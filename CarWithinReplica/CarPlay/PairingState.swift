import Foundation

/// 配对与认证状态机。
/// 状态号与字段来自原版运行日志：Pair-Setup 1 / 3 / 5、Pair-Verify、auth-setup。
final class PairingState {
    static let shared = PairingState()

    private(set) var setupState: UInt8 = 1
    private(set) var verifiedController = false
    private(set) var mfiAccepted = false
    private(set) var sessionUUID = UUID().uuidString
    private var sharedSecret: Data?

    private init() {}

    /// /pair-setup：返回下一阶段所需的 TLV8。
    func pairSetup(_ body: Data) -> Data {
        let items = TLV8.decode(body)
        let requested = items.first(where: { $0.type == 0x06 })?.value.first ?? 1
        setupState = min(UInt8(max(1, Int(requested))), 5)
        var response: [TLV8.Item] = [.init(type: 0x06, value: Data([setupState]))]
        if setupState == 3 {
            // SRP salt / 服务端公钥占位：真机验证时按 iPhone 的挑战替换
            sharedSecret = Data(repeating: 0xA5, count: 32)
            response.append(.init(type: 0x03, value: Data(repeating: 0x11, count: 16)))
            response.append(.init(type: 0x04, value: BonjourPublisher.shared.publicKeyData))
        }
        if setupState == 5 {
            verifiedController = true
            response.append(.init(type: 0x05, value: Data(repeating: 0x22, count: 64)))
        }
        return TLV8.encode(response)
    }

    /// /pair-verify：控制端证明自己，完成后启用加密控制。
    func pairVerify(_ body: Data) -> Data {
        verifiedController = true
        return TLV8.encode([
            .init(type: 0x06, value: Data([2])),
            .init(type: 0x03, value: BonjourPublisher.shared.publicKeyData),
        ])
    }

    /// /auth-setup：用 MFi 私钥对挑战签名，生成 MFiSAP 响应。
    func authSetup(_ body: Data) -> Data {
        let items = TLV8.decode(body)
        let challenge = items.first(where: { $0.type == 0x01 })?.value
            ?? Data("CarWithin-MFiSAP".utf8)
        guard let signature = MFIIdentity.shared.sign(challenge) else {
            return TLV8.encode([.init(type: 0x06, value: Data([0]))])
        }
        mfiAccepted = true
        return TLV8.encode([
            .init(type: 0x01, value: signature),
            .init(type: 0x02, value: MFIIdentity.shared.chainData ?? Data()),
        ])
    }

    func reset() {
        setupState = 1
        verifiedController = false
        mfiAccepted = false
        sharedSecret = nil
        sessionUUID = UUID().uuidString
    }
}
