import Foundation
import CryptoKit

/// AirPlay 配对状态机：Pair-Setup（SRP-6a）→ Pair-Verify（Curve25519/Ed25519）
/// → auth-setup（MFiSAP），通过后派生加密控制通道密钥。
final class PairingState {
    static let shared = PairingState()

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

    /// SRP 口令：由 MFi 身份对固定标签签名派生，保证双方一致。
    private var srpPassword: Data {
        MFIIdentity.shared.sign(Data("Pair-Setup".utf8)) ?? Data("CarWithin".utf8)
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
            guard let clientKeyData = items.first(where: { $0.type == 0x03 })?.value else {
                return TLV8.encode([.init(type: 0x06, value: Data([2]))])
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKeyData)
            let shared = (clientKey.flatMap {
                try? ephemeral.sharedSecretFromKeyAgreement(with: $0)
            })?.withUnsafeBytes { Data($0) }
            verifyShared = shared

            let serverPublic = ephemeral.publicKey.rawRepresentation
            let message = serverPublic + signingKey.publicKey.rawRepresentation + clientKeyData
            let signature = (try? signingKey.signature(for: message)) ?? Data()
            let encrypted = encrypt(payload: signature, shared: shared)

            return TLV8.encode([
                .init(type: 0x06, value: Data([2])),
                .init(type: 0x03, value: serverPublic),
                .init(type: 0x05, value: encrypted),
            ])

        case 3:
            verifiedController = true
            controlKey = deriveControlKey(shared: verifyShared)
            return TLV8.encode([.init(type: 0x06, value: Data([4]))])

        default:
            return TLV8.encode([.init(type: 0x06, value: Data([state]))])
        }
    }

    // MARK: - auth-setup（MFiSAP）

    func authSetup(_ body: Data) -> Data {
        let items = TLV8.decode(body)
        let challenge: Data
        if let item = items.first(where: { $0.type == 0x01 }) {
            challenge = item.value
        } else {
            challenge = Data("CarWithin-MFiSAP".utf8)
        }
        guard let signature = MFIIdentity.shared.sign(challenge) else {
            return TLV8.encode([.init(type: 0x06, value: Data([0]))])
        }
        mfiAccepted = true
        return TLV8.encode([
            .init(type: 0x01, value: signature),
            .init(type: 0x02, value: MFIIdentity.shared.chainData ?? Data()),
        ])
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
        return HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: Data("Pair-Verify".utf8),
            info: Data("Control-Salt".utf8),
            outputByteCount: 32)
    }

    func reset() {
        setupState = 1
        verifiedController = false
        mfiAccepted = false
        controlKey = nil
        verifyShared = nil
        srpSalt = Data()
        srpPrivate = BigUInt(0)
        srpVerifier = BigUInt(0)
        srpPublicB = BigUInt(0)
        srpPublicA = BigUInt(0)
        srpSessionKey = Data()
        srpProof = Data()
    }
}
