import Foundation

/// 轻量设置存储。默认值取自真机截图，保证首次打开与原版观感一致。
enum SettingsStore {
    private static let defaults = UserDefaults.standard

    private static func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func flag(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    // 连接与输出
    static var wifiSSID: String {
        get { string("wifi.ssid", "") }
        set { defaults.set(newValue, forKey: "wifi.ssid") }
    }

    static var wifiPassword: String {
        get { string("wifi.password", "") }
        set { defaults.set(newValue, forKey: "wifi.password") }
    }

    static var presets: [String] {
        get { defaults.stringArray(forKey: "wifi.presets") ?? [] }
        set { defaults.set(newValue, forKey: "wifi.presets") }
    }

    static var output: String {
        get { string("output.mode", "browser") }
        set { defaults.set(newValue, forKey: "output.mode") }
    }

    static var receiverHost: String {
        get { string("output.host", "192.168.1.1") }
        set { defaults.set(newValue, forKey: "output.host") }
    }

    static var receiverPort: String {
        get { string("output.port", "9888") }
        set { defaults.set(newValue, forKey: "output.port") }
    }

    static var httpsPort: String {
        get { string("https.port", "9889") }
        set { defaults.set(newValue, forKey: "https.port") }
    }

    static var httpsMode: String {
        get { string("https.mode", "本地 IP") }
        set { defaults.set(newValue, forKey: "https.mode") }
    }

    // CarPlay
    static var resolution: String {
        get { string("video.resolution", "1080P") }
        set { defaults.set(newValue, forKey: "video.resolution") }
    }

    static var appearance: String {
        get { string("carplay.appearance", "跟随系统") }
        set { defaults.set(newValue, forKey: "carplay.appearance") }
    }

    static var audioRoute: String {
        get { string("carplay.audio", "Wi-Fi 伴音") }
        set { defaults.set(newValue, forKey: "carplay.audio") }
    }

    static var drivingSide: String {
        get { string("carplay.side", "左舵") }
        set { defaults.set(newValue, forKey: "carplay.side") }
    }

    static var vehicleIcon: String {
        get { string("carplay.vehicleIcon", "默认") }
        set { defaults.set(newValue, forKey: "carplay.vehicleIcon") }
    }

    // 日志
    static var logLevel: String {
        get { string("log.level", "详细") }
        set { defaults.set(newValue, forKey: "log.level") }
    }

    // 后台与画中画
    static var lockBackground: Bool {
        get { flag("pip.lockBackground", true) }
        set { defaults.set(newValue, forKey: "pip.lockBackground") }
    }

    static var pipTiming: String {
        get { string("pip.timing", "离开 App 时") }
        set { defaults.set(newValue, forKey: "pip.timing") }
    }
}

/// 输出方式的中文名，UI 与存储分离。
enum OutputMode {
    static let all: [(id: String, title: String)] = [
        ("browser", "浏览器"),
        ("ninebot5", "九号 5 寸"),
        ("ninebot7", "九号 7 寸（实验）"),
        ("tailing", "台铃 4.3 寸（实验）"),
        ("carlife", "无线 CarLife"),
        ("airplay", "AirPlay（实验）"),
    ]

    static func title(for id: String) -> String {
        all.first { $0.id == id }?.title ?? id
    }
}
