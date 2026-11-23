import Foundation
import CryptoKit
import Security

/// 协议层错误 —— 照原版 `TDSCarKit.ProtocolError` 的语义实现。
enum ProtocolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// MFi 身份材料 —— 照原版 `TDSCarKit.AccessoryIdentity` 实现。
///
/// 原版字段布局（从 `sign(challenge:)` 反编译确认）：
/// - `+0x10` `certificateChain: Data`（0xAA01 直接回这个）
/// - `+0x20` `privateKey: SecKey`
///
/// `sign(challenge:)` 用的是 `SecKeyCreateSignature` +
/// `kSecKeyAlgorithmECDSASignatureRFC4754`，**输入必须是 32 字节**（否则抛
/// "MFi v3 challenge must be 32 bytes"），输出 64 字节 R‖S（RFC4754 裸签名，不是 DER）。
/// 这里不能用 CryptoKit 的 `signature(for:)`——它会对入参再做一次 SHA256。
final class AccessoryIdentity {
    static let shared = AccessoryIdentity()

    /// 主线程（设置页）与 CarPlay 后台队列都会访问，所有状态读写统一走这把锁。
    private let lock = NSRecursiveLock()

    private(set) var certificateChain: Data?
    private(set) var leafCertificate: SecCertificate?
    private(set) var secKey: SecKey?
    /// 仅供离线自检/公钥比对，签名一律走 SecKey。
    private(set) var p256Key: P256.Signing.PrivateKey?
    private(set) var isReady = false
    /// 证书主题摘要，用作 ACC 的配件标识符。
    private(set) var identifier = "CarWithin"

    private init() {}

    // MARK: - 旧接口兼容

    var chainData: Data? { certificateChain }
    var privateKey: P256.Signing.PrivateKey? { p256Key }

    // MARK: - 载入

    func load() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var steps: [String] = []

        // 先全部解析到局部变量，成功后才一次性提交。
        // 这样设置页反复调用 load() 时，正在进行的 CarPlay 会话不会看到 secKey 被临时清空。
        guard let leafURL = locate("leaf.cer") else {
            return ["未找到 leaf.cer"] + Self.importHint.components(separatedBy: "\n")
        }
        guard let leafData = try? Data(contentsOf: leafURL),
              let certificate = SecCertificateCreateWithData(nil, leafData as CFData) else {
            return ["leaf.cer 解析失败"] + Self.importHint.components(separatedBy: "\n")
        }

        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "未知"
        steps.append("叶子证书：\(summary)")

        var newChain: Data?
        if let p7bURL = locate("certificate.p7b"), let p7b = try? Data(contentsOf: p7bURL) {
            newChain = p7b
            steps.append("证书链：\(p7b.count) 字节")
        } else {
            steps.append("缺少 certificate.p7b（0xAA01 将无内容可回）")
        }

        guard let keyURL = locate("private.x963") else {
            return steps + ["未找到 private.x963"] + Self.importHint.components(separatedBy: "\n")
        }
        guard let keyData = try? Data(contentsOf: keyURL) else {
            return steps + ["private.x963 读取失败"]
        }

        let normalized = Self.normalize(keyData)
        steps.append("私钥 \(keyData.count)B → 归一化 \(normalized.count)B")

        var leafPublic: Data?
        if let leafKey = SecCertificateCopyKey(certificate) {
            leafPublic = SecKeyCopyExternalRepresentation(leafKey, nil) as Data?
        }

        // 原版 private.x963 是 97 字节的 SEC1/x9.63 私钥：0x04 ‖ X(32) ‖ Y(32) ‖ D(32)。
        // SecKeyCreateWithData 正好吃这个长度；同时把 D（末 32 字节）交给 CryptoKit 便于公钥比对。
        var x963Candidate = Data()
        var newP256: P256.Signing.PrivateKey?
        if normalized.count == 97, normalized.first == 0x04 {
            x963Candidate = normalized
            let scalar = normalized.suffix(32)
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar) {
                newP256 = key
                let match = key.publicKey.x963Representation == normalized.prefix(65)
                steps.append("x963 97B：末 32 字节作标量，公钥前 65B 比对\(match ? "一致" : "不一致")")
            }
        } else if normalized.count == 32 {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: normalized) {
                newP256 = key
                x963Candidate = key.x963Representation
                steps.append("裸 32B 标量：已重建 x963 \(x963Candidate.count)B")
            }
        } else if normalized.count == 65, normalized.first == 0x04 {
            steps.append("私钥文件是 65B 公钥格式，无法用于签名（需要 97B 含私钥标量）")
        } else {
            steps.append("私钥长度 \(normalized.count)B 未被识别（期望 97 或 32）")
        }

        var matchedKey: SecKey?
        if !x963Candidate.isEmpty {
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256
            ]
            matchedKey = SecKeyCreateWithData(x963Candidate as CFData,
                                              attributes as CFDictionary,
                                              &error)
            if matchedKey == nil, let error {
                steps.append("SecKeyCreateWithData 失败：\(error.takeRetainedValue())")
            }
        }

        if newP256 == nil, let key = matchedKey,
           let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? {
            steps.append("SecKey 就绪，公钥 \(raw.count)B")
        }

        if let leafPublic, let key = matchedKey,
           let publicRaw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
           publicRaw != leafPublic {
            steps.append("警告：私钥公钥与叶子证书不一致（可能不是同一套 MFi 材料）")
        }

        guard let key = matchedKey else {
            return steps + ["私钥无法构造 SecKey（首位 \(Self.hexPrefix(normalized))）"] + Self.importHint.components(separatedBy: "\n")
        }

        // 解析全部成功，原子提交。
        certificateChain = newChain
        leafCertificate = certificate
        p256Key = newP256
        secKey = key
        identifier = summary
        isReady = true
        steps.append("签名私钥就绪（RFC4754，P-256）")
        return steps
    }

    // MARK: - 签名

    /// 严格版：iAP2 MFi v3 认证，输入必须 32 字节。
    func sign(challenge: Data) throws -> Data {
        guard challenge.count == 32 else {
            throw ProtocolError.message("MFi v3 challenge must be 32 bytes, got \(challenge.count)")
        }
        lock.lock()
        let key = secKey
        lock.unlock()
        guard let key else {
            throw ProtocolError.message("签名私钥未就绪")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key,
                                                    .ecdsaSignatureRFC4754,
                                                    challenge as CFData,
                                                    &error) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "未知"
            throw ProtocolError.message("SecKeyCreateSignature 失败：\(reason)")
        }
        return signature as Data
    }

    /// 宽松版：任意长度输入，先归一成 32 字节再签（自检、配对等非 iAP2 场景）。
    func sign(_ data: Data) -> Data? {
        let challenge: Data
        if data.count == 32 {
            challenge = data
        } else {
            challenge = Data(SHA256.hash(data: data))
        }
        return try? sign(challenge: challenge)
    }

    // MARK: - 工具

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
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        // 1) Documents 根目录（爱思助手 / 文件 App 导入的落点）
        // 2) Documents/MFI 子目录（成组放更整洁）
        // 3) Bundle 兜底（仅当有人自己把文件塞进 Xcode 工程时才会命中）
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let documents {
            let roots = [
                documents,
                documents.appendingPathComponent("MFI", isDirectory: true),
            ]
            for root in roots {
                let url = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return Bundle.main.url(forResource: base, withExtension: ext)
    }

    /// 缺失材料时给用户的指引 —— 必须能照着做，不能只说"缺少"。
    static let importHint = """
    未检测到 MFi 身份材料。请把下面三个文件导入本应用的 Documents 目录：
      · private.x963
      · leaf.cer
      · certificate.p7b

    导入方式（任选其一）：
      1. 爱思助手 → 应用 → CarWithin → 文件管理 → 沙盒 → Documents，把三个文件拖进去；
      2. iPhone「文件」App → 我的 iPhone → CarWithin，把三个文件拷贝进去；
      3. 用数据线连接电脑，在 Finder/iTunes 的文件共享里拖入。

    导入后回到设置页点一次「重新载入 MFi 材料」即可，无需重装。
    """
}

/// 兼容旧调用点。
typealias MFIIdentity = AccessoryIdentity
