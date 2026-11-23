import Foundation
import UIKit

/// 车机运行时配置层。
///
/// 设置页里存的是中文展示值（"夜间" / "右舵" / "H.265"…），
/// 各模块需要的是具体参数（nightMode=2 / rightHandDrive=true / isH265=true）。
/// 所有翻译只在这里做一次，避免同一个设置在多处被解释成不同结果。
enum CarPlayConfiguration {

    // MARK: - 车辆名称 / 按钮 / 图标

    static var vehicleName: String {
        let name = SettingsStore.vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "CarWithin" : name
    }

    static var showVehicleButton: Bool { SettingsStore.showVehicleButton }

    static var vehicleIcon: String { SettingsStore.vehicleIcon }

    /// 浏览器 HUD 上车辆按钮的图标尺寸倍率。
    static var vehicleButtonScale: Double {
        switch iconMillimeters {
        case 240: return 1.2
        case 160: return 0.8
        default: return 1.0
        }
    }

    // MARK: - 外观

    /// 0 = 跟随系统，1 = 白天，2 = 夜间。
    static var nightMode: Int {
        switch SettingsStore.appearance {
        case "白天": return 1
        case "夜间": return 2
        default: return 0
        }
    }

    static var interfaceStyle: UIUserInterfaceStyle {
        switch SettingsStore.appearance {
        case "白天": return .light
        case "夜间": return .dark
        default: return .unspecified
        }
    }

    /// 浏览器页面用的主题（跟随系统时按当前系统外观解析）。
    static var darkInterface: Bool {
        switch nightMode {
        case 1: return false
        case 2: return true
        default: return UIScreen.main.traitCollection.userInterfaceStyle == .dark
        }
    }

    static var themeName: String { darkInterface ? "dark" : "light" }

    // MARK: - 驾驶位

    static var rightHandDrive: Bool { SettingsStore.drivingSide == "右舵" }

    /// 车机 HUD 应贴近驾驶位的一侧。
    static var hudSide: String { rightHandDrive ? "right" : "left" }

    // MARK: - 声音

    /// Wi-Fi 伴音：音频送浏览器接收端；关闭时由本机（iPhone）播放。
    static var audioOverWiFi: Bool { SettingsStore.audioRoute == "Wi-Fi 伴音" }

    static var localAudioEnabled: Bool { !audioOverWiFi }

    // MARK: - 视频编码

    static var isH265: Bool { !SettingsStore.codec.contains("264") }

    static var codecName: String { isH265 ? "H.265" : "H.264" }

    /// WebCodecs 的 codec 字符串。
    static var webCodecsString: String {
        isH265 ? "hvc1.1.6.L123.B0" : "avc1.42E01F"
    }

    static var hevcProfile: String { isH265 ? "Main" : "Baseline" }

    // MARK: - 分辨率与画面比例

    /// 自动重启的降级级别（0 正常 / 1 降帧 / 2 降帧+降分辨率）。
    /// 只作用于本次连接，不写回用户设置。
    static var degradation: Int = 0

    static var baseWidth: Int {
        let value = SettingsStore.resolution
        var width = 1920
        if value.contains("720") { width = 1280 }
        if value.contains("480") { width = 854 }
        if degradation >= 2 { width = min(width, 1280) }
        return width
    }

    static var baseHeight: Int {
        let value = SettingsStore.resolution
        var height = 1080
        if value.contains("720") { height = 720 }
        if value.contains("480") { height = 480 }
        if degradation >= 2 { height = min(height, 720) }
        return height
    }

    static var aspectRatioText: String {
        switch SettingsStore.aspectRatio {
        case "4:3": return "4:3"
        case "21:9": return "21:9"
        case "16:9": return "16:9"
        default: return "16:9"
        }
    }

    static var aspectRatioValue: Double {
        switch SettingsStore.aspectRatio {
        case "4:3": return 4.0 / 3.0
        case "21:9": return 21.0 / 9.0
        default: return 16.0 / 9.0
        }
    }

    static var usesCustomAspect: Bool {
        SettingsStore.aspectRatio != "预设比例"
    }

    static var screenFollowsReceiver: Bool {
        SettingsStore.screenMode == "跟随接收端"
    }

    /// 广播给 iPhone 的显示尺寸。自定义比例时保持宽度、重算高度。
    static var displayWidth: Int { baseWidth }

    static var displayHeight: Int {
        guard usesCustomAspect else { return baseHeight }
        return max(320, Int((Double(baseWidth) / aspectRatioValue).rounded()))
    }

    static var fps: Int {
        let configured = SettingsStore.fps
        return degradation >= 1 ? min(configured, 30) : configured
    }

    // MARK: - 图标大小

    static var iconMillimeters: Int {
        if SettingsStore.iconSize.contains("240") { return 240 }
        if SettingsStore.iconSize.contains("160") { return 160 }
        return 200
    }

    static var iconScale: Double {
        switch iconMillimeters {
        case 240: return 1.2
        case 160: return 0.8
        default: return 1.0
        }
    }

    // MARK: - 浏览器性能

    enum PerformanceMode: String {
        case auto = "auto"
        case lowLatency = "low"
        case compatible = "compat"

        /// 解码队列上限（帧），低延迟档主动丢旧帧。
        var maxQueue: Int {
            switch self {
            case .auto: return 2
            case .lowLatency: return 1
            case .compatible: return 6
            }
        }

        var useWebCodecs: Bool { self != .compatible }

        var jpegQuality: Double {
            switch self {
            case .auto: return 0.7
            case .lowLatency: return 0.6
            case .compatible: return 0.82
            }
        }

        /// 0 表示不额外限帧。
        var targetFPS: Int { self == .compatible ? 30 : 0 }
    }

    static var performanceMode: PerformanceMode {
        switch SettingsStore.browserPerformance {
        case "低延迟": return .lowLatency
        case "兼容": return .compatible
        default: return .auto
        }
    }

    static var showTouches: Bool { SettingsStore.showTouches }

    static var autoRestart: Bool { SettingsStore.autoRestart }

    /// 注入到浏览器页面的启动配置（JS 对象字面量）。
    static var browserBootstrap: String {
        let name = vehicleName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "\n", with: " ")
        let perf = performanceMode
        return """
        {theme:'\(themeName)',hudSide:'\(hudSide)',vehicleName:'\(name)',
        showVehicleButton:\(showVehicleButton),vehicleButtonScale:\(vehicleButtonScale),
        showTouches:\(showTouches),iconScale:\(iconScale),
        perfMode:'\(perf.rawValue)',maxQueue:\(perf.maxQueue),useWebCodecs:\(perf.useWebCodecs),
        targetFPS:\(perf.targetFPS),jpegQuality:\(perf.jpegQuality),
        aspect:'\(aspectRatioText)',aspectValue:\(aspectRatioValue),
        followReceiver:\(screenFollowsReceiver),width:\(displayWidth),height:\(displayHeight),
        fps:\(fps),codec:'\(codecName)',audioOverWiFi:\(audioOverWiFi),nightMode:\(nightMode)}
        """
    }

    // MARK: - 协议侧输出

    /// Bonjour TXT 记录：只放 iOS 的 CarPlay/AirPlay 栈认的标准字段
    /// （对照 WirelessCarPlay 的 TXT 结构：deviceid / features / model / pk / flags）。
    /// 车机配置走 /info 与 iAP2 0x1D00，不塞进 TXT——mDNS 单包有上限，塞多了会被丢弃。
    /// TXT 记录直接取 `AirPlayIdentity`，字段集合与取值全部来自原版 App 的实抓结果。
    /// 之前这里是手写的猜测值（features/flags/pi 全错），iOS 因此不认。
    static func txtRecord() -> [String: Data] {
        AirPlayIdentity.shared.txtRecord
    }

    /// /info 的能力声明 plist。
    static func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>name</key><string>\(vehicleName)</string>
        <key>deviceID</key><string>\(AirPlayIdentity.shared.deviceID)</string>
        <key>model</key><string>\(AirPlayIdentity.model)</string>
        <key>srcVers</key><string>\(AirPlayIdentity.sourceVersion)</string>
        <key>features</key><integer>\(AirPlayIdentity.featuresCombined)</integer>
        <key>keepAliveLowPower</key><true/>
        <key>keepAliveSendStatsAsBody</key><true/>
        <key>supportsH265</key><\(isH265 ? "true" : "false")/>
        <key>videoCodec</key><string>\(isH265 ? "H.265" : "H.264")</string>
        <key>width</key><integer>\(displayWidth)</integer>
        <key>height</key><integer>\(displayHeight)</integer>
        <key>fps</key><integer>\(fps)</integer>
        <key>aspectRatio</key><string>\(aspectRatioText)</string>
        <key>iconSize</key><integer>\(iconMillimeters)</integer>
        <key>nightMode</key><integer>\(nightMode)</integer>
        <key>rightHandDrive</key><\(rightHandDrive ? "true" : "false")/>
        <key>vehicleButton</key><\(showVehicleButton ? "true" : "false")/>
        </dict></plist>
        """
    }

    /// 启动时打印的配置摘要，便于真机核对每项是否生效。
    static func summary() -> [String] {
        [
            "车辆：\(vehicleName)（按钮 \(showVehicleButton ? "显示" : "隐藏")，图标 \(vehicleIcon)）",
            "外观：\(SettingsStore.appearance)（nightMode=\(nightMode)，主题 \(themeName)）",
            "驾驶位：\(SettingsStore.drivingSide)（rightHandDrive=\(rightHandDrive)）",
            "声音：\(SettingsStore.audioRoute)（伴音 \(audioOverWiFi ? "开" : "关")）",
            "编码：\(codecName)（HEVC \(isH265 ? "支持" : "关闭")，\(webCodecsString)）",
            "画面：\(displayWidth)×\(displayHeight) @ \(fps)FPS，比例 \(aspectRatioText)，\(SettingsStore.screenMode)",
            "图标：\(iconMillimeters) mm（缩放 \(iconScale)）",
            "浏览器：\(SettingsStore.browserPerformance)（\(performanceMode.rawValue)），触摸点 \(showTouches ? "显示" : "隐藏")",
            "自动重启：\(autoRestart ? "开" : "关")",
        ]
    }

    /// 用于检测设置是否变更（回前台时比较）。
    static var signature: String { summary().joined(separator: "|") }

    /// 启动时把外观应用到 App 界面。
    static func applyAppearance() {
        let style = interfaceStyle
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}
