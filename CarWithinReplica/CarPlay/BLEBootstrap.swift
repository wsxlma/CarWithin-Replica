import Foundation
import CoreBluetooth

/// BLE 引导：复刻原版 `TDSCarKit.BLEBootstrap` 的完整形态。
///
/// 原版做的事（从二进制符号还原）：
///   1. CBMutableService + CBMutableCharacteristic 注册 GATT 服务
///   2. publishL2CAPChannel 发布 L2CAP（iAP2 over BLE 的数据通道）
///   3. startAdvertising 广播服务 UUID
///   4. didReceiveRead/WriteRequests 收发 BLEFrame(type,payload)，内层是 iAP2
///
/// 关键：只 startAdvertising 不 addService 是不行的——iPhone 扫到广播后
/// 会去读 GATT，服务不存在就直接忽略，配对框也就不会弹。
final class BLEBootstrap: NSObject, CBPeripheralManagerDelegate {
    static let shared = BLEBootstrap()
    var onLog: ((String) -> Void)?

    /// 车机声明支持 CarPlay 的发现 UUID（车机开发文档：配件端蓝牙 CarPlay EIR 扩展）。
    /// 少了这个，iPhone 扫到外设也不会认成 CarPlay，配对框自然不弹。
    private let carPlayUUID = CBUUID(string: "EC884348-CD41-40A2-9727-575D50BF1FD3")
    /// 配件端 iAP2 EIR 扩展 UUID（同文档）。
    private let iap2UUID = CBUUID(string: "FFCACADE-AFDE-CADE-DEFA-CADE00000000")
    /// 原版 strings 里的数据服务（0xFC94）与特征。
    private let serviceUUID = CBUUID(string: "0000FC94-0000-1000-8000-00805F9B34FB")
    private let characteristicUUID = CBUUID(string: "F20BFCDB-B5B1-484F-AFBA-29DDE86C972E")

    private var manager: CBPeripheralManager?
    private var psmID: CBL2CAPPSM?
    private var characteristic: CBMutableCharacteristic?
    private var subscribed: [CBCentral] = []
    private var links: [L2CAPLink] = []
    private var frameParser = BLEFrameParser()

    private override init() { super.init() }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        stop()
        onLog?("[BLE] 启动外设（GATT 服务 0xFC94 + L2CAP + 广播）")
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        manager?.stopAdvertising()
        manager?.removeAllServices()
        if let psmID { manager?.unpublishL2CAPChannel(psmID) }
        manager = nil
        self.psmID = nil
        characteristic = nil
        subscribed.removeAll()
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

        // 1) 先发布 L2CAP 数据通道
        peripheral.publishL2CAPChannel(withEncryption: false)

        // 2) 再注册 GATT 服务。注意：每个 service 必须有自己的 characteristic 实例，
        //    复用同一个实例会导致 addService 崩溃（2.3.8 闪退原因）。
        var dataCharacteristic: CBMutableCharacteristic?
        for uuid in [carPlayUUID, iap2UUID, serviceUUID] {
            let characteristic = CBMutableCharacteristic(
                type: characteristicUUID,
                properties: [.read, .write, .writeWithoutResponse, .notify],
                value: nil,
                permissions: [.readable, .writeable])
            let service = CBMutableService(type: uuid, primary: true)
            service.characteristics = [characteristic]
            peripheral.add(service)
            if dataCharacteristic == nil { dataCharacteristic = characteristic }
        }
        self.characteristic = dataCharacteristic
        onLog?("[BLE] GATT 服务已注册：CarPlay(EC884348) + iAP2(FFCACADE) + 0xFC94")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("[BLE] GATT 服务添加失败：\(error.localizedDescription)")
            return
        }
        onLog?("[BLE] GATT 服务已添加，开始广播")
        // AD 包必须带 CarPlay TLV 载荷（配对 flag / 能力掩码 / 设备 MAC），
        // 否则 iPhone 只看到一个普通外设，不认它是 CarPlay（真机抓包结论）。
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: CarPlayConfiguration.vehicleName,
            CBAdvertisementDataServiceUUIDsKey: [carPlayUUID, iap2UUID, serviceUUID],
            CBAdvertisementDataServiceDataKey: [carPlayUUID: carPlayTLV()],
        ]
        peripheral.startAdvertising(advertisement)
    }

    /// CarPlay TLV 载荷：element = id(1) + len(1) + value。
    ///   0x01 配对 flag、0x02 能力掩码、0x03 设备 MAC（车机开发文档 IE 结构）。
    private func carPlayTLV() -> Data {
        var tlv = Data()
        // 配对 flag：已声明 CarPlay + iAP2
        tlv.append(contentsOf: [0x01, 0x01, 0x03])
        // 能力掩码：CarPlay=0x01 | iAP2=0x02 | H.265=0x04 | 音频=0x08
        let capability: UInt16 = 0x000F
        tlv.append(0x02); tlv.append(0x02)
        tlv.append(UInt8(capability & 0xFF)); tlv.append(UInt8(capability >> 8))
        // 设备 MAC（与 Bonjour TXT 的 deviceid 一致）
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        tlv.append(0x03); tlv.append(UInt8(mac.count))
        tlv.append(contentsOf: mac)
        return tlv
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onLog?("[BLE] 广播启动失败：\(error.localizedDescription)")
            return
        }
        onLog?("[BLE] 广播已启动：\(CarPlayConfiguration.vehicleName)")
        onLog?("[BLE] AD 包：CarPlay UUID EC884348 + iAP2 UUID FFCACADE + TLV(配对/能力/MAC)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            onLog?("[BLE] L2CAP 发布失败：\(error.localizedDescription)")
            return
        }
        psmID = PSM
        onLog?("[BLE] L2CAP 通道已发布 PSM=\(PSM)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        // 读请求：回车机信息 + L2CAP PSM，iPhone 靠这个知道连哪个通道。
        var payload = Data()
        var ps = psmID ?? 0
        payload.append(withUnsafeBytes(of: &ps) { Data($0) })
        payload.append(Data(CarPlayConfiguration.vehicleName.utf8))
        request.value = payload
        peripheral.respond(to: request, withResult: .success)
        onLog?("[BLE] 读请求已应答（\(payload.count)B，PSM=\(psmID.map(String.init) ?? "?")）")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let value = request.value {
                onLog?("[BLE] 收到写入 \(value.count)B")
                consume(value, peripheral: peripheral)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribed.append(central)
        onLog?("[BLE] 对端已订阅特征（连接建立）")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribed.removeAll { $0.identifier == central.identifier }
        onLog?("[BLE] 对端取消订阅")
    }

    // MARK: - BLEFrame ↔ iAP2

    /// 特征值里的帧：`[type: UInt16 LE][length: UInt16 LE][payload]`，payload 是 iAP2。
    private func consume(_ data: Data, peripheral: CBPeripheralManager) {
        let frames = frameParser.append(data)
        for frame in frames {
            onLog?("[BLE] 帧 type=0x\(String(frame.type, radix: 16)) \(frame.payload.count)B")
            handle(frame, peripheral: peripheral)
        }
    }

    private func handle(_ frame: BLEFrame, peripheral: CBPeripheralManager) {
        var parser = IAP2Parser()
        parser.append(frame.payload)
        while let packet = parser.next() {
            onLog?("[BLE] iAP2 control=0x\(String(packet.control, radix: 16)) \(packet.payload.count)B")

            if packet.control & 0x02 == 0 {
                var reply = IAP2Packet.presence
                reply.session = packet.session
                send(reply, peripheral: peripheral)
                continue
            }

            guard packet.payload.count >= 2 else { continue }
            let start = packet.payload.startIndex
            let messageID = (UInt16(packet.payload[start]) << 8) | UInt16(packet.payload[start + 1])
            onLog?("[BLE] iAP2 消息 0x\(String(messageID, radix: 16))")

            if messageID == IAP2MessageID.requestAuthenticationCert,
               let message = IAP2Authentication.certificateMessage() {
                send(IAP2Packet(control: 0x02, session: packet.session,
                                sequence: packet.sequence,
                                acknowledgement: packet.acknowledgement,
                                payload: message.encoded()), peripheral: peripheral)
                onLog?("[BLE] → 已回送 MFi 证书链")
            } else if messageID == IAP2MessageID.requestAuthenticationSignature {
                let challenge = packet.payload.count > 4 ? Data(packet.payload[(start + 4)...]) : Data()
                if let message = IAP2Authentication.responseMessage(challenge: challenge) {
                    send(IAP2Packet(control: 0x02, session: packet.session,
                                    sequence: packet.sequence,
                                    acknowledgement: packet.acknowledgement,
                                    payload: message.encoded()), peripheral: peripheral)
                    onLog?("[BLE] → 已回送 MFi 签名")
                }
            } else if messageID == IAP2MessageID.startIDPS {
                // 识别：先声明「我是一台 CarPlay 车机」，iPhone 收到后才可能弹配对框。
                let ident = AccessoryMessages.identification(
                    name: CarPlayConfiguration.vehicleName,
                    deviceID: AccessoryMessages.deviceID)
                send(IAP2Packet(control: 0x02, session: packet.session,
                                sequence: packet.sequence,
                                acknowledgement: packet.acknowledgement,
                                payload: ident.encoded()), peripheral: peripheral)
                onLog?("[BLE] → 已回送 identification（声明 CarPlay 车机）")

                let config = IAP2Configuration.message()
                send(IAP2Packet(control: 0x02, session: packet.session,
                                sequence: packet.sequence,
                                acknowledgement: packet.acknowledgement,
                                payload: config.encoded()), peripheral: peripheral)
                onLog?("[BLE] → 已回送车机配置 0x1D00")
            } else if messageID == IAP2MessageID.authStatus {
                // 认证通过后把 RTSP 地址递给 iPhone，让它连进来。
                let host = BrowserOutput.localIPv4() ?? "127.0.0.1"
                let session = AccessoryMessages.startSession(
                    address: host, port: 7000,
                    deviceID: AccessoryMessages.deviceID, wifi: nil)
                send(IAP2Packet(control: 0x02, session: packet.session,
                                sequence: packet.sequence,
                                acknowledgement: packet.acknowledgement,
                                payload: session.encoded()), peripheral: peripheral)
                onLog?("[BLE] → 已回送 startSession（\(host):7000）")
            }
        }
    }

    private func send(_ packet: IAP2Packet, peripheral: CBPeripheralManager) {
        let frame = BLEFrame(type: 0x0001, payload: packet.encoded())
        guard let characteristic else { return }
        let ok = peripheral.updateValue(frame.encoded(), for: characteristic, onSubscribedCentrals: nil)
        if !ok {
            onLog?("[BLE] 通知队列已满，稍后重试")
        }
    }
}

// MARK: - BLE 帧协议

/// 特征值上的帧：`[type: UInt16 LE][length: UInt16 LE][payload]`。
struct BLEFrame {
    var type: UInt16
    var payload: Data

    func encoded() -> Data {
        var data = Data()
        var t = type.littleEndian
        var l = UInt16(payload.count).littleEndian
        data.append(withUnsafeBytes(of: &t) { Data($0) })
        data.append(withUnsafeBytes(of: &l) { Data($0) })
        data.append(payload)
        return data
    }
}

struct BLEFrameParser {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [BLEFrame] {
        buffer.append(data)
        var frames: [BLEFrame] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let type = UInt16(buffer[start]) | (UInt16(buffer[start + 1]) << 8)
            let length = Int(UInt16(buffer[start + 2]) | (UInt16(buffer[start + 3]) << 8))
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
            buffer.removeFirst(4 + length)
            frames.append(BLEFrame(type: type, payload: payload))
        }
        return frames
    }

    mutating func reset() { buffer.removeAll() }
}

/// 一条 L2CAP 链路（原版同样保留 L2CAP 作为大数据通道）。
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
            guard let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let read = input.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { return }
            parser.append(Data(buffer[0..<read]))
            while let packet = parser.next() {
                onLog?("← L2CAP iAP2 control=0x\(String(packet.control, radix: 16)) \(packet.payload.count)B")
            }
        case .endEncountered, .errorOccurred:
            onLog?("L2CAP 流已结束")
            close()
        default:
            break
        }
    }
}
