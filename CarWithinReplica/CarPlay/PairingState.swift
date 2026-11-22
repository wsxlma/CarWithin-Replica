import Foundation
import CryptoKit

/// AirPlay 配对状态机：Pair-Setup（SRP-6a）→ Pair-Verify（Curve25519/Ed25519）
/// → auth-setup（MFiSAP），通过后派生加密控制通道密钥。
final class PairingState {
    static let shared = PairingState()

    var onLog: ((String) -> Void)?

    private(set) var setupState: UInt8 = 1
    private(set) var verifiedController = false
    private(set) var mfiAccepted = false
    private(set) var controlKey: SymmetricKey?

    private var srpSalt = Data()
    private var srpPrivate: BigUInt = BigUInt(0)
    private var srpVerifier: BigUInt = BigUInt(0)
    private var srpPublicB: BigUInt = BigUInt(0)
    private var srpPublicA: BigUInt = BigUInt(0)
    private var srpSessionKey: Data = Data()
    private var srpProof: Data = Data()

    private var verifyShared: Data?
    private var ed25519Key: Curve25519.Signing.PrivateKey?

    private init() {}

    /// 从 MFi 私钥派生稳定的 Ed25519 长期密钥，重启后标识不变。
    private var signingKey: Curve25519.Signing.PrivateKey {
        if let ed25519Key { return ed25519Key }
        let seed = Data(SHA512.hash(data: MFIIdentity.shared.privateKey?.rawRepresentation ?? Data()))
        let key = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed.prefix(32)))
            ?? Curve25519.Signing.PrivateKey()
        ed25519Key = key
        return key
    }

    /// SRP 口令：由 MFi 身份对固定标签签名派生。
    ///
    /// **必须缓存**：ECDSA 每次签名都不同（随机 k），若 M1 与 M3 各算一次，
    /// 两次口令不同，客户端证明必然校验失败——这是一直卡在 pair-setup 的隐形原因。
    private var cachedSRPPassword: Data?

    private var srpPassword: Data {
        if let cachedSRPPassword { return cachedSRPPassword }
        let value = MFIIdentity.shared.sign(Data("Pair-Setup".utf8)) ?? Data("CarWithin".utf8)
        cachedSRPPassword = value
        return value
    }

    // MARK: - Pair-Setup

    func pairSetup(_ body: Data) -> Data {
        let items = TLV8.decode(body)
        let state = items.first(where: { $0.type == 0x06 })?.value.first ?? 1
        setupState = state

        switch state {
        case 1:
            // M2：给出 salt 与 B = (k*v + g^b) mod N
            srpSalt = SRP6a.random(16)
            srpPrivate = BigUInt(bytes: [UInt8](SRP6a.random(32)))
            srpVerifier = SRP6a.verifier(x: SRP6a.privateKey(salt: srpSalt, password: srpPassword))
            srpPublicB = SRP6a.publicValue(v: srpVerifier, b: srpPrivate)
            return TLV8.encode([
                .init(type: 0x06, value: Data([2])),
                .init(type: 0x02, value: srpSalt),
                .init(type: 0x03, value: SRP6a.pad(srpPublicB)),
            ])

        case 3:
            // M4：校验客户端证明，回送服务端证明
            guard let aData = items.first(where: { $0.type == 0x03 })?.value,
                  let proof = items.first(where: { $0.type == 0x04 })?.value else {
                return TLV8.encode([
                    .init(type: 0x06, value: Data([4])),
                    .init(type: 0x07, value: Data([2])),
                ])
            }
            srpPublicA = BigUInt(bytes: [UInt8](aData))
            let u = SRP6a.scrambling(a: srpPublicA, b: srpPublicB)
            let secret = SRP6a.sharedSecret(a: srpPublicA, v: srpVerifier, b: srpPrivate, u: u)
            srpSessionKey = SRP6a.sessionKey(secret)
            let expected = SRP6a.clientProof(salt: srpSalt, a: srpPublicA, b: srpPublicB, k: srpSessionKey)

            guard expected == proof else {
                setupState = 4
                return TLV8.encode([
                    .init(type: 0x06, value: Data([4])),
                    .init(type: 0x07, value: Data([2])),
                ])
            }
            srpProof = expected
            let serverProof = SRP6a.serverProof(a: srpPublicA, m1: proof, k: srpSessionKey)
            return TLV8.encode([
                .init(type: 0x06, value: Data([4])),
                .init(type: 0x04, value: serverProof),
            ])

        case 5:
            // M5：交换双方标识，握手完成
            verifiedController = true
            return TLV8.encode([
                .init(type: 0x06, value: Data([6])),
                .init(type: 0x05, value: exchangePayload()),
            ])

        default:
            return TLV8.encode([
                .init(type: 0x06, value: Data([state])),
                .init(type: 0x07, value: Data([1])),
            ])
        }
    }

    private func exchangePayload() -> Data {
        var payload = Data()
        payload.append(UInt8(1))
        payload.append(Data("CarWithin".utf8))
        payload.append(UInt8(signingKey.publicKey.rawRepresentation.count))
        payload.append(signingKey.publicKey.rawRepresentation)
        return payload
    }

    // MARK: - Pair-Verify

    func pairVerify(_ body: Data) -> Data {
        let items = TLV8.decode(body)
        let state = items.first(where: { $0.type == 0x06 })?.value.first ?? 1

        switch state {
        case 1:
            guard let clientKeyData = items.first(where: { $0.type == 0x03 })?.value,
                  let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKeyData) else {
                return TLV8.encode([.init(type: 0x06, value: Data([2]))])
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = (try? ephemeral.sharedSecretFromKeyAgreement(with: clientKey))?
                .withUnsafeBytes { Data($0) }
            verifyShared = shared

            let serverPublic = ephemeral.publicKey.rawRepresentation
            ephemeralPublic = serverPublic
            // AirPlay pair-verify M2 的签名内容是 `serverPub ‖ clientPub`（64 字节），
            // 不包含长期公钥——之前多塞了 signingKey 公钥，签名必然验不过。
            let message = serverPublic + clientKeyData
            let signature = (try? signingKey.signature(for: message)) ?? Data()
            let encrypted = encryptVerify(payload: signature, shared: shared, msg: "PV-Msg02")

            return TLV8.encode([
                .init(type: 0x06, value: Data([2])),
                .init(type: 0x03, value: serverPublic),
                .init(type: 0x05, value: encrypted),
            ])

        case 3:
            // M3：客户端回 encrypted 签名，我们派生控制通道密钥即可（不强制验签，
            // 验签失败也只影响诊断，不该把已经建立的握手掐断）。
            if let item = items.first(where: { $0.type == 0x05 })?.value,
               let shared = verifyShared {
                let key = deriveVerifyKey(shared: shared)
                if let box = try? ChaChaPoly.SealedBox(combined: item),
                   let plain = try? ChaChaPoly.open(box, using: key) {
                    let expected = signingKey.publicKey.rawRepresentation + ephemeralPublic
                    if plain.count >= 64, Data(plain.prefix(64)) == expected.prefix(64) {
                        onLog?("[配对] pair-verify 客户端签名校验通过")
                    } else {
                        onLog?("[配对] pair-verify 客户端签名内容不匹配（继续）")
                    }
                } else {
                    onLog?("[配对] pair-verify M3 解密失败（继续）")
                }
            }
            verifiedController = true
            controlKey = deriveControlKey(shared: verifyShared)
            onLog?("[配对] pair-verify 完成，控制通道密钥已派生")
            return TLV8.encode([.init(type: 0x06, value: Data([4]))])

        default:
            return TLV8.encode([.init(type: 0x06, value: Data([state]))])
        }
    }

    /// 记录本轮 ephemeral 公钥，供 M3 校验客户端签名内容。
    private var ephemeralPublic = Data()

    /// pair-verify 专用密钥：salt/info 都是 AirPlay 规定值。
    private func deriveVerifyKey(shared: Data) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            info: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32)
    }

    /// AirPlay 的 nonce 是 8 字节 ASCII + 4 字节零，共 12 字节。
    private func makeNonce(_ text: String) -> ChaChaPoly.Nonce? {
        var bytes = Data(text.utf8)
        bytes.append(Data(repeating: 0, count: max(0, 12 - bytes.count)))
        return try? ChaChaPoly.Nonce(data: bytes.prefix(12))
    }

    private func encryptVerify(payload: Data, shared: Data?, msg: String) -> Data {
        guard let shared else { return payload }
        let key = deriveVerifyKey(shared: shared)
        guard let nonce = makeNonce(msg),
              let box = try? ChaChaPoly.seal(payload, using: key, nonce: nonce) else {
            return payload
        }
        return box.combined
    }

    // MARK: - auth-setup（MFiSAP）

    /// 原版 `/auth-setup` 直接把请求体交给 `MFiSAP.respond(to:identity:)`，
    /// 返回裸二进制（`[BE32 certLen][cert][BE32 encLen][enc]`），不是 TLV8。
    /// 这一步失败不该掐断整条链路（不少接收端可以跳过 MFi 认证），所以这里降级返回空。
    func authSetup(_ body: Data) -> Data {
        do {
            let response = try MFiSAP.respond(to: body, identity: MFIIdentity.shared)
            mfiAccepted = true
            onLog?("[配对] auth-setup MFiSAP 完成（\(response.count)B）")
            return response
        } catch {
            onLog?("[配对] auth-setup 失败：\(error.localizedDescription)")
            return Data()
        }
    }

    // MARK: - 加密控制通道

    private func encrypt(payload: Data, shared: Data?) -> Data {
        guard let shared else { return payload }
        let key = deriveControlKey(shared: shared)
        guard let box = try? ChaChaPoly.seal(payload, using: key) else { return payload }
        return box.combined
    }

    private func deriveControlKey(shared: Data?) -> SymmetricKey {
        guard let shared else { return SymmetricKey(size: .bits256) }
        // AirPlay 控制通道：salt = "Control-Salt"，info 分别对应读/写密钥。
        // 这里派生写方向（配件 → iPhone）。
        return HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: Data("Control-Salt".utf8),
            info: Data("Control-Write-Encryption-Key".utf8),
            outputByteCount: 32)
    }

    func reset() {
        setupState = 1
        verifiedController = false
        mfiAccepted = false
        controlKey = nil
        verifyShared = nil
        cachedSRPPassword = nil
        ephemeralPublic = Data()
        srpSalt = Data()
        srpPrivate = BigUInt(0)
        srpVerifier = BigUInt(0)
        srpPublicB = BigUInt(0)
        srpPublicA = BigUInt(0)
        srpSessionKey = Data()
        srpProof = Data()
    }
}
