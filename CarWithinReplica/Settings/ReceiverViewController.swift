import UIKit

/// 设置页内容，对应原版的 `ReceiverViewController`。
///
/// 原版 `aboutLinks()` 返回一组支持入口（支持页 / 关注作者 / 请我喝杯咖啡 /
/// 诊断与实验 / 关于）。按需求这里**只保留「诊断与实验」**，其余四项不再构造，
/// 因此界面上不会出现，也不存在被隐藏但仍可触发的路径。
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
        var sections: [SettingsSection] = [
            SettingsSection(header: "连接", rows: [
                .page("Wi-Fi 与网络", icon: "wifi",
                      detail: "填写仪表或车机的 Wi-Fi 名称与密码") {
                    GuideViewController(title: "Wi-Fi 与网络",
                                        text: "在此保存仪表 Wi-Fi 的名称与密码。\n\n原版按 SSID 只保留一条预设，修改密码时更新原记录。")
                },
                .page("Wi-Fi 预设", icon: "bookmark",
                      detail: "按 SSID 保存，换网时点选") {
                    GuideViewController(title: "Wi-Fi 预设",
                                        text: "切换网络时点选已保存的预设即可。\n\n左滑删除预设时会同时删除该网络保存的密码。")
                },
                .guide("当前输出", icon: "rectangle.connected.to.line.below",
                       text: "可选输出：浏览器、九号 5 寸、九号 7 寸（实验）、台铃 4.3 寸（实验）、无线 CarLife、AirPlay（实验）。\n\n选择后返回即可保存。"),
                .guide("输出设置", icon: "slider.horizontal.3",
                       text: "设置接收端地址、端口与画面参数。\n\n仪表类输出需要先加入仪表 Wi-Fi，再填写仪表 IP。"),
            ]),
            SettingsSection(header: "画面", rows: [
                .guide("画面尺寸", icon: "arrow.up.left.and.arrow.down.right",
                       text: "车机拉伸画面或出现黑屏时，可尝试固定分辨率、30 FPS 与 H.264。"),
                .guide("帧率", icon: "speedometer",
                       text: "九号 5 寸默认 30 FPS，九号 7 寸标称 25 FPS，台铃 4.3 寸最高 20 FPS。"),
            ]),
            SettingsSection(header: "CarPlay", rows: [
                .guide("外观与驾驶位", icon: "car.side",
                       text: "可切换深浅色外观与左舵/右舵布局。"),
                .guide("后台与画中画", icon: "pip",
                       text: "选择画中画的开启时机。使用锁屏继续运行前，需在系统设置中允许 CarWithin 在锁定时使用 CarPlay。"),
            ]),
            SettingsSection(header: "支持", rows: aboutLinks()),
        ]

        // 原版此处分「实验」与「浏览器输出」两组。
        sections.append(contentsOf: experimentSections())
        sections.append(contentsOf: browserOutputSections())
        return sections
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

    // MARK: - 其余分组

    private func experimentSections() -> [SettingsSection] {
        [
            SettingsSection(header: "实验", footer: "实验功能可能随版本调整。", rows: [
                .guide("同机 CarPlay 探测", icon: "wave.3.right",
                       text: "用于确认本机是否能建立 CarPlay 会话。\n\n若提示 CoreAccessories 拒绝连接，说明签名缺少私有传输权限，与代码无关。"),
            ]),
        ]
    }

    private func browserOutputSections() -> [SettingsSection] {
        [
            SettingsSection(header: "浏览器输出", footer: "局域网接收页没有登录校验，请在可信网络中使用。", rows: [
                .guide("HTTP 与 HTTPS", icon: "network",
                       text: "HTTP 默认 9888，兼容性优先；HTTPS 默认 9889，浏览器支持 WebCodecs 时延迟更低。"),
                .guide("HTTPS 证书", icon: "lock.shield",
                       text: "在接收设备上打开接收页并选择「配置 HTTPS」，按提示安装并信任证书。"),
            ]),
        ]
    }
}
