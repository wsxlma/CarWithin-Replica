import Foundation

/// 同设备探测编排 —— 逐条照原版 `TDSCarKit.SameDeviceProbe` 反编译重写
/// （`analysis/probe.c` / `probe-send.c`）。
///
/// 原版行为要点：
/// - `start` 先 `stop()`（重置序列号等全部状态），`active = true`，`generation = UUID()`。
/// - `transport.startWithIdentifier(name, transportType: 2)`，成功后**立刻**发
///   `IAP2Packet.presence`（裸 6 字节，不套帧头）。
/// - `send` 每次 `sequence &+ 1`，封包 `control = 0x40`，`session` 取实例字段。
/// - 初始值：`sequence = 0x10`、`acknowledgement = 0`、`session = 1`、
///   `lastPayloadSequence = 0x0100`，五个标志位全 false。
/// - 定时重发：3s / 20s / 70s（原版 `asyncAfter` 的三个常量）。
/// - 状态机见 `handle(_:)`。
final class SameDeviceProbe {
    var onLog: ((String) -> Void)?
    var onStage: ((String) -> Void)?
    var onFinished: ((String) -> Void)?
    /// 收到完整 iAP2 消息后向外抛（原版用于把业务消息转给上层）。
    var onMessage: ((IAP2Message) -> Void)?

    private let transport: DirectAccessoryTransport
    private var identity: AccessoryIdentity?
    private var generation = UUID()
    private(set) var active = false

    // 链路状态（原版字段，初值来自 stop()）
    private(set) var sequence: UInt8 = 0x10
    private(set) var acknowledgement: UInt8 = 0
    private(set) var session: UInt8 = 1
    private(set) var lastPayloadSequence: UInt16 = 0x0100
    private(set) var linked = false
    private(set) var authenticated = false
    private(set) var identified = false
    private(set) var requested = false
    private(set) var controlConnected = false

    private var iap2Parser = IAP2Parser()
    private var frameParser = BLEFrameParser()
    private var scheduled: [DispatchWorkItem] = []
    /// 传给 0x4301 的地址，由上层注入（NativeReceiver 实际监听的地址）。
    var sessionEndpoint: (address: String, port: UInt16, wifi: AccessoryMessages.WiFi?)?

    init(transport: DirectAccessoryTransport = .shared) {
        self.transport = transport
    }

    // MARK: - 生命周期

    func start(name: String, identity: AccessoryIdentity, transportType: Int = 2) {
        stop()
        active = true
        self.identity = identity
        generation = UUID()
        onLog?("[探测] 启动：name=\(name) type=\(transportType) generation=\(generation.uuidString.prefix(8))")

        transport.onLog = { [weak self] message in self?.onLog?(message) }
        transport.onData = { [weak self] data in self?.receive(data) }

        guard transport.start(identifier: name, transportType: transportType) else {
            onLog?("[探测] transport 启动失败，终止")
            stop()
            onFinished?("直连配件通道建立失败")
            return
        }

        // 原版：连接成功后立刻发 presence。
        do {
            try sendRaw(IAP2Packet.presence, label: "presence")
        } catch {
            onLog?("[探测] 发送 presence 失败：\(error.localizedDescription)")
            stop()
            onFinished?("发送 presence 失败")
            return
        }
        onStage?("已连接配件通道，presence 已发出")

        scheduleFollowUps()
    }

    func stop() {
        active = false
        generation = UUID()
        transport.onData = nil
        transport.stop()

        frameParser.reset()
        iap2Parser.reset()

        sequence = 0x10
        acknowledgement = 0
        session = 1
        lastPayloadSequence = 0x0100
        linked = false
        authenticated = false
        identified = false
        requested = false
        controlConnected = false

        scheduled.forEach { $0.cancel() }
        scheduled.removeAll()
        identity = nil
        onLog?("[探测] 已停止并重置状态")
    }

    // MARK: - 定时补发

    /// 原版在 3s / 20s / 70s 三个时间点做补发，保证链路不会因为一次丢包就卡死。
    private func scheduleFollowUps() {
        for (index, delay) in [3.0, 20.0, 70.0].enumerated() {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                let stage = "第 \(index + 1) 次补发(\(Int(delay))s)"
                if self.identified && self.requested {
                    self.onLog?("[探测] \(stage)：已进入会话阶段，仅保活")
                    return
                }
                self.onLog?("[探测] \(stage)：identified=\(self.identified) authenticated=\(self.authenticated) requested=\(self.requested)")
                try? self.sendRaw(IAP2Packet.presence, label: "presence 补发")
            }
            scheduled.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - 发送

    private func sendRaw(_ data: Data, label: String) throws {
        guard transport.sendData(data) else {
            throw ProtocolError.message("transport.sendData 返回失败（\(label)）")
        }
        onLog?("[探测] → \(label) \(data.count)B")
    }

    /// 原版 `send(_ message: IAP2Message)`。
    private func send(_ message: IAP2Message) throws {
        sequence = sequence &+ 1
        let packet = IAP2Packet(control: 0x40,
                                sequence: sequence,
                                acknowledgement: acknowledgement,
                                session: session,
                                payload: message.encoded())
        let data = packet.encoded()
        guard transport.sendData(data) else {
            throw ProtocolError.message("transport.sendData 返回失败（消息 0x\(String(message.id, radix: 16))）")
        }
        onLog?("[探测] → iAP2 0x\(String(format: "%04X", message.id)) seq=\(sequence) session=\(session) \(data.count)B  \(hex(data))")
    }

    // MARK: - 接收

    private func receive(_ data: Data) {
        onLog?("[探测] ← 原始 \(data.count)B  \(hex(data, limit: 64))")

        // 原版链路里数据可能带 BLEFrame 头，也可能直接是 iAP2 包。
        // 这里先尝试直接切 iAP2；切不出来再剥一层 BLEFrame。
        iap2Parser.append(data)
        var progress = false
        while let packet = iap2Parser.next() {
            progress = true
            handle(packet: packet)
        }
        if progress { return }

        // 走 BLEFrame 容器（原版 stop() 里就持有 BLEFrameParser）。
        frameParser.append(data)
        while let frame = frameParser.next() {
            onLog?("[探测] ← BLEFrame type=0x\(String(format: "%04X", frame.type)) \(frame.payload.count)B")
            iap2Parser.append(frame.payload)
            while let packet = iap2Parser.next() {
                handle(packet: packet)
            }
        }

        if let reason = iap2Parser.lastDropReason {
            onLog?("[探测] iAP2 切包丢弃 \(iap2Parser.droppedBytes)B（\(reason)）")
        }
        if let reason = frameParser.lastDropReason {
            onLog?("[探测] BLEFrame 切包丢弃 \(frameParser.droppedBytes)B（\(reason)）")
        }
    }

    private func handle(packet: IAP2Packet) {
        onLog?("[探测] ← iAP2 control=0x\(String(format: "%02X", packet.control)) seq=\(packet.sequence) ack=\(packet.acknowledgement) session=\(packet.session) payload=\(packet.payload.count)B")

        // 链路层同步包（control 0xEE 之类）直接应答链路，不进消息层。
        if packet.control & 0x80 != 0 {
            linked = true
            onLog?("[探测] 链路同步包 control=0x\(String(format: "%02X", packet.control))，标记 linked")
            return
        }

        guard let message = IAP2Message.parse(packet.payload) else {
            onLog?("[探测] 消息层解析失败（payload 首字节 \(packet.payload.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))）")
            return
        }
        handle(message, packet: packet)
    }

    private func handle(_ message: IAP2Message, packet: IAP2Packet) {
        onLog?("[探测] ← 消息 \(message.summary)")
        onMessage?(message)

        switch message.id {
        case IAP2MessageID.requestIdentification:              // 0x1D00
            onLog?("[探测] 收到 0x1D00 识别请求，回 0x1D01")
            let identification = AccessoryMessages.identification(
                name: CarPlayConfiguration.vehicleName,
                deviceID: AccessoryMessages.deviceID)
            do {
                try send(identification)
            } catch {
                onLog?("[探测] 回 0x1D01 失败：\(error.localizedDescription)")
            }

        case IAP2MessageID.identificationAccepted:             // 0x1D02
            identified = true
            onLog?("[探测] iOS 已接受配件识别（identified = true）")
            onStage?("配件识别已通过")

        case IAP2MessageID.identificationRejected:             // 0x1D03
            let list = message.parameters.map { String(format: "0x%04X", $0.id) }.joined(separator: ",")
            onLog?("[探测] 识别被拒绝 0x1D03，参数 id：\(list)")
            onStage?("识别被拒绝：\(list)")

        case IAP2MessageID.requestAuthentication:              // 0xAA00
            onLog?("[探测] 收到 0xAA00 认证请求，回证书链")
            guard let chain = identity?.certificateChain, !chain.isEmpty else {
                onLog?("[探测] 没有可用证书链（certificate.p7b 缺失），无法回 0xAA01")
                return
            }
            let reply = IAP2Message(id: IAP2MessageID.authenticationCertificate,
                                    parameters: [IAP2Parameter(id: 0, value: chain)])
            do {
                try send(reply)
            } catch {
                onLog?("[探测] 回 0xAA01 失败：\(error.localizedDescription)")
            }

        case IAP2MessageID.requestAuthenticationSignature:     // 0xAA02
            onLog?("[探测] 收到 0xAA02 签名请求")
            guard let challenge = message.data(0) else {
                onLog?("[探测] 0xAA02 缺少参数 id 0，忽略")
                return
            }
            onLog?("[探测] 挑战值 \(challenge.count)B：\(hex(challenge))")
            guard let identity else {
                onLog?("[探测] 身份未就绪，无法签名")
                return
            }
            do {
                let signature = try identity.sign(challenge: challenge)
                onLog?("[探测] 签名 \(signature.count)B：\(hex(signature, limit: 32))")
                let reply = IAP2Message(id: IAP2MessageID.authenticationSignature,
                                        parameters: [IAP2Parameter(id: 0, value: signature)])
                try send(reply)
            } catch {
                onLog?("[探测] 签名/回 0xAA03 失败：\(error.localizedDescription)")
            }

        case IAP2MessageID.authenticationSucceeded:            // 0xAA04
            onLog?("[探测] iOS 报告认证结束 0xAA04")
            stop()
            onFinished?("认证流程结束（0xAA04）")

        case IAP2MessageID.authenticationAccepted:             // 0xAA05
            authenticated = true
            onLog?("[探测] iOS 已接受配件认证（authenticated = true）")
            onStage?("配件认证已通过")

        case IAP2MessageID.carPlayAvailable:                   // 0x4300
            onLog?("[探测] 收到 0x4300（CarPlay 可用）")
            guard authenticated && identified else {
                onLog?("[探测] 但 authenticated=\(authenticated) identified=\(identified)，条件不足，暂不请求会话")
                return
            }
            sendStartSession(reason: "0x4300 触发")
            // 原版在 3s / 6s 再补两次，防止第一次交互丢失。
            for delay in [3.0, 6.0] {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.active else { return }
                    self.sendStartSession(reason: "0x4300 补发(\(Int(delay))s)")
                }
                scheduled.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }

        default:
            onLog?("[探测] 未处理消息 0x\(String(format: "%04X", message.id))，参数 \(message.parameters.count) 个")
        }
    }

    private func sendStartSession(reason: String) {
        guard let endpoint = sessionEndpoint else {
            onLog?("[探测] 未配置会话地址，无法回 0x4301（\(reason)）")
            return
        }
        let message = AccessoryMessages.startSession(address: endpoint.address,
                                                     port: endpoint.port,
                                                     deviceID: AccessoryMessages.deviceID,
                                                     wifi: endpoint.wifi)
        do {
            try send(message)
            requested = true
            onLog?("[探测] \(reason)：已请求 CarPlay 连入 \(endpoint.address):\(endpoint.port)")
            onStage?("已请求 iOS 连入 \(endpoint.address):\(endpoint.port)")
        } catch {
            onLog?("[探测] 回 0x4301 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 工具

    private func hex(_ data: Data, limit: Int = 48) -> String {
        let slice = data.prefix(limit)
        let text = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? text + " …(共 \(data.count)B)" : text
    }
}
