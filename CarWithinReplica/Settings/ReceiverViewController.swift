import UIKit

/// 设置页内容，对应原版 `ReceiverViewController`。
///
/// 分组与文案按真机截图还原：连接与输出 / CarPlay / 后台与画中画 / 支持。
/// 「支持」分组**只保留「诊断与实验」**，支持页、关注作者、请我喝杯咖啡、关于
/// 四项不再构造，界面上不存在，也没有隐藏入口。
final class ReceiverViewController: SettingsPageController {
    init() {
        super.init(title: "设置")
        buildSections = { [weak self] in self?.makeSections() ?? [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "checkmark",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)),
                       for: .normal)
        close.tintColor = .white
        close.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        close.layer.cornerRadius = 17
        close.layer.cornerCurve = .continuous
        close.clipsToBounds = true
        close.addTarget(self, action: #selector(closeSheet), for: .touchUpInside)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.frame = close.bounds
        blur.isUserInteractionEnabled = false
        close.insertSubview(blur, at: 0)

        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: close)
        navigationController?.navigationBar.prefersLargeTitles = false
    }

    @objc private func closeSheet() {
        dismiss(animated: true)
    }

    // MARK: - 分组

    private func makeSections() -> [SettingsSection] {
        [
            SettingsSection("连接与输出", rows: connectionRows()),
            SettingsSection("CarPlay", rows: carPlayRows()),
            SettingsSection("后台与画中画",
                            footer: "锁屏前，请在 iPhone「设置 › 通用 › CarPlay › CarWithin」中打开「锁定时允许 CarPlay」。后台运行会增加耗电。画中画仅显示实时画面。离开 App 时自动开启需打开 iPhone「设置 › 通用 › 画中画」中的自动选项。",
                            rows: backgroundRows()),
            SettingsSection("支持", rows: aboutLinks()),
        ]
    }

    // MARK: - 连接与输出

    private func connectionRows() -> [SettingsRow] {
        [
            pushRow("使用说明", symbol: "book.fill", tint: .systemOrange) {
                GuideViewController(title: "使用说明", text: """
                1. 在「Wi-Fi 与网络」保存仪表或车机的 Wi-Fi 信息。
                2. 在「当前输出」选择输出方式；仪表类输出需先加入仪表 Wi-Fi。
                3. 回到首页，点「启动本机 CarPlay」。
                4. 浏览器输出时，让接收设备连到同一 Wi-Fi，打开 App 显示的地址。

                停止共享请回到首页点「停止」。
                """)
            },

            pushRow("Wi-Fi 与网络", symbol: "wifi", tint: .systemBlue,
                    detail: { SettingsStore.wifiSSID.isEmpty ? "添加" : SettingsStore.wifiSSID }) {
                FormViewController(title: "Wi-Fi 与网络", fields: [
                    .init(title: "名称", placeholder: "SSID",
                          value: { SettingsStore.wifiSSID },
                          onCommit: { name in
                              SettingsStore.wifiSSID = name
                              var presets = SettingsStore.presets
                              if !name.isEmpty, !presets.contains(name) {
                                  presets.append(name)
                                  SettingsStore.presets = presets
                              }
                          }),
                    .init(title: "密码", placeholder: "留空表示开放网络",
                          value: { SettingsStore.wifiPassword },
                          onCommit: { SettingsStore.wifiPassword = $0 },
                          secure: true),
                ], footer: "同名 Wi-Fi 只保存一项；再次修改密码会更新原记录。")
            },

            pushRow("Wi-Fi 预设", symbol: "list.bullet.rectangle", tint: .systemBlue,
                    detail: { SettingsStore.wifiSSID.isEmpty ? "未选择" : SettingsStore.wifiSSID }) {
                WiFiPresetsViewController()
            },

            pushRow("兼容信道", symbol: "antenna.radiowaves.left.and.right", tint: .systemBlue,
                    detail: { SettingsStore.wifiChannel },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "兼容信道",
                    options: ["自动", "1", "6", "11", "36", "44", "149"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.wifiChannel },
                    onSelect: { SettingsStore.wifiChannel = $0 })
            },

            SettingsRow("开放网络", symbol: "lock.open", tint: .systemOrange,
                        detail: { SettingsStore.wifiOpen ? "无密码" : nil },
                        accessory: .toggle(SettingsStore.wifiOpen) { isOn in
                            SettingsStore.wifiOpen = isOn
                            if isOn { SettingsStore.wifiPassword = "" }
                        }),

            pushRow("当前输出", symbol: "square.and.arrow.up", tint: .systemPurple,
                    detail: { OutputMode.title(for: SettingsStore.output) },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "当前输出",
                    options: OutputMode.all.map {
                        SelectionViewController.Option(id: $0.id, title: $0.title, subtitle: nil)
                    },
                    current: { SettingsStore.output },
                    onSelect: { SettingsStore.output = $0 })
            },

            pushRow("输出设置", symbol: "slider.horizontal.3", tint: .systemGray) {
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

            pushRow("HTTPS 设置", symbol: "lock.shield.fill", tint: .systemBlue) {
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

    // MARK: - CarPlay

    private func carPlayRows() -> [SettingsRow] {
        [
            pushRow("画面", symbol: "rectangle.inset.filled", tint: .systemGreen,
                    detail: { SettingsStore.resolution }) {
                SelectionViewController(
                    title: "画面",
                    options: ["1080P", "720P", "480P", "跟随接收端"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.resolution },
                    onSelect: { SettingsStore.resolution = $0 })
            },

            pushRow("CarPlay 外观", symbol: "circle.lefthalf.filled", tint: .systemBlue,
                    detail: { SettingsStore.appearance },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "CarPlay 外观",
                    options: ["跟随系统", "浅色", "深色"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.appearance },
                    onSelect: { SettingsStore.appearance = $0 })
            },

            pushRow("声音", symbol: "speaker.wave.2.fill", tint: .systemOrange,
                    detail: { SettingsStore.audioRoute }) {
                SelectionViewController(
                    title: "声音",
                    options: [
                        .init(id: "Wi-Fi 伴音", title: "Wi-Fi 伴音",
                              subtitle: "随画面传输，由接收设备播放"),
                        .init(id: "由 iPhone 输出", title: "由 iPhone 输出",
                              subtitle: "走当前扬声器或蓝牙设备"),
                    ],
                    current: { SettingsStore.audioRoute },
                    onSelect: { SettingsStore.audioRoute = $0 })
            },

            pushRow("驾驶位", symbol: "steeringwheel", tint: .systemTeal,
                    detail: { SettingsStore.drivingSide },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "驾驶位",
                    options: ["左舵", "右舵"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.drivingSide },
                    onSelect: { SettingsStore.drivingSide = $0 })
            },

            pushRow("车辆", symbol: "car.fill", tint: .systemTeal) {
                GuideViewController(title: "车辆", text: """
                车辆按钮与原版一致：

                · 可启用或隐藏车辆按钮
                · 可选取自定义图标
                · 可恢复默认图标

                图标更改会在下次启动 CarPlay 时生效。
                """)
            },
        ]
    }

    // MARK: - 后台与画中画

    private func backgroundRows() -> [SettingsRow] {
        [
            SettingsRow("锁屏与后台继续运行", symbol: "lock.fill", tint: .systemPurple,
                        accessory: .toggle(SettingsStore.lockBackground) {
                            SettingsStore.lockBackground = $0
                        }),

            pushRow("画中画开启时机", symbol: "pip.enter", tint: .systemBlue,
                    detail: { SettingsStore.pipTiming },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "画中画开启时机",
                    options: [
                        .init(id: "离开 App 时", title: "离开 App 时", subtitle: "默认"),
                        .init(id: "出画面后立即", title: "出画面后立即", subtitle: nil),
                        .init(id: "关闭自动开启", title: "关闭自动开启", subtitle: nil),
                    ],
                    current: { SettingsStore.pipTiming },
                    onSelect: { SettingsStore.pipTiming = $0 })
            },
        ]
    }

    // MARK: - 支持（只保留诊断与实验）

    private func aboutLinks() -> [SettingsRow] {
        // 刻意删除：支持页、关注作者、请我喝杯咖啡、关于。
        // 不要从原版恢复这些入口。
        [
            pushRow("诊断与实验", symbol: "stethoscope", tint: .systemTeal) {
                DiagnosticsViewController()
            },
            pushRow("日志级别", symbol: "text.alignleft", tint: .systemGray,
                    detail: { SettingsStore.logLevel },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "日志级别",
                    options: [
                        .init(id: "详细", title: "详细", subtitle: "打印每一步与所有回包"),
                        .init(id: "错误", title: "错误", subtitle: "只打印出错信息"),
                        .init(id: "无", title: "无", subtitle: "不记录日志"),
                    ],
                    current: { SettingsStore.logLevel },
                    onSelect: { SettingsStore.logLevel = $0 })
            },
            SettingsRow("导出日志", symbol: "square.and.arrow.up", tint: .systemBlue) { [weak self] in
                self?.exportLog()
            },
        ]
    }

    /// 把日志写到临时文件，用系统分享面板导出。
    private func exportLog() {
        let text = DiagnosticsLog.shared.text
        guard !text.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("carwithin-log.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        present(controller, animated: true)
    }
}
