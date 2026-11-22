import Foundation
import CryptoKit

/// 自建端点第一步：把本机广播成一个 AirPlay / CarWithin 车机，
/// 让同一台 iPhone 的 CarPlay 栈主动连进来（原版日志证据）。
///
/// 两条路都广播：_carplay._tcp（标准无线 CarPlay）与 _airplay._tcp（原版走的
/// AirPlay 协议路径）。TXT 只放 iOS 认的标准字段，车机配置走 /info 与 iAP2。
/// 服务名取自车辆名称设置，改设置后调用 republish() 立即生效。
final class BonjourPublisher: NSObject, NetServiceDelegate {
    static let shared = BonjourPublisher()
    var onLog: ((String) -> Void)?

    private var services: [NetService] = []
    private var confirmed = Set<ObjectIdentifier>()
    private let pairingKey = Curve25519.KeyAgreement.PrivateKey()
    private var currentPort: Int32 = 7000

    private override init() { super.init() }

    var publicKeyData: Data { pairingKey.publicKey.rawRepresentation }

    func start(name: String? = nil, port: Int32 = 7000) {
        // NetService 的 delegate 回调依赖 runloop。在 Task / 后台线程上 publish
        // 会让 didPublish/didNotPublish 永远不来、服务也注册不上——必须回到主线程。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start(name: name, port: port) }
            return
        }
        stop()
        currentPort = port
        let serviceName = name ?? CarPlayConfiguration.vehicleName
        let txt = CarPlayConfiguration.txtRecord(pairingKey: pairingKey.publicKey.rawRepresentation)

        // 严格照原版 Info.plist 的三条服务类型（原版**没有** _carplay._tcp，
        // 也没有 _apple-mobdev2._tcp）。之前多发的两个既无依据又容易引发注册冲突。
        let types = [
            "_airplay._tcp.",
            "_tds-carkit._tcp.",
            "_carplay-ctrl._tcp.",
        ]
        for type in types {
            let service = NetService(domain: "local.", type: type, name: serviceName, port: port)
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            service.delegate = self
            service.publish()
            services.append(service)
            onLog?("Bonjour 发布 \(serviceName).\(type) → 端口 \(port)")
        }
        onLog?("车辆能力：\(CarPlayConfiguration.codecName) / \(CarPlayConfiguration.displayWidth)×\(CarPlayConfiguration.displayHeight)"
               + " / 夜间模式 \(CarPlayConfiguration.nightMode) / \(CarPlayConfiguration.rightHandDrive ? "右舵" : "左舵")")

        // 3 秒后核对每个服务是否真的发布了，避免「打印了发布、实际没上」
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.services.isEmpty else { return }
            let pending = self.services.filter { !self.confirmed.contains(ObjectIdentifier($0)) }
            if !pending.isEmpty {
                self.onLog?("Bonjour 有 \(pending.count) 个服务未确认发布，请检查本地网络权限（设置 → 隐私与安全性 → 本地网络）")
            }
        }
    }

    /// 设置变更后重新广播（名称、编码、比例等变化时调用）。
    func republish() {
        guard !services.isEmpty else { return }
        onLog?("配置已变更，重新发布 Bonjour 服务")
        start(port: currentPort)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        services.forEach { $0.stop() }
        services.removeAll()
        confirmed.removeAll()
    }

    func netServiceDidPublish(_ sender: NetService) {
        confirmed.insert(ObjectIdentifier(sender))
        onLog?("Bonjour 注册成功：\(sender.name).\(sender.type)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        confirmed.insert(ObjectIdentifier(sender))
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        var message = "Bonjour 注册失败：\(sender.type) \(errorDict)"
        if code == -72008 {
            message += "\n这是本地网络权限被拒绝：请到 设置 → 隐私与安全性 → 本地网络，打开 CarWithin 的开关"
        } else if code == -72001 {
            message += "\n服务名冲突，稍后重试"
        }
        onLog?(message)
    }
}
