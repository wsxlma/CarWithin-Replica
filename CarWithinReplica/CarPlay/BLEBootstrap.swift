import Foundation
import CoreBluetooth

/// BLE 引导链路 —— 照原版 `TDSCarKit.BLEBootstrap` 反编译重写。
///
/// 原版真实实现（此前写成「三 GATT 服务 + Manufacturer Data 广播」是错的）：
/// 1. 只用一个服务 `0000FC94-0000-1000-8000-00805F9B34FB`，广播里报短 UUID `"FC94"`。
/// 2. 蓝牙 poweredOn 后**只做一件事**：`publishL2CAPChannel(withEncryption: false)`。
/// 3. `didPublishL2CAPChannel` 拿到 PSM 后，才建特征
///    `F20BFCDB-B5B1-484F-AFBA-29DDE86C972E`（properties read|notify = 0x12，
///    permissions readable = 1，value 初始 nil），挂到 FC94 服务上加进去。
/// 4. 系统读该特征时回 `[PSM 高字节][PSM 低字节]`，按 offset `dropFirst` 后 `setValue`。
/// 5. `didAdd service` 之后才 `startAdvertising`：
///    `ServiceUUIDs = ["FC94"]` + `LocalName = 设备名`。**无 Manufacturer Data。**
/// 6. L2CAP 通道建立（`didOpen`）后进入帧解析。
final class BLEBootstrap: NSObject {
    static let shared = BLEBootstrap()

    var onLog: ((String) -> Void)?
    /// L2CAP / GATT 上收到的原始字节（交给上层切 BLEFrame）。
    var onData: ((Data) -> Void)?

    static let serviceUUID = CBUUID(string: "0000FC94-0000-1000-8000-00805F9B34FB")
    static let advertisedServiceID = "FC94"
    static let psmCharacteristicUUID = CBUUID(string: "F20BFCDB-B5B1-484F-AFBA-29DDE86C972E")
    static let defaultDeviceName = "TDS_CAR_KIT-0001"

    private var manager: CBPeripheralManager?
    private var psmCharacteristic: CBMutableCharacteristic?
    private var service: CBMutableService?
    private var l2capChannel: CBL2CAPChannel?
    private var publishedPSM: UInt16 = 0
    private(set) var isAdvertising = false
    private(set) var isReady = false
    private var deviceName = BLEBootstrap.defaultDeviceName

    private override init() { super.init() }

    // MARK: - 启动 / 停止

    func start(deviceName: String? = nil) {
        runOnMain { [weak self] in
            guard let self else { return }
            if let deviceName, !deviceName.isEmpty {
                self.deviceName = deviceName
            }
            guard self.manager == nil else {
                self.onLog?("[BLE] 已在运行，忽略重复启动")
                return
            }
            self.onLog?("[BLE] 启动：service=\(BLEBootstrap.serviceUUID.uuidString) psmChar=\(BLEBootstrap.psmCharacteristicUUID.uuidString) name=\(self.deviceName)")
            self.manager = CBPeripheralManager(delegate: self, queue: .main, options: [
                CBPeripheralManagerOptionShowPowerAlertKey: false
            ])
        }
    }

    func stop() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.onLog?("[BLE] 停止")
            self.isAdvertising = false
            self.isReady = false
            if let manager = self.manager {
                manager.stopAdvertising()
                if let service = self.service {
                    manager.remove(service)
                }
                if self.publishedPSM != 0 {
                    manager.unpublishL2CAPChannel(self.publishedPSM)
                }
            }
            if let channel = self.l2capChannel {
                channel.inputStream?.close()
                channel.outputStream?.close()
            }
            self.l2capChannel = nil
            self.psmCharacteristic = nil
            self.service = nil
            self.manager?.delegate = nil
            self.manager = nil
            self.publishedPSM = 0
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - 内部流程

    private func publishPSM() {
        guard let manager, manager.state == .poweredOn, publishedPSM == 0 else { return }
        onLog?("[BLE] 发布 L2CAP 通道（不加密）")
        manager.publishL2CAPChannel(withEncryption: false)
    }

    private func attachService(psm: UInt16) {
        guard let manager, service == nil else { return }

        let characteristic = CBMutableCharacteristic(type: BLEBootstrap.psmCharacteristicUUID,
                                                     properties: [.read, .notify],
                                                     value: nil,
                                                     permissions: [.readable])
        psmCharacteristic = characteristic

        let newService = CBMutableService(type: BLEBootstrap.serviceUUID, primary: true)
        newService.characteristics = [characteristic]
        service = newService
        onLog?("[BLE] 添加服务 \(BLEBootstrap.serviceUUID.uuidString)（PSM=\(psm)）")
        manager.add(newService)
    }

    private func startAdvertising() {
        guard let manager, manager.state == .poweredOn, !isAdvertising else { return }
        let payload: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLEBootstrap.advertisedServiceID)],
            CBAdvertisementDataLocalNameKey: deviceName
        ]
        manager.startAdvertising(payload)
        isAdvertising = true
        isReady = true
        onLog?("[BLE] 开始广播：FC94 + LocalName=\(deviceName)")
    }

    private var psmBytes: Data {
        Data([UInt8((publishedPSM >> 8) & 0xFF), UInt8(publishedPSM & 0xFF)])
    }

    private func openChannel(_ channel: CBL2CAPChannel) {
        l2capChannel = channel
        onLog?("[BLE] L2CAP 通道已建立 psm=\(publishedPSM)")
        guard let input = channel.inputStream, let output = channel.outputStream else {
            onLog?("[BLE] L2CAP 通道流不可用")
            return
        }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .default)
        output.schedule(in: .main, forMode: .default)
        input.open()
        output.open()
    }

    private func readAvailable(_ stream: InputStream) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                onLog?("[BLE] ← L2CAP \(count)B")
                onData?(data)
            } else if count < 0 {
                onLog?("[BLE] 读取失败：\(stream.streamError?.localizedDescription ?? "未知")")
                return
            } else {
                return
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEBootstrap: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let stateName: String
        switch peripheral.state {
        case .poweredOn: stateName = "poweredOn"
        case .poweredOff: stateName = "poweredOff"
        case .unauthorized: stateName = "unauthorized"
        case .unsupported: stateName = "unsupported"
        case .resetting: stateName = "resetting"
        default: stateName = "unknown(\(peripheral.state.rawValue))"
        }
        onLog?("[BLE] 状态 → \(stateName)")

        if peripheral.state == .poweredOn {
            publishPSM()
        } else {
            isAdvertising = false
            isReady = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM,
                           error: Error?) {
        if let error {
            onLog?("[BLE] 发布 L2CAP 失败：\(error.localizedDescription)")
            return
        }
        publishedPSM = UInt16(PSM)
        onLog?("[BLE] L2CAP 已发布 PSM=\(PSM)")
        attachService(psm: UInt16(PSM))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if let error {
            onLog?("[BLE] 添加服务失败：\(error.localizedDescription)")
            return
        }
        onLog?("[BLE] 服务已添加，准备广播")
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onLog?("[BLE] 广播失败：\(error.localizedDescription)")
            isAdvertising = false
            return
        }
        onLog?("[BLE] 广播已开始（FC94）")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value = psmBytes
        let offset = request.offset
        guard offset <= value.count else {
            onLog?("[BLE] 读取 offset=\(offset) 越界（PSM 数据 \(value.count)B）")
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        let slice = Data(value.dropFirst(offset))
        request.value = slice
        peripheral.respond(to: request, withResult: .success)
        onLog?("[BLE] ← 读取 PSM offset=\(offset)，回 \(hex(slice))")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let value = request.value {
                onLog?("[BLE] ← 写入 \(value.count)B：\(hex(value))")
                onData?(value)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didOpen channel: CBL2CAPChannel?,
                           error: Error?) {
        if let error {
            onLog?("[BLE] L2CAP 打开失败：\(error.localizedDescription)")
            return
        }
        guard let channel else {
            onLog?("[BLE] L2CAP 通道为 nil")
            return
        }
        openChannel(channel)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        onLog?("[BLE] 中心设备 \(central.identifier.uuidString) 订阅 \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        onLog?("[BLE] 中心设备 \(central.identifier.uuidString) 取消订阅 \(characteristic.uuid.uuidString)")
    }
}

// MARK: - 流代理

extension BLEBootstrap: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if let input = aStream as? InputStream {
                readAvailable(input)
            }
        case .errorOccurred:
            onLog?("[BLE] 流错误：\(aStream.streamError?.localizedDescription ?? "未知")")
        case .endEncountered:
            onLog?("[BLE] 流结束")
        default:
            break
        }
    }
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}
