import Foundation

/// iAP2 配件消息 —— 逐字段照原版 `TDSCarKit.AccessoryMessages` 反编译结果实现
/// （`analysis/accmsg.c`，含三个私有辅助方法 `string` / `group` / `init` 折叠）。
///
/// 两个关键约定（原版实现细节，此前完全写错）：
/// 1. 字符串参数的值是 `0x00 + UTF8`，不是裸 UTF8，也不是带结尾 0。
///    原版 `string(_,_)` 先取静态字面量 `[0x00]`（DAT_1001b4f68）再 append UTF8。
/// 2. 「组」参数的值是**子参数 encoded 后的串联**（原版 `group(_,_)` 把每个
///    `IAP2Parameter.encoded()` 依次 append 进一个 Data，再包成同 id 的参数）。
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

    // MARK: - 原版三个私有辅助

    /// `string(id, s)` → value = `0x00` + UTF8
    static func string(_ id: UInt16, _ text: String) -> IAP2Parameter {
        var value = Data([0x00])
        value.append(contentsOf: Array(text.utf8))
        return IAP2Parameter(id: id, value: value)
    }

    /// `group(id, params)` → value = 子参数 encoded 串联
    static func group(_ id: UInt16, _ parameters: [IAP2Parameter]) -> IAP2Parameter {
        var value = Data()
        for parameter in parameters {
            value.append(parameter.encoded())
        }
        return IAP2Parameter(id: id, value: value)
    }

    // MARK: - 0x1D01 识别信息

    /// 响应 0x1D00。原版参数表（全部来自反编译）：
    /// ```
    ///  0  name                       1  "CP-Receiver-1"     2  "OEM"
    ///  3  "SN000001"                 4  "1.0.0"            5  "1.0.0"
    ///  6  43 01                      7  43 00              8  00
    ///  9  00 00                     12  "en"              13  "en"
    /// 16  [0:00 01, 1:"USBSHot", 2:空, 3:01, 4:空]
    /// 17  [0:00 02, 1:"Bluetooth", 2:空, 3:空]
    /// 24  [0:00 03, 1:"WiFiCarPlay", 2:空, 4:空]
    /// ```
    static func identification(name: String, deviceID: String) -> IAP2Message {
        var parameters: [IAP2Parameter] = []
        parameters.append(string(0, name))
        parameters.append(string(1, "CP-Receiver-1"))
        parameters.append(string(2, "OEM"))
        parameters.append(string(3, "SN000001"))
        parameters.append(string(4, "1.0.0"))
        parameters.append(string(5, "1.0.0"))
        parameters.append(IAP2Parameter(id: 6, value: Data([0x43, 0x01])))
        parameters.append(IAP2Parameter(id: 7, value: Data([0x43, 0x00])))
        parameters.append(IAP2Parameter(id: 8, value: Data([0x00])))
        parameters.append(IAP2Parameter(id: 9, value: Data([0x00, 0x00])))
        parameters.append(string(12, "en"))
        parameters.append(string(13, "en"))

        parameters.append(group(0x10, [
            IAP2Parameter(id: 0, value: Data([0x00, 0x01])),
            string(1, "USBSHot"),
            IAP2Parameter(id: 2, value: Data()),
            IAP2Parameter(id: 3, value: Data([0x01])),
            IAP2Parameter(id: 4, value: Data())
        ]))
        parameters.append(group(0x11, [
            IAP2Parameter(id: 0, value: Data([0x00, 0x02])),
            string(1, "Bluetooth"),
            IAP2Parameter(id: 2, value: Data()),
            IAP2Parameter(id: 3, value: Data())
        ]))
        parameters.append(group(0x18, [
            IAP2Parameter(id: 0, value: Data([0x00, 0x03])),
            string(1, "WiFiCarPlay"),
            IAP2Parameter(id: 2, value: Data()),
            IAP2Parameter(id: 4, value: Data())
        ]))

        return IAP2Message(id: IAP2MessageID.identificationInformation, parameters: parameters)
    }

    /// 原版会先把 deviceID 按 `:` 切成 6 段并用 radix 16 逐段解析，任一段失败即抛错。
    static func isValidDeviceID(_ deviceID: String) -> Bool {
        let parts = deviceID.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { UInt8($0, radix: 16) != nil }
    }

    // MARK: - 0x4301 启动 CarPlay

    /// 响应 0x4300。原版参数表：
    /// ```
    ///  0  group[ string(0, address) ]
    ///  1  group[ string(0,ssid), string(1,password), raw(2,[channel]),
    ///            string(3, address), raw(4,[password.isEmpty ? 0 : 2]) ]   ← 仅 ssid 非空时
    ///  2  raw 00 00 <port BE16>
    ///  3  string(deviceID)
    ///  4  string("")
    ///  5  string("11.905")
    /// ```
    static func startSession(address: String,
                             port: UInt16,
                             deviceID: String,
                             wifi: WiFi?) -> IAP2Message {
        var parameters: [IAP2Parameter] = []

        parameters.append(group(0, [string(0, address)]))

        if let wifi, !wifi.ssid.isEmpty {
            parameters.append(group(1, [
                string(0, wifi.ssid),
                string(1, wifi.password),
                IAP2Parameter(id: 2, value: Data([wifi.channel])),
                string(3, address),
                IAP2Parameter(id: 4, value: Data([wifi.password.isEmpty ? 0 : 2]))
            ]))
        }

        parameters.append(IAP2Parameter(id: 2, value: Data([
            0x00, 0x00,
            UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)
        ])))
        parameters.append(string(3, deviceID))
        parameters.append(string(4, ""))
        parameters.append(string(5, "11.905"))

        return IAP2Message(id: IAP2MessageID.startCarPlaySession, parameters: parameters)
    }

    /// 当前车机对外身份。原版会按 `:` 切成 6 段做十六进制校验，
    /// 所以这里必须是标准 MAC 文本格式，否则 identification 会被原版逻辑拒绝。
    static var deviceID: String { "AA:BB:CC:DD:EE:FF" }

    static func summary() -> String {
        "identification(15 项) + startSession 已按原版参数表就绪（deviceID \(deviceID)）"
    }
}
