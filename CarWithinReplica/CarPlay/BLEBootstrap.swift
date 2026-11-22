import Foundation
import CoreBluetooth

/// BLE 引导：复刻原版 `TDSCarKit.BLEBootstrap`。
///
/// 原版从二进制里能挖到的完整形态：
///   CBPeripheralManager 广播服务 0xFC94（外加 0xF20BFCDB…）
///   publishL2CAPChannel 发布 L2CAP 通道（iAP2 over BLE 的传输层）
///   对端连入后，iAP2 字节流走 L2CAP
///
/// iPhone 的 CarPlay 栈靠这个 BLE 广播发现「车机」，然后弹出
/// 「连接 CarPlay 车载」系统弹窗——光有 Bonjour 是不够的。
final class BLEBootstrap: NSObject, CBPeripheralManagerDelegate {
    static let shared = BLEBootstrap()
    var onLog: ((String) -> Void)?

    /// 原版广播的两个服务 UUID（strings 里挖到，紧挨着 `/L2CAP`）。
    private let advertisedServiceIDs: [CBUUID] = [
        CBUUID(string: "0000FC94-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "F20BFCDB-B5B1-484F-AFBA-29DDE86C972E"),
    ]

    private var manager: CBPeripheralManager?
    private var psmID: CBL2CAPPSM?
    private var links: [L2CAPLink] = []

    private override init() { super.init() }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        stop()
        onLog?("[BLE] 启动外设广播（服务 0xFC94 + L2CAP）")
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        manager?.stopAdvertising()
        if let psmID { manager?.unpublishL2CAPChannel(psmID) }
        manager?.stop()
        manager = nil
        self.psmID = nil
        links.forEach { $0.close() }
        links.removeAll()
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let name: String
        switch peripheral.state {
        case .poweredOn: name = "已开启"
        case .poweredOff: name = "已关闭"
        case .unauthorized: name = "未授权"
        case .unsupported: name = "不支持"
        case .resetting: name = "重置中"
        default: name = "未知"
        }
        onLog?("[BLE] 蓝牙状态：\(name)")
        if peripheral.state == .unauthorized {
            onLog?("[BLE] 蓝牙权限被拒：请到 设置 → 隐私与安全性 → 蓝牙 打开 CarWithin")
            return
        }
        guard peripheral.state == .poweredOn else { return }
        // L2CAP 是 iAP2 over BLE 的传输层，先发布通道再广播（原版顺序）。
        peripheral.publishL2CAPChannel()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM,
                           error: Error?) {
        if let error {
            onLog?("[BLE] L2CAP 发布失败：\(error.localizedDescription)")
            return
        }
        psmID = PSM
        onLog?("[BLE] L2CAP 通道已发布 PSM=\(PSM)")

        let name = CarPlayConfiguration.vehicleName
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: advertisedServiceIDs,
        ]
        peripheral.startAdvertising(advertisement)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onLog?("[BLE] 广播启动失败：\(error.localizedDescription)")
            return
        }
        onLog?("[BLE] 广播已启动：\(CarPlayConfiguration.vehicleName) · 服务 0xFC94")
        onLog?("[BLE] 等待 iOS 的 CarPlay 栈发现并弹出「连接 CarPlay 车载」")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didOpen channel: CBL2CAPChannel?,
                           error: Error?) {
        if let error {
            onLog?("[BLE] L2CAP 连入失败：\(error.localizedDescription)")
            return
        }
        guard let channel else { return }
        onLog?("[BLE] L2CAP 已连入 PSM=\(channel.channelPSM)")
        let link = L2CAPLink(channel: channel)
        link.onLog = { [weak self] in self?.onLog?($0) }
        links.append(link)
        link.open()
    }
}

/// 一条 L2CAP 链路：把 iAP2 字节流读出来，解析成封包并回话。
final class L2CAPLink: NSObject, StreamDelegate {
    let channel: CBL2CAPChannel
    var onLog: ((String) -> Void)?

    private var parser = IAP2Parser()

    init(channel: CBL2CAPChannel) {
        self.channel = channel
    }

    func open() {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            onLog?("L2CAP 通道缺少输入/输出流")
            return
        }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        onLog?("L2CAP 流已打开，等待 iAP2 数据")
    }

    func close() {
        channel.inputStream?.close()
        channel.outputStream?.close()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === channel.inputStream else { return }
        switch eventCode {
        case .hasBytesAvailable:
            var buffer = [UInt8](repeating: 0, count: 4096)
            let read = aStream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { return }
            parser.append(Data(buffer[0..<read]))
            while let packet = parser.next() {
                handle(packet)
            }
        case .endEncountered, .errorOccurred:
            onLog?("L2CAP 流已结束")
            close()
        default:
            break
        }
    }

    private func handle(_ packet: IAP2Packet) {
        onLog?("← L2CAP iAP2 control=0x\(String(packet.control, radix: 16)) session=\(packet.session) \(packet.payload.count)B")

        // 链路包（控制位 bit1 = 0）回 presence，保持链路存活。
        if packet.control & 0x02 == 0 {
            var reply = IAP2Packet.presence
            reply.session = packet.session
            send(reply)
            return
        }

        // 消息包：认出 iAP2 认证流程就用 MFi 身份回话。
        guard packet.payload.count >= 2 else { return }
        let start = packet.payload.startIndex
        let messageID = (UInt16(packet.payload[start]) << 8) | UInt16(packet.payload[start + 1])
        onLog?("iAP2 消息 0x\(String(messageID, radix: 16))")

        if messageID == IAP2MessageID.requestAuthenticationCert,
           let message = IAP2Authentication.certificateMessage() {
            send(IAP2Packet(control: 0x02, session: packet.session,
                            sequence: packet.sequence,
                            acknowledgement: packet.acknowledgement,
                            payload: message.encoded()))
            onLog?("→ 已回送 MFi 证书链")
        } else if messageID == IAP2MessageID.requestAuthenticationSignature {
            let challenge = packet.payload.count > 4 ? Data(packet.payload[(start + 4)...]) : Data()
            if let message = IAP2Authentication.responseMessage(challenge: challenge) {
                send(IAP2Packet(control: 0x02, session: packet.session,
                                sequence: packet.sequence,
                                acknowledgement: packet.acknowledgement,
                                payload: message.encoded()))
                onLog?("→ 已回送 MFi 签名")
            }
        } else if messageID == IAP2MessageID.startIDPS {
            // 识别流程：回一条包含车机能力的 0x1D00，声明我们支持 CarPlay。
            let config = IAP2Configuration.message()
            send(IAP2Packet(control: 0x02, session: packet.session,
                            sequence: packet.sequence,
                            acknowledgement: packet.acknowledgement,
                            payload: config.encoded()))
            onLog?("→ 已回送车机配置 0x1D00")
        }
    }

    private func send(_ packet: IAP2Packet) {
        guard let output = channel.outputStream else { return }
        let data = packet.encoded()
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = output.write(base, maxLength: data.count)
        }
    }
}
