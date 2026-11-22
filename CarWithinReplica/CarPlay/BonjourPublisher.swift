import Foundation
import CryptoKit

/// 自建端点第一步：把本机广播成一个 AirPlay / CarWithin 车机，
/// 让同一台 iPhone 的 CarPlay 栈主动连进来（原版日志证据）。
final class BonjourPublisher: NSObject, NetServiceDelegate {
    static let shared = BonjourPublisher()
    var onLog: ((String) -> Void)?

    private var services: [NetService] = []
    private let pairingKey = Curve25519.KeyAgreement.PrivateKey()

    private override init() { super.init() }

    var publicKeyData: Data { pairingKey.publicKey.rawRepresentation }

    func start(name: String = "CarWithin", port: Int32 = 7000) {
        stop()
        let txt: [String: Data] = [
            "deviceid": Data("AA:BB:CC:DD:EE:FF".utf8),
            "features": Data("0x5A7FFFF7,0x1E".utf8),
            "flags": Data("0x4".utf8),
            "model": Data("CarWithin1,1".utf8),
            "name": Data(name.utf8),
            "manufacturer": Data("CarWithin".utf8),
            "serialNumber": Data("CW0001".utf8),
            "protovers": Data("1.1".utf8),
            "srcvers": Data("700.1".utf8),
            "vv": Data("2".utf8),
            "pi": Data(UUID().uuidString.utf8),
            "pk": pairingKey.publicKey.rawRepresentation,
            "gid": Data("CarWithin".utf8),
        ]
        for type in ["_airplay._tcp.", "_tds-carkit._tcp."] {
            let service = NetService(domain: "local.", type: type, name: name, port: port)
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            service.delegate = self
            service.publish()
            services.append(service)
            onLog?("Bonjour 发布 \(type) → 端口 \(port)")
        }
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
