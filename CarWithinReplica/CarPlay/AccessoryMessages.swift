import Foundation

/// iAP2 配件消息构造（复刻原版 `TDSCarKit.AccessoryMessages`）。
///
/// 原版两个静态方法（符号还原）：
///   identification(name:deviceID:) -> IAP2Message
///   startSession(address:port:deviceID:wifi:) -> IAP2Message
///   struct WiFi { ssid, password, channel: UInt8 }
///
/// identification 是声明「我是一台 CarPlay 车机」，iPhone 收到后才可能
/// 弹出「连接 CarPlay 车载」；startSession 则把 RTSP 地址递给 iPhone。
enum AccessoryMessages {
    struct WiFi {
        let ssid: String
        let password: String
        let channel: UInt8

        init(ssid: String, password: String, channel: UInt8 = 0) {
            self.ssid = ssid
            self.password = password
            self.channel = channel
        }
    }

    private static func text(_ value: String) -> Data { Data(value.utf8) }

    /// 0x1D01：响应系统 0x1D00 识别请求（原版日志：收到 0x1D00 → 发送 0x1D01）。
    static func identification(name: String, deviceID: String) -> IAP2Message {
        IAP2Message(id: IAP2MessageID.identificationInfo, parameters: [
            .init(id: 0x00, value: text(name)),
            .init(id: 0x01, value: text(deviceID)),
        ])
    }

    /// 0x4301：响应系统 0x4300「CarPlay 可用」，请求在指定地址启动 CarPlay。
    static func startSession(address: String,
                             port: UInt16,
                             deviceID: String,
                             wifi: WiFi?) -> IAP2Message {
        var portBytes = port.bigEndian
        var parameters: [IAP2Parameter] = [
            .init(id: 0x01, value: text(address)),
            .init(id: 0x02, value: withUnsafeBytes(of: &portBytes) { Data($0) }),
            .init(id: 0x03, value: text(deviceID)),
        ]
        if let wifi {
            parameters.append(.init(id: 0x04, value: text(wifi.ssid)))
            parameters.append(.init(id: 0x05, value: text(wifi.password)))
            parameters.append(.init(id: 0x06, value: Data([wifi.channel])))
        }
        return IAP2Message(id: IAP2MessageID.requestCarPlayStart, parameters: parameters)
    }

    /// 当前车机对外身份（与 Bonjour TXT 保持一致）。
    static var deviceID: String { "AA:BB:CC:DD:EE:FF" }

    static func summary() -> String {
        "identification + startSession 已就绪（deviceID \(deviceID)）"
    }
}
