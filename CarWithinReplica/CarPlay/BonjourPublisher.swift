import Foundation
import CryptoKit

/// 自建端点第一步：把本机广播成一个 AirPlay / CarWithin 车机，
/// 让同一台 iPhone 的 CarPlay 栈主动连进来（原版日志证据）。
///
/// TXT 记录里的车机能力字段全部来自设置页（车辆名称、外观、驾驶位、
/// 编码、分辨率、图标大小…），改设置后调用 republish() 立即生效。
final class BonjourPublisher: NSObject, NetServiceDelegate {
    static let shared = BonjourPublisher()
    var onLog: ((String) -> Void)?

    private var services: [NetService] = []
    private let pairingKey = Curve25519.KeyAgreement.PrivateKey()
    private var currentPort: Int32 = 7000

    private override init() { super.init() }

    var publicKeyData: Data { pairingKey.publicKey.rawRepresentation }

    func start(name: String? = nil, port: Int32 = 7000) {
        stop()
        currentPort = port
        let serviceName = name ?? CarPlayConfiguration.vehicleName
        let txt = CarPlayConfiguration.txtRecord(pairingKey: pairingKey.publicKey.rawRepresentation)

        for type in ["_airplay._tcp.", "_tds-carkit._tcp."] {
            let service = NetService(domain: "local.", type: type, name: serviceName, port: port)
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            service.delegate = self
            service.publish()
            services.append(service)
            onLog?("Bonjour 发布 \(serviceName).\(type) → 端口 \(port)")
        }
        onLog?("车辆能力：\(CarPlayConfiguration.codecName) / \(CarPlayConfiguration.displayWidth)×\(CarPlayConfiguration.displayHeight)"
               + " / 夜间模式 \(CarPlayConfiguration.nightMode) / \(CarPlayConfiguration.rightHandDrive ? "右舵" : "左舵")")
    }

    /// 设置变更后重新广播（名称、编码、比例等变化时调用）。
    func republish() {
        guard !services.isEmpty else { return }
        onLog?("配置已变更，重新发布 Bonjour 服务")
        start(port: currentPort)
    }

    func stop() {
        services.forEach { $0.stop() }
        services.removeAll()
    }

    func netServiceDidPublish(_ sender: NetService) {
        onLog?("Bonjour 注册成功：\(sender.name).\(sender.type)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onLog?("Bonjour 注册失败：\(errorDict)")
    }
}
