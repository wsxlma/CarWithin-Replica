import Foundation
import CryptoKit

/// AirPlay 广播身份 —— 字段取值全部来自原版 App 的真实 mDNS 记录（实抓）：
///
/// ```
/// features=0x5653aee2,0x61     （合并 = 0x615653AEE2，与反编译常量一致）
/// pi=ABA798CD-6501-45E1-9C58-D7F641952403
/// srcvers=509.11
/// flags=0x4
/// pk=d41c5a72a841c755682007232c830d59964b004e19daf56c026f596f3f64d258   （Ed25519 公钥 hex）
/// deviceid=9A:53:6C:3D:C7:BB
/// protovers=1.1
/// model=TDSCarKit1,1
/// ```
///
/// 其中 `pi`（设备实例 UUID）、`deviceid`（MAC）、`pk`（Ed25519 公钥）必须在多次启动之间
/// **保持不变**——否则 iPhone 每次都会把它当成一台全新的车机，配对记录全部失效。
final class AirPlayIdentity {
    static let shared = AirPlayIdentity()

    /// 原版 features 的两段：低 32 位在前、高 32 位在后，逗号分隔。
    /// 合并值 0x615653AEE2 与反编译 `CarPlayInfo.features(audio:)` 的有音频分支完全一致。
    static let featuresLow: UInt32 = 0x5653_AEE2
    static let featuresHigh: UInt32 = 0x61
    static let featuresCombined: UInt64 = 0x61_5653_AEE2

    /// 以下四项是原版常量，直接照抄。
    static let sourceVersion = "509.11"
    static let model = "TDSCarKit1,1"
    static let protocolVersion = "1.1"
    static let flags = "0x4"

    private let defaults = UserDefaults.standard

    private(set) var deviceID: String
    private(set) var instanceID: String
    private(set) var signingKey: Curve25519.Signing.PrivateKey

    private enum Key {
        static let deviceID = "airplay.deviceid"
        static let instanceID = "airplay.pi"
        static let privateKey = "airplay.pk.private"
    }

    private init() {
        // deviceid：本地管理位（第二字节 & 0x02）置位的 MAC，原版也是这种形态。
        if let saved = defaults.string(forKey: Key.deviceID), Self.isValidMAC(saved) {
            deviceID = saved
        } else {
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            bytes[0] = (bytes[0] & 0xFE) | 0x02   // 本地管理、单播
            let value = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            defaults.set(value, forKey: Key.deviceID)
            deviceID = value
        }

        // pi：持久 UUID，绝不能每次启动重新生成。
        if let saved = defaults.string(forKey: Key.instanceID) {
            instanceID = saved
        } else {
            let value = UUID().uuidString
            defaults.set(value, forKey: Key.instanceID)
            instanceID = value
        }

        // pk：Ed25519 密钥对，私钥持久化，公钥以 hex 形式广播。
        if let raw = defaults.data(forKey: Key.privateKey),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            signingKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            defaults.set(key.rawRepresentation, forKey: Key.privateKey)
            signingKey = key
        }
    }

    /// 32 字节 Ed25519 公钥 → 64 个 hex 字符（原版就是这个格式，不是原始二进制）。
    var publicKeyHex: String {
        signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// 原始公钥字节，供 Bonjour 以外的地方使用。
    var publicKeyData: Data { signingKey.publicKey.rawRepresentation }

    /// AirPlay TXT 记录 —— 与原版抓包结果逐字段对齐，不多不少。
    var txtRecord: [String: Data] {
        func text(_ value: String) -> Data { Data(value.utf8) }
        return [
            "features": text("0x\(String(featuresLow, radix: 16)),0x\(String(featuresHigh, radix: 16))"),
            "pi": text(instanceID),
            "srcvers": text(Self.sourceVersion),
            "flags": text(Self.flags),
            "pk": text(publicKeyHex),
            "deviceid": text(deviceID),
            "protovers": text(Self.protocolVersion),
            "model": text(Self.model),
        ]
    }

    /// 强制换一个新身份（调试用：让 iPhone 忘掉旧配对）。
    func reset() {
        defaults.removeObject(forKey: Key.deviceID)
        defaults.removeObject(forKey: Key.instanceID)
        defaults.removeObject(forKey: Key.privateKey)
    }

    private static func isValidMAC(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}