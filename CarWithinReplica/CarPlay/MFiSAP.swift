import Foundation
import CryptoKit
import CommonCrypto

/// MFiSAP —— 照原版 `TDSCarKit.MFiSAP.respond(to:identity:)` 反编译实现
/// （`analysis/msg.c` @ 0x10011aa58）。
///
/// 原版算法：
/// 1. 输入必须 **33 字节且首字节 0x01**，余下 32 字节是对方 Curve25519 公钥。
/// 2. 本地生成 Curve25519 临时私钥，做 ECDH 得到 sharedSecret。
/// 3. `AES Key = SHA1(shared ‖ "SEA-KEY")` 取前 16 字节；
///    `AES IV  = SHA1(shared ‖ "SEA-IV")`  取前 16 字节。
/// 4. 对我方 Curve25519 公钥做 `SHA256`，再用配件长期私钥做 P-256 ECDSA（RFC4754）签名。
/// 5. 用 AES-CTR(key, iv) 加密该签名。
/// 6. 输出 `[BE32 certChain.count][certChain][BE32 encSig.count][encSig]`。
enum MFiSAP {
    static func respond(to data: Data, identity: AccessoryIdentity) throws -> Data {
        guard data.count == 33, data.first == 0x01 else {
            throw ProtocolError.message("MFiSAP 输入必须是 33 字节且首字节 0x01（实际 \(data.count)B，首字节 \(data.first.map { String(format: "0x%02X", $0) } ?? "空")）")
        }

        let peerPublicData = Data(data[data.startIndex + 1 ..< data.startIndex + 33])
        let peerKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicData)
        } catch {
            throw ProtocolError.message("MFiSAP 对方公钥无效：\(error.localizedDescription)")
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret: Data
        do {
            sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)
                .withUnsafeBytes { Data($0) }
        } catch {
            throw ProtocolError.message("MFiSAP ECDH 失败：\(error.localizedDescription)")
        }

        let aesKey = Data(sha1(sharedSecret + Data("SEA-KEY".utf8))).prefix(16)
        let aesIV = Data(sha1(sharedSecret + Data("SEA-IV".utf8))).prefix(16)

        let ourPublic = ephemeral.publicKey.rawRepresentation
        let challenge = Data(SHA256.hash(data: ourPublic))
        let signature = try identity.sign(challenge: challenge)
        let encrypted = try aesCTR(key: Data(aesKey), iv: Data(aesIV), data: signature)

        let chain = identity.certificateChain ?? Data()
        var output = Data()
        output.append(be32(chain.count))
        output.append(chain)
        output.append(be32(encrypted.count))
        output.append(encrypted)
        return output
    }

    /// CryptoKit 不提供 SHA1（只有 SHA256 及以上），MFiSAP 规定用 SHA1，走 CommonCrypto。
    private static func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    private static func be32(_ value: Int) -> Data {        let v = UInt32(truncatingIfNeeded: value)
        return Data([UInt8((v >> 24) & 0xFF),
                     UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF),
                     UInt8(v & 0xFF)])
    }

    /// AES-CTR（大端计数器），与 Apple 的 CCCrypt 默认行为一致。
    private static func aesCTR(key: Data, iv: Data, data: Data) throws -> Data {
        guard data.count <= 0x10000 else {
            throw ProtocolError.message("MFiSAP 待加密数据过长：\(data.count)B")
        }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                        CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding),
                                        ivBytes.baseAddress,
                                        keyBytes.baseAddress,
                                        key.count,
                                        nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw ProtocolError.message("AES-CTR 初始化失败（\(createStatus)）")
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let updateStatus = data.withUnsafeBytes { inBytes -> CCCryptorStatus in
            output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
                CCCryptorUpdate(cryptor,
                                inBytes.baseAddress,
                                data.count,
                                outBytes.baseAddress,
                                outBytes.count,
                                &moved)
            }
        }
        guard updateStatus == kCCSuccess else {
            throw ProtocolError.message("AES-CTR 加密失败（\(updateStatus)）")
        }
        return Data(output.prefix(moved))
    }
}
