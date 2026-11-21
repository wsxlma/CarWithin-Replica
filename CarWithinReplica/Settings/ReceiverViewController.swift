import UIKit

/// 设置页内容，对应原版的 `ReceiverViewController`。
///
/// 「支持」分组**只保留「诊断与实验」**：支持页、关注作者、请我喝杯咖啡、关于
/// 四项不再构造，界面上不存在，也没有隐藏入口。
/// 其余分组（通用 / 画面 / CarPlay / 后台与画中画 / 实验 / 浏览器输出）保持完整。
final class ReceiverViewController: SettingsPageController {
    init() {
        super.init(title: "设置")
        buildSections = { [weak self] in self?.makeSections() ?? [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - 分组

    private func makeSections() -> [SettingsSection] {
        [
            SettingsSection(header: "通用", rows: generalRows()),
            SettingsSection(header: "画面",
                            footer: "车机拉伸画面或出现黑屏时，可试固定分辨率、30 FPS 与 H.264。",
                            rows: videoRows()),
            SettingsSection(header: "CarPlay", rows: carPlayRows()),
            SettingsSection(header: "后台与画中画",
                            footer: "锁屏继续运行前，请在系统「设置 › 通用 › CarPlay › CarWithin」中允许锁定时使用。",
                            rows: backgroundRows()),
            SettingsSection(header: "实验",
                            footer: "实验功能可能随版本调整。",
                            rows: experimentRows()),
            SettingsSection(header: "浏览器输出",
                            footer: "局域网接收页没有登录校验，可访问地址的设备都能观看与触控，请在可信网络中使用。",
                            rows: browserRows()),
            SettingsSection(header: "支持", rows: aboutLinks()),
        ]
    }

    // MARK: - 通用

    private func generalRows() -> [SettingsRow] {
        [
            .guide("使用说明", icon: "book",
                   text: """
                   1. 在「Wi-Fi 与网络」保存仪表或车机的 Wi-Fi 信息。
                   2. 在「当前输出」选择输出方式；仪表类输出需先加入仪表 Wi-Fi。
                   3. 回到首页，点「启动 CarPlay」。
                   4. 浏览器输出时，让接收设备连到同一 Wi-Fi，打开 App 显示的地址。

                   停止共享请回到首页点「停止」。
                   """),

            .page("Wi-Fi 与网络", icon: "wifi",
                  detailProvider: { SettingsStore.wifiSSID }) {
                FormViewController(title: "Wi-Fi 与网络", fields: [
                    .init(title: "名称", placeholder: "SSID",
                          value: { SettingsStore.wifiSSID },
                          onCommit: { SettingsStore.wifiSSID = $0 }),
                    .init(title: "密码", placeholder: "留空表示开放网络",
                          value: { SettingsStore.wifiPassword },
                          onCommit: { SettingsStore.wifiPassword = $0 },
                          secure: true),
                ], footer: "同名 Wi-Fi 只保存一项；再次修改密码会更新原记录。")
            },

            .page("Wi-Fi 预设", icon: "bookmark",
                  detailProvider: {
                      let count = SettingsStore.presets.count
                      return count == 0 ? "尚未保存预设" : "\(count) 个预设"
                  }) {
                WiFiPresetsViewController()
            },

            .page("当前输出", icon: "rectangle.connected.to.line.below",
                  detailProvider: { OutputMode.title(for: SettingsStore.output) }) {
                SelectionViewController(
                    title: "当前输出",
                    options: OutputMode.all.map {
                        SelectionViewController.Option(id: $0.id, title: $0.title, subtitle: nil)
                    },
                    current: { SettingsStore.output },
                    onSelect: { SettingsStore.output = $0 })
            },

            .page("输出设置", icon: "slider.horizontal.3",
                  detailProvider: { "\(SettingsStore.receiverHost):\(SettingsStore.receiverPort)" }) {
                FormViewController(title: "输出设置", fields: [
                    .init(title: "接收端地址", placeholder: "192.168.1.1",
                          value: { SettingsStore.receiverHost },
                          onCommit: { SettingsStore.receiverHost = $0 },
                          keyboard: .numbersAndPunctuation),
                    .init(title: "端口", placeholder: "9888",
                          value: { SettingsStore.receiverPort },
                          onCommit: { SettingsStore.receiverPort = $0 },
                          keyboard: .numberPad),
                ], footer: "九号与台铃仪表默认地址为 192.168.1.1，请在加入仪表 Wi-Fi 后核对。")
            },

            .page("HTTPS 设置", icon: "lock.shield",
                  detailProvider: { "\(SettingsStore.httpsMode) · \(SettingsStore.httpsPort)" }) {
                FormViewController(title: "HTTPS 设置", fields: [
                    .init(title: "端口", placeholder: "9889",
                          value: { SettingsStore.httpsPort },
                          onCommit: { SettingsStore.httpsPort = $0 },
                          keyboard: .numberPad),
                    .init(title: "域名方案", placeholder: "本地 IP / sslip.io / DuckDNS",
                          value: { SettingsStore.httpsMode },
                          onCommit: { SettingsStore.httpsMode = $0 }),
                ], footer: "留空端口时通常使用 HTTP 端口加 1。域名方案不建立公网隧道。")
            },
        ]
    }

    // MARK: - 画面

    private func videoRows() -> [SettingsRow] {
        [
            .control("跟随车机", icon: "rectangle.dashed",
                     detail: "按接收端窗口尺寸决定画面规格",
                     detailProvider: nil,
                     ClosureSwitch(isOn: SettingsStore.followReceiver) {
                         SettingsStore.followReceiver = $0
                     }),

            .page("固定分辨率", icon: "aspectratio",
                  detailProvider: { SettingsStore.resolution }) {
                SelectionViewController(
                    title: "固定分辨率",
                    options: ["跟随车机", "1920×1080", "1280×720", "1024×600", "848×480", "480×272"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.resolution },
                    onSelect: { SettingsStore.resolution = $0 })
            },

            .page("帧率", icon: "speedometer",
                  detailProvider: { "\(SettingsStore.fps) FPS" }) {
                SelectionViewController(
                    title: "帧率",
                    options: [60, 30, 25, 20]
                        .map { SelectionViewController.Option(id: "\($0)", title: "\($0) FPS", subtitle: nil) },
                    current: { "\(SettingsStore.fps)" },
                    onSelect: { SettingsStore.fps = Int($0) ?? 30 })
            },

            .page("编码", icon: "film",
                  detailProvider: { SettingsStore.codec }) {
                SelectionViewController(
                    title: "编码",
                    options: [
                        .init(id: "H.264", title: "H.264", subtitle: "兼容性优先"),
                        .init(id: "H.265", title: "H.265", subtitle: "同码率下画质更好，需浏览器支持"),
                    ],
                    current: { SettingsStore.codec },
                    onSelect: { SettingsStore.codec = $0 })
            },

            .page("屏幕适配", icon: "arrow.up.left.and.arrow.down.right",
                  detailProvider: { SettingsStore.screenFit }) {
                SelectionViewController(
                    title: "屏幕适配",
                    options: [
                        .init(id: "完整", title: "完整", subtitle: "保留整幅画面"),
                        .init(id: "裁满", title: "裁满", subtitle: "裁掉超出部分"),
                        .init(id: "拉伸", title: "拉伸", subtitle: "改变画面比例填满"),
                    ],
                    current: { SettingsStore.screenFit },
                    onSelect: { SettingsStore.screenFit = $0 })
            },
        ]
    }

    // MARK: - CarPlay

    private func carPlayRows() -> [SettingsRow] {
        [
            .page("外观", icon: "circle.lefthalf.filled",
                  detailProvider: { SettingsStore.appearance }) {
                SelectionViewController(
                    title: "外观",
                    options: ["自动", "浅色", "深色"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.appearance },
                    onSelect: { SettingsStore.appearance = $0 })
            },

            .control("右舵驾驶位", icon: "steeringwheel",
                     detail: "切换后需重新启动 CarPlay",
                     detailProvider: nil,
                     ClosureSwitch(isOn: SettingsStore.rightHandDrive) {
                         SettingsStore.rightHandDrive = $0
                     }),

            .page("声音输出", icon: "speaker.wave.2",
                  detailProvider: { SettingsStore.audioRoute }) {
                SelectionViewController(
                    title: "声音输出",
                    options: [
                        .init(id: "由 iPhone 输出", title: "由 iPhone 输出",
                              subtitle: "走当前扬声器或蓝牙设备"),
                        .init(id: "随画面传输", title: "随画面传输（Wi-Fi）",
                              subtitle: "浏览器播放伴音，通话与 Siri 仍在手机"),
                    ],
                    current: { SettingsStore.audioRoute },
                    onSelect: { SettingsStore.audioRoute = $0 })
            },
        ]
    }

    // MARK: - 后台与画中画

    private func backgroundRows() -> [SettingsRow] {
        [
            .page("画中画时机", icon: "pip",
                  detailProvider: { SettingsStore.pipTiming }) {
                SelectionViewController(
                    title: "画中画时机",
                    options: [
                        .init(id: "离开 App 时", title: "离开 App 时", subtitle: "默认"),
                        .init(id: "出画面后立即", title: "出画面后立即", subtitle: nil),
                        .init(id: "关闭自动开启", title: "关闭自动开启", subtitle: nil),
                    ],
                    current: { SettingsStore.pipTiming },
                    onSelect: { SettingsStore.pipTiming = $0 })
            },

            .control("锁定时允许 CarPlay", icon: "lock.open",
                     detail: "需系统设置中同时开启",
                     detailProvider: nil,
                     ClosureSwitch(isOn: SettingsStore.allowWhileLocked) {
                         SettingsStore.allowWhileLocked = $0
                     }),
        ]
    }

    // MARK: - 实验

    private func experimentRows() -> [SettingsRow] {
        [
            .guide("同机 CarPlay 探测", icon: "wave.3.right",
                   text: "用于确认本机是否能建立 CarPlay 会话。\n\n若提示 CoreAccessories 拒绝连接，说明签名缺少私有传输权限，与代码无关。"),
        ]
    }

    // MARK: - 支持（只保留诊断与实验）

    private func aboutLinks() -> [SettingsRow] {
        // 刻意删除：支持页、关注作者、请我喝杯咖啡、关于。
        // 不要从原版恢复这些入口。
        [
            .page("诊断与实验", icon: "stethoscope",
                  detail: "查看运行日志，便于反馈问题") {
                DiagnosticsViewController()
            },
        ]
    }

    // MARK: - 浏览器输出

    private func browserRows() -> [SettingsRow] {
        [
            .guide("HTTP 与 HTTPS", icon: "network",
                   text: "HTTP 默认 9888，兼容性优先；HTTPS 默认 9889，浏览器支持 WebCodecs 时延迟更低。"),
            .guide("证书配置", icon: "checkmark.shield",
                   text: "先在接收设备打开 HTTP 接收页，点「配置 HTTPS」，核对指纹后再安装并信任证书。"),
        ]
    }
}
