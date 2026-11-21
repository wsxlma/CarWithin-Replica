import Foundation

/// 轻量设置存储。原版把参数分散在 `ReceiverConfiguration` 与各处 UserDefaults 里，
/// 这里统一一层读写，便于设置页的副标题实时反映当前值。
enum SettingsStore {
    private static let defaults = UserDefaults.standard

    private static func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    // 连接
    static var wifiSSID: String {
        get { string("wifi.ssid", "未设置") }
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

    // 画面
    static var followReceiver: Bool {
        get { defaults.object(forKey: "video.follow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "video.follow") }
    }

    static var resolution: String {
        get { string("video.resolution", "跟随车机") }
        set { defaults.set(newValue, forKey: "video.resolution") }
    }

    static var fps: Int {
        get { defaults.object(forKey: "video.fps") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "video.fps") }
    }

    static var codec: String {
        get { string("video.codec", "H.264") }
        set { defaults.set(newValue, forKey: "video.codec") }
    }

    static var screenFit: String {
        get { string("video.fit", "完整") }
        set { defaults.set(newValue, forKey: "video.fit") }
    }

    // CarPlay
    static var appearance: String {
        get { string("carplay.appearance", "自动") }
        set { defaults.set(newValue, forKey: "carplay.appearance") }
    }

    static var rightHandDrive: Bool {
        get { defaults.object(forKey: "carplay.rhd") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "carplay.rhd") }
    }

    static var audioRoute: String {
        get { string("carplay.audio", "由 iPhone 输出") }
        set { defaults.set(newValue, forKey: "carplay.audio") }
    }

    // 后台与画中画
    static var pipTiming: String {
        get { string("pip.timing", "离开 App 时") }
        set { defaults.set(newValue, forKey: "pip.timing") }
    }

    static var allowWhileLocked: Bool {
        get { defaults.object(forKey: "pip.locked") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "pip.locked") }
    }

    // HTTPS
    static var httpsPort: String {
        get { string("https.port", "9889") }
        set { defaults.set(newValue, forKey: "https.port") }
    }

    static var httpsMode: String {
        get { string("https.mode", "本地 IP") }
        set { defaults.set(newValue, forKey: "https.mode") }
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
