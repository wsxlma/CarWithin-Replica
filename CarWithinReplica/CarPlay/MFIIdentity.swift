import Foundation
import CryptoKit
import Security

/// MFi 身份材料加载器。
///
/// 约定文件名（放在 App 的 Documents 目录，或打进 Bundle）：
/// - `certificate.p7b`  Apple 签发的证书链
/// - `leaf.cer`         配件叶子证书（DER）
/// - `private.x963`     P-256 私钥（32 字节标量，或 0x04 开头的 65 字节）
final class MFIIdentity {
    static let shared = MFIIdentity()

    private(set) var leaf: SecCertificate?
    private(set) var chainData: Data?
    private(set) var privateKey: P256.Signing.PrivateKey?
    private(set) var isReady = false

    private init() {}

    /// 优先 Documents（可用文件 App 拷入），其次 Bundle。
    func load() -> [String] {
        var steps: [String] = []

        guard let leafURL = locate("leaf.cer") else {
            return ["未找到 leaf.cer"]
        }
        guard let leafData = try? Data(contentsOf: leafURL),
              let certificate = SecCertificateCreateWithData(nil, leafData as CFData) else {
            return ["leaf.cer 解析失败"]
        }
        leaf = certificate

        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "未知"
        steps.append("叶子证书：\(summary)")

        if let p7bURL = locate("certificate.p7b"), let p7b = try? Data(contentsOf: p7bURL) {
            chainData = p7b
            steps.append("证书链：\(p7b.count) 字节")
        } else {
            steps.append("缺少 certificate.p7b")
        }

        guard let keyURL = locate("private.x963") else {
            return steps + ["未找到 private.x963"]
        }
        guard let keyData = try? Data(contentsOf: keyURL) else {
            return steps + ["private.x963 读取失败"]
        }

        // 私钥可能是裸标量、x963、base64 文本或 DER，逐个尝试。
        let normalized = Self.normalize(keyData)
        steps.append("私钥原始 \(keyData.count)B，归一化 \(normalized.count)B")

        var scalar: Data?
        if normalized.count == 32 {
            scalar = normalized
        } else if normalized.count == 65, normalized.first == 0x04 {
            scalar = normalized.dropFirst()
        } else {
            // 交给 Security 解析 DER/PKCS#8
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256,
            ]
            var error: Unmanaged<CFError>?
            if let secKey = SecKeyCreateWithData(normalized as CFData, attributes as CFDictionary, &error),
               let raw = SecKeyCopyExternalRepresentation(secKey, &error) as Data? {
                if raw.count == 32 {
                    scalar = raw
                } else if raw.count == 65, raw.first == 0x04 {
                    scalar = raw.dropFirst()
                }
            } else if let error = error?.takeRetainedValue() {
                steps.append("Security 解析失败：\(error.localizedDescription)")
            }
        }

        guard let scalar, scalar.count == 32,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar) else {
            return steps + ["私钥格式仍不支持（首位 \(Self.hexPrefix(normalized))）"]
        }
        privateKey = key
        steps.append("私钥：P-256 已载入")

        // 私钥与叶子证书是否匹配：比对公钥的 X9.63 表示
        if let leafKey = SecCertificateCopyKey(certificate),
           let leafPublic = SecKeyCopyExternalRepresentation(leafKey, nil) as Data? {
            let ours = key.publicKey.x963Representation
            if leafPublic == ours {
                steps.append("私钥与证书匹配")
                isReady = true
            } else {
                steps.append("私钥与证书不匹配（leaf \(leafPublic.count)B / ours \(ours.count)B）")
            }
        } else {
            steps.append("无法读取证书公钥")
        }

        return steps
    }

    /// 用私钥对挑战签名，供 iAP2 认证使用。
    func sign(_ data: Data) -> Data? {
        guard let privateKey else { return nil }
        return try? privateKey.signature(for: data).derRepresentation
    }

    /// PEM -> base64 -> 原样，三种形式归一。
    private static func normalize(_ data: Data) -> Data {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("-----BEGIN") {
                let body = trimmed
                    .split(separator: "\n")
                    .filter { !$0.hasPrefix("-----") }
                    .joined()
                if let decoded = Data(base64Encoded: body) { return decoded }
            }
            if trimmed.allSatisfy({ $0.isASCII && !$0.isNewline ? $0.isLetter || $0.isNumber || "+/=".contains($0) : true }),
               let decoded = Data(base64Encoded: trimmed) {
                return decoded
            }
        }
        return data
    }

    private static func hexPrefix(_ data: Data, count: Int = 8) -> String {
        data.prefix(count).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func locate(_ name: String) -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = documents?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext)
    }
}
