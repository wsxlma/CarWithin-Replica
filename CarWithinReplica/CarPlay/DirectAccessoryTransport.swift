import Foundation

/// 直连配件传输：照原版 `DirectAccessoryTransport` 的接口自己实现。
///
/// 原版这个类就在它 App 二进制里（`_OBJC_CLASS_$_DirectAccessoryTransport`
/// 带完整方法/属性表），是对 ACCTransportClient 的封装：
///   client / connection / endpoint / generation
///   - startWithIdentifier:transportType:error:   （原版用 transportType=2）
///   - sendData:error:
///   - stop
///   @property (copy) void (^onData)(NSData *)
///
/// 关键：它不是系统私有框架的类，所以之前 dlopen 查找必然落空。
/// 这里照同样的调用序列自己建端点：createConnection → createEndpoint，
/// 并把 transportType/protocol/publish/identifier 的组合全试一遍，
/// 直到 createEndpoint 返回非 nil——那组参数就是原版用的。
final class DirectAccessoryTransport: NSObject {
    static let shared = DirectAccessoryTransport()

    /// 收到系统送来的数据（对应原版 onData）。
    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var client: AnyObject?
    private(set) var connectionUUID: String?
    private(set) var endpointUUID: String?
    private(set) var generation = 0
    private var started = false
    private var parser = IAP2Parser()

    private override init() { super.init() }

    // MARK: - 对外接口（与原版同名同参）

    @discardableResult
    func start(identifier: String, transportType: Int32 = 2) -> Bool {
        stop()
        generation += 1

        guard let client = ACCBridge.sharedTransportClient() else {
            onLog?("[直连] ACCTransportClient 不可用")
            return false
        }
        self.client = client

        // 1) 建连接（原版日志里 type=0 返回 nil，type=1 成功）
        var connectionUUID: String?
        for type: Int32 in [1, 0, 2] {
            if let uuid = ACCBridge.createConnection(type: type, identifier: identifier) {
                connectionUUID = uuid
                onLog?("[直连] createConnection(type=\(type)) → \(uuid)")
                break
            }
        }
        guard let connectionUUID else {
            onLog?("[直连] createConnection 全部失败")
            return false
        }
        self.connectionUUID = connectionUUID

        // 2) 建端点。参数组合已在真机上验证（2.3.6 首次成功）：
        //    transport=2 protocol=0 publish=false identifier=配件名（不是 connection UUID）。
        guard let endpoint = ACCBridge.createEndpoint(
            transportType: transportType,
            protocolType: 0,
            identifier: identifier,
            connectionUUID: connectionUUID,
            publishConnection: false,
            onData: { [weak self] data in
                self?.receive(data)
            }) else {
            onLog?("[直连] createEndpoint 失败（transport=\(transportType) protocol=0）")
            return false
        }
        endpointUUID = endpoint
        onLog?("[直连] createEndpoint 成功 → \(endpoint)")
        onLog?("[直连] 参数组合：transport=\(transportType) protocol=0 publish=false identifier=\(identifier)")

        // 3) 发布连接（原版这里也返回 false，但端点已建起来，不阻塞）
        let published = ACCBridge.publishConnection(uuid: connectionUUID)
        onLog?("[直连] publishConnection → \(published)")

        started = true
        onLog?("[直连] 本机配件端点已就绪（identifier=\(identifier), transportType=\(transportType)）")

        // 原版流程：端点建好后发一个「iAP2 在线探测」，等 iOS 服务回应，
        // 之后系统会主动发 0xAA00/0x1D00/0x4300，我们逐条回（见 receive）。
        sendProbe()
        return true
    }

    /// iAP2 在线探测：一条 presence 链路包，提示 iOS 服务我们在了。
    private func sendProbe() {
        let probe = IAP2Packet.presence
        send(probe.encoded())
        onLog?("[直连] → 已发送 iAP2 在线探测，等待 iOS 服务回应")
    }

    /// 收到系统送来的字节流：切出 iAP2 封包，按认证流程回话。
    /// 按原版日志的完整 iAP2 流程逐条响应：
    ///   0xAA00→0xAA01 证书、0xAA02→0xAA03 签名、0xAA05 认证通过
    ///   0x1D00→0x1D01 识别信息、0x1D02 识别通过
    ///   0x4300→0x4301 请求启动 CarPlay（带本机地址），随后 iOS 连入 7000
    private func receive(_ data: Data) {
        onLog?("[直连] ← 收到配件数据 \(data.count)B")
        parser.append(data)
        while let packet = parser.next() {
            onLog?("[直连] iAP2 control=0x\(String(packet.control, radix: 16)) \(packet.payload.count)B")
            onData?(packet.payload)

            if packet.control & 0x02 == 0 {
                var reply = IAP2Packet.presence
                reply.session = packet.session
                send(reply.encoded())
                onLog?("[直连] → 回送 presence")
                continue
            }
            guard packet.payload.count >= 2 else { continue }
            let start = packet.payload.startIndex
            let messageID = (UInt16(packet.payload[start]) << 8) | UInt16(packet.payload[start + 1])
            onLog?("[直连] ← iAP2 消息 0x\(String(messageID, radix: 16))")

            switch messageID {
            case IAP2MessageID.requestAuthentication:            // 0xAA00
                if let cert = IAP2Authentication.certificateMessage() {
                    send(encode(cert, packet: packet))
                    onLog?("[直连] → 回送 MFi 证书链 0xAA01")
                }
            case IAP2MessageID.requestAuthenticationSignature:   // 0xAA02
                let challenge = packet.payload.count > 4 ? Data(packet.payload[(start + 4)...]) : Data()
                if let resp = IAP2Authentication.responseMessage(challenge: challenge) {
                    send(encode(resp, packet: packet))
                    onLog?("[直连] → 回送 MFi 签名 0xAA03")
                }
            case IAP2MessageID.accessoryAuthAccepted:            // 0xAA05
                onLog?("[直连] ← iOS 已接受配件认证")
            case IAP2MessageID.requestIdentification:            // 0x1D00
                let ident = AccessoryMessages.identification(
                    name: CarPlayConfiguration.vehicleName,
                    deviceID: AccessoryMessages.deviceID)
                send(encode(ident, packet: packet))
                onLog?("[直连] → 回送识别信息 0x1D01")
            case IAP2MessageID.identificationAccepted:           // 0x1D02
                onLog?("[直连] ← iOS 已接受配件识别，等待 CarPlay 可用通知")
            case IAP2MessageID.carPlayAvailable:                 // 0x4300
                let host = BrowserOutput.localIPv4() ?? "127.0.0.1"
                let start = AccessoryMessages.startSession(
                    address: host, port: 7000,
                    deviceID: AccessoryMessages.deviceID, wifi: nil)
                send(encode(start, packet: packet))
                onLog?("[直连] → 回送 0x4301 请求在 \(host):7000 启动 CarPlay")
            default:
                break
            }
        }
    }

    private func encode(_ message: IAP2Message, packet: IAP2Packet?) -> Data {
        if let packet {
            return IAP2Packet(control: 0x02, session: packet.session,
                              sequence: packet.sequence,
                              acknowledgement: packet.acknowledgement,
                              payload: message.encoded()).encoded()
        }
        return IAP2Packet(control: 0x02, session: 0, sequence: 0,
                          acknowledgement: 0,
                          payload: message.encoded()).encoded()
    }

    @discardableResult
    func sendData(_ data: Data) -> Bool {
        guard started, let endpointUUID, let connectionUUID else { return false }
        return ACCBridge.sendOutgoingData(data,
                                         endpointUUID: endpointUUID,
                                         connectionUUID: connectionUUID)
    }

    private func send(_ data: Data) {
        // 配件 → 系统：processIncomingData 才是正确方向
        //（sendOutgoingData 是系统 → 配件，之前用反了，系统收不到）。
        guard let endpointUUID else {
            onLog?("[直连] 无端点，无法发送")
            return
        }
        let okIn = ACCBridge.processIncomingData(data, endpointUUID: endpointUUID)
        _ = sendData(data)   // 顺带再走一次反向，便于日志对比哪个有效
        if okIn {
            onLog?("[直连] → processIncomingData 已发送 \(data.count)B")
        } else {
            onLog?("[直连] → processIncomingData 失败，改走 sendOutgoingData \(data.count)B")
        }
    }

    func stop() {
        if let endpointUUID {
            _ = ACCBridge.destroyEndpoint(uuid: endpointUUID)
        }
        if let connectionUUID {
            _ = ACCBridge.destroyConnection(uuid: connectionUUID)
        }
        client = nil
        endpointUUID = nil
        connectionUUID = nil
        started = false
    }
}
