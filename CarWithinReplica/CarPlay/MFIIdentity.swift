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
    /// 证书主题里的 IPA 编号，用作 ACC 的配件标识符。
    private(set) var identifier = "CarWithin"

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
        identifier = summary
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

        // 私钥候选：依次尝试，用叶子证书的公钥验证，匹配的才算数。
        let normalized = Self.normalize(keyData)
        var candidates: [Data] = []
        if normalized.count == 32 { candidates.append(normalized) }
        if normalized.count > 32 { candidates.append(normalized.suffix(32)) }
        if normalized.first == 0x04, normalized.count > 33 {
            candidates.append(normalized.dropFirst().prefix(32))
        }
        steps.append("私钥 \(keyData.count)B → 归一化 \(normalized.count)B，候选 \(candidates.count) 个")

        var leafPublic: Data?
        if let leafKey = SecCertificateCopyKey(certificate) {
            leafPublic = SecKeyCopyExternalRepresentation(leafKey, nil) as Data?
        }

        var matched: P256.Signing.PrivateKey?
        for candidate in candidates {
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: candidate) else { continue }
            if let leafPublic, key.publicKey.x963Representation == leafPublic {
                matched = key
                steps.append("私钥与证书匹配（候选 \(candidate.count)B）")
                break
            }
        }

        guard let key = matched else {
            return steps + ["所有候选都不匹配（首位 \(Self.hexPrefix(normalized))）"]
        }
        privateKey = key

        isReady = true

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
