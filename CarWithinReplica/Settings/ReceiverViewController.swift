import UIKit

/// 设置页内容，对应原版 `ReceiverViewController`。
/// 分组：连接与输出 / CarPlay / 后台与画中画 / 支持。
/// 「支持」只保留「诊断与实验」，其余四项按需求不构造。
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
            pushRow("使用说明", symbol: "book.fill", tint: .systemOrange) { [weak self] in
                GuideViewController(title: "使用说明", text: Self.usageText)
            },

            pushRow("Wi-Fi 与网络", symbol: "wifi", tint: .systemBlue,
                    detail: { SettingsStore.wifiSSID.isEmpty ? "添加" : SettingsStore.wifiSSID }) {
                Self.addWiFiPage()
            },

            pushRow("Wi-Fi 预设", symbol: "list.bullet.rectangle", tint: .systemBlue,
                    detail: { SettingsStore.wifiSSID.isEmpty ? "未选择" : SettingsStore.wifiSSID }) {
                WiFiPresetsViewController()
            },

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
                Self.outputSettingsPage()
            },

            pushRow("HTTPS 设置", symbol: "lock.shield.fill", tint: .systemBlue) {
                Self.httpsPage()
            },
        ]
    }

    // MARK: - CarPlay

    private func carPlayRows() -> [SettingsRow] {
        [
            pushRow("画面", symbol: "rectangle.inset.filled", tint: .systemGreen,
                    detail: { SettingsStore.resolution }) {
                Self.displayPage()
            },

            pushRow("CarPlay 外观", symbol: "circle.lefthalf.filled", tint: .systemBlue,
                    detail: { SettingsStore.appearance },
                    accessory: .upDown) {
                SelectionViewController(
                    title: "CarPlay 外观",
                    options: ["跟随系统", "白天", "夜间"]
                        .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                    current: { SettingsStore.appearance },
                    onSelect: { SettingsStore.appearance = $0 })
            },

            pushRow("声音", symbol: "speaker.wave.2.fill", tint: .systemOrange,
                    detail: { SettingsStore.audioRoute }) {
                Self.soundPage()
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
                Self.vehiclePage()
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
                        .init(id: "关闭", title: "关闭", subtitle: nil),
                        .init(id: "离开 App 时", title: "离开 App 时", subtitle: "默认"),
                        .init(id: "出画面后立即", title: "出画面后立即", subtitle: nil),
                    ],
                    current: { SettingsStore.pipTiming },
                    onSelect: { SettingsStore.pipTiming = $0 })
            },
        ]
    }

    // MARK: - 支持（只保留诊断与实验）

    private func aboutLinks() -> [SettingsRow] {
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

    // MARK: - 二级页

    private static func addWiFiPage() -> SettingsPageController {
        let controller = SettingsPageController(title: "添加 Wi-Fi")
        controller.buildSections = { [weak controller] in
            guard let controller else { return [] }
            return [
                SettingsSection(nil,
                                footer: "返回自动保存。同名网络会更新原预设，兼容信道通常保持 36。",
                                rows: [
                    controller.pushRow("Wi-Fi 名称", symbol: "wifi", tint: .systemBlue,
                                       detail: { SettingsStore.wifiSSID.isEmpty ? "未填写" : SettingsStore.wifiSSID },
                                       accessory: .none) {
                        FormViewController(title: "Wi-Fi 名称", fields: [
                            .init(title: "名称", placeholder: "SSID",
                                  value: { SettingsStore.wifiSSID },
                                  onCommit: { name in
                                      let trimmed = name.trimmingCharacters(in: .whitespaces)
                                      SettingsStore.wifiSSID = trimmed
                                      var presets = SettingsStore.presets
                                      presets.removeAll { $0 != trimmed && trimmed.hasPrefix($0) }
                                      if !trimmed.isEmpty, !presets.contains(trimmed) {
                                          presets.append(trimmed)
                                      }
                                      SettingsStore.presets = presets
                                  }),
                        ], footer: "输入完成后按键盘的完成键保存。")
                    },
                    controller.pushRow("密码", symbol: "key.fill", tint: .systemGray,
                                       detail: {
                                           SettingsStore.wifiOpen ? "开放网络" :
                                           (SettingsStore.wifiPassword.isEmpty ? "未设置" : "已设置")
                                       },
                                       accessory: .none) {
                        FormViewController(title: "密码", fields: [
                            .init(title: "密码", placeholder: "开放网络留空",
                                  value: { SettingsStore.wifiPassword },
                                  onCommit: { SettingsStore.wifiPassword = $0 },
                                  secure: true),
                        ])
                    },
                    SettingsRow("开放网络（无密码）", symbol: "lock.open", tint: .systemOrange,
                                accessory: .toggle(SettingsStore.wifiOpen) { isOn in
                                    SettingsStore.wifiOpen = isOn
                                    if isOn { SettingsStore.wifiPassword = "" }
                                }),
                    controller.pushRow("兼容信道", symbol: "antenna.radiowaves.left.and.right",
                                       tint: .systemBlue,
                                       detail: { SettingsStore.wifiChannel },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "兼容信道",
                            options: ["自动", "36", "1", "6", "11", "44", "149"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.wifiChannel },
                            onSelect: { SettingsStore.wifiChannel = $0 })
                    },
                ]),
            ]
        }
        return controller
    }

    private static func outputSettingsPage() -> SettingsPageController {
        let controller = SettingsPageController(title: "输出设置")
        controller.buildSections = { [weak controller] in
            guard let controller else { return [] }
            return [
                SettingsSection(nil, rows: [
                    SettingsRow("局域网接收页", symbol: "globe", tint: .systemTeal,
                                accessory: .toggle(SettingsStore.lanReceiver) {
                                    SettingsStore.lanReceiver = $0
                                }),
                ]),
                SettingsSection("HTTP · 兼容模式", rows: [
                    controller.pushRow("HTTP 端口", symbol: "number", tint: .systemGray,
                                       detail: { SettingsStore.receiverPort },
                                       accessory: .none) {
                        FormViewController(title: "HTTP 端口", fields: [
                            .init(title: "端口", placeholder: "9888",
                                  value: { SettingsStore.receiverPort },
                                  onCommit: { SettingsStore.receiverPort = $0 },
                                  keyboard: .numberPad),
                        ])
                    },
                    SettingsRow("复制 HTTP 地址", symbol: "doc.on.doc", tint: .systemBlue,
                                detail: { SettingsStore.httpAddress }) { [weak controller] in
                        UIPasteboard.general.string = SettingsStore.httpAddress
                        controller?.navigationItem.prompt = "已复制 HTTP 地址"
                    },
                    SettingsRow("在本机浏览器打开", symbol: "safari", tint: .systemBlue) {
                        if let url = URL(string: SettingsStore.httpAddress) {
                            UIApplication.shared.open(url)
                        }
                    },
                ]),
                SettingsSection("高级",
                                footer: "浏览器性能默认自动。低延迟频繁跳帧时会回到兼容模式。",
                                rows: [
                    controller.pushRow("浏览器性能", symbol: "speedometer", tint: .systemBlue,
                                       detail: { SettingsStore.browserPerformance },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "浏览器性能",
                            options: ["自动", "低延迟", "兼容"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.browserPerformance },
                            onSelect: { SettingsStore.browserPerformance = $0 })
                    },
                    SettingsRow("显示触摸点", symbol: "hand.tap", tint: .systemOrange,
                                accessory: .toggle(SettingsStore.showTouches) {
                                    SettingsStore.showTouches = $0
                                }),
                ]),
            ]
        }
        return controller
    }

    private static func httpsPage() -> SettingsPageController {
        let controller = SettingsPageController(title: "HTTPS 设置")
        controller.buildSections = { [weak controller] in
            guard let controller else { return [] }
            return [
                SettingsSection("地址与证书",
                                footer: "本地 IP 和 sslip.io 使用这台设备的本地根证书。DuckDNS 可使用自行申请的公开 CA 证书。",
                                rows: [
                    controller.pushRow("地址方案", symbol: "globe", tint: .systemTeal,
                                       detail: { SettingsStore.httpsMode },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "地址方案",
                            options: ["本地 IP", "sslip.io", "DuckDNS"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.httpsMode },
                            onSelect: { SettingsStore.httpsMode = $0 })
                    },
                    controller.pushRow("HTTPS 端口", symbol: "number", tint: .systemGray,
                                       detail: { SettingsStore.httpsPort },
                                       accessory: .none) {
                        FormViewController(title: "HTTPS 端口", fields: [
                            .init(title: "端口", placeholder: "9889",
                                  value: { SettingsStore.httpsPort },
                                  onCommit: { SettingsStore.httpsPort = $0 },
                                  keyboard: .numberPad),
                        ])
                    },
                    SettingsRow("复制 HTTPS 地址", symbol: "doc.on.doc", tint: .systemBlue,
                                detail: { SettingsStore.httpsAddress }) {
                        UIPasteboard.general.string = SettingsStore.httpsAddress
                    },
                ]),
                SettingsSection(nil,
                                footer: "在接收设备的 HTTP 页面点「配置 HTTPS」，安装并信任本机根证书。",
                                rows: [
                    controller.pushRow("证书安装说明", symbol: "doc.text", tint: .systemBlue) {
                        GuideViewController(title: "HTTPS 低延迟", text: Self.httpsGuideText)
                    },
                ]),
                SettingsSection(nil,
                                footer: "启动 CarPlay 后即可打开上方地址。",
                                rows: []),
            ]
        }
        return controller
    }

    private static func displayPage() -> SettingsPageController {
        let controller = SettingsPageController(title: "画面")
        controller.buildSections = { [weak controller] in
            guard let controller else { return [] }
            return [
                SettingsSection(nil,
                                footer: "选择比例后按分辨率档位计算尺寸，短边至少 320 像素。2K/4K 会增加发热和带宽。",
                                rows: [
                    controller.pushRow("画面尺寸", symbol: "rectangle.split.2x1", tint: .systemGreen,
                                       detail: { SettingsStore.screenMode },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "画面尺寸",
                            options: ["固定尺寸", "跟随接收端"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.screenMode },
                            onSelect: { SettingsStore.screenMode = $0 })
                    },
                    controller.pushRow("分辨率", symbol: "arrow.up.left.and.arrow.down.right",
                                       tint: .systemGreen,
                                       detail: { SettingsStore.resolution },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "分辨率",
                            options: ["1080P（1920×1080）", "720P（1280×720）", "480P（854×480）"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.resolution },
                            onSelect: { SettingsStore.resolution = $0 })
                    },
                    controller.pushRow("画面比例", symbol: "aspectratio", tint: .systemGreen,
                                       detail: { SettingsStore.aspectRatio },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "画面比例",
                            options: ["预设比例", "16:9", "4:3", "21:9"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.aspectRatio },
                            onSelect: { SettingsStore.aspectRatio = $0 })
                    },
                ]),
                SettingsSection(nil,
                                footer: "自动帧率根据主网页选择 30 或 60 FPS。支持 H.265 的主网页会优先使用 H.265。",
                                rows: [
                    controller.pushRow("视频编码", symbol: "film", tint: .systemGreen,
                                       detail: { SettingsStore.codec },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "视频编码",
                            options: ["H.265", "H.264"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.codec },
                            onSelect: { SettingsStore.codec = $0 })
                    },
                    controller.pushRow("帧率", symbol: "speedometer", tint: .systemGreen,
                                       detail: { "\(SettingsStore.fps) FPS" },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "帧率",
                            options: [60, 30, 25, 20]
                                .map { SelectionViewController.Option(id: "\($0)", title: "\($0) FPS", subtitle: nil) },
                            current: { "\(SettingsStore.fps)" },
                            onSelect: { SettingsStore.fps = Int($0) ?? 60 })
                    },
                ]),
                SettingsSection(nil,
                                footer: "浏览器画面持续卡顿时，自动以更轻的画面重启 CarPlay（先降到 30 FPS，再降到 720P），每次连接最多两次。",
                                rows: [
                    SettingsRow("自动重启", symbol: "arrow.clockwise", tint: .systemGreen,
                                accessory: .toggle(SettingsStore.autoRestart) {
                                    SettingsStore.autoRestart = $0
                                }),
                ]),
                SettingsSection("图标", rows: [
                    controller.pushRow("CarPlay 图标大小", symbol: "square.grid.2x2.fill",
                                       tint: .systemPurple,
                                       detail: { SettingsStore.iconSize },
                                       accessory: .upDown) {
                        SelectionViewController(
                            title: "CarPlay 图标大小",
                            options: ["默认（200 mm）", "大（240 mm）", "小（160 mm）"]
                                .map { SelectionViewController.Option(id: $0, title: $0, subtitle: nil) },
                            current: { SettingsStore.iconSize },
                            onSelect: { SettingsStore.iconSize = $0 })
                    },
                ]),
            ]
        }
        return controller
    }

    private static func soundPage() -> SettingsPageController {
        func row(_ title: String, _ detail: String, _ id: String) -> SettingsRow {
            SettingsRow(title, symbol: "speaker.wave.2", tint: .systemOrange,
                        detail: { SettingsStore.audioRoute == id ? "✓" : nil },
                        accessory: .none) {
                SettingsStore.audioRoute = id
            }
        }
        let controller = SettingsPageController(title: "声音")
        controller.buildSections = {
            [
                SettingsSection(nil,
                                footer: "更改在下次启动 CarPlay 时生效。使用 Wi-Fi 伴音时，通话和 Siri 留在 iPhone。",
                                rows: [
                    row("由 iPhone 输出", "用 iPhone 当前的声音输出。想让车机出声，请先配对并选中车机蓝牙。", "由 iPhone 输出"),
                    row("随画面传输（Wi-Fi）", "由接收画面的设备播放。画面自动播放后，若网页提示「开启声音」，点一下即可。", "Wi-Fi 伴音"),
                ]),
            ]
        }
        return controller
    }

    private static func vehiclePage() -> SettingsPageController {
        let controller = SettingsPageController(title: "车辆")
        controller.buildSections = { [weak controller] in
            guard let controller else { return [] }
            return [
                SettingsSection(nil,
                                footer: "车辆名称显示在 iPhone 的 CarPlay 车辆列表中。",
                                rows: [
                    controller.pushRow("车辆名称", symbol: "car", tint: .systemGray,
                                       detail: { SettingsStore.vehicleName },
                                       accessory: .none) {
                        FormViewController(title: "车辆名称", fields: [
                            .init(title: "名称", placeholder: "CarWithin",
                                  value: { SettingsStore.vehicleName },
                                  onCommit: { SettingsStore.vehicleName = $0 }),
                        ])
                    },
                ]),
                SettingsSection("CarPlay 车辆按钮",
                                footer: "图片会居中裁成正方形，下次启动 CarPlay 时生效。",
                                rows: [
                    SettingsRow("显示车辆按钮", symbol: "car.side", tint: .systemTeal,
                                accessory: .toggle(SettingsStore.showVehicleButton) {
                                    SettingsStore.showVehicleButton = $0
                                }),
                    controller.pushRow("当前图标 · \(SettingsStore.vehicleIcon)",
                                       symbol: "car.fill", tint: .systemBlue) {
                        GuideViewController(title: "车辆图标", text: "当前使用默认图标。可从照片选择自定义图标。")
                    },
                    controller.pushRow("从照片选择图标", symbol: "photo", tint: .systemBlue) {
                        GuideViewController(title: "从照片选择图标", text: "选取一张图片，居中裁成正方形作为车辆按钮图标。")
                    },
                ]),
            ]
        }
        return controller
    }

    // MARK: - 文案

    private static let usageText = """
    1. 先连 Wi-Fi

    让 iPhone 加入 Wi-Fi：路由器、车机 Wi-Fi 或另一台手机的热点都可以。有网、没网都能投屏。

    选择同名预设：回到 CarWithin，在「Wi-Fi 预设」选择刚连的网络。第一次用，在「Wi-Fi 与网络」添加。

    2. 选一种输出

    浏览器：车机连同一个 Wi-Fi。在「当前输出」选浏览器，启动 CarPlay，再用车机打开首页显示的 HTTP 地址。

    车机或仪表：选你的设备支持的输出。CarLife 先打开车机上的 CarLife；台铃和九号先加入仪表 Wi-Fi、打开仪表投屏；AirPlay 在首页选接收设备。

    3. 常见问题

    卡在正在连接：核对 iPhone 连的 Wi-Fi 和预设是否同名。仍连不上，关开一次 Wi-Fi，回到 App 重新启动。
    """

    private static let httpsGuideText = """
    从 HTTP 接收页开始

    在接收设备上打开 HTTP 接收页，点「配置 HTTPS」，再按页面步骤为该设备安装证书。

    iPhone 和 iPad

    下载描述文件后，在系统设置安装，再前往「通用 › 关于本机 › 证书信任设置」开启完全信任，最后打开 HTTPS 地址。

    Android

    下载 Android 证书，按接收页指引在系统设置中安装为 CA 证书，再打开 HTTPS 地址。系统菜单名称随品牌而异。
    """

    private func exportLog() {
        let text = DiagnosticsLog.shared.text
        guard !text.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carwithin-log.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        present(controller, animated: true)
    }
}
