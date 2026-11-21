import Foundation
import UIKit
import Darwin

/// 探测 CoreAccessories 是否可用。
///
/// 原版靠 `ACCTransportClient` 建立虚拟配件传输，二进制里也提示过
/// `CoreAccessories refused the connection`。自签包能不能拿到它，决定后续
/// CarPlay 逆向是否值得投入，所以先做成一个可点的自检项。
enum TransportProbe {
    struct Report {
        let frameworkLoaded: Bool
        let classFound: Bool
        let detail: String

        var summary: String {
            if !frameworkLoaded { return "CoreAccessories 未加载" }
            return classFound ? "找到 ACCTransportClient" : "已加载，但找不到 ACCTransportClient"
        }
    }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories"

    static func run() -> Report {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "未知原因"
            return Report(frameworkLoaded: false, classFound: false,
                          detail: "dlopen 失败：\(reason)")
        }
        defer { dlclose(handle) }

        let cls = NSClassFromString("ACCTransportClient")
        if cls != nil {
            return Report(frameworkLoaded: true, classFound: true,
                          detail: "已加载 CoreAccessories，且能取到 ACCTransportClient。下一步应尝试建立 endpoint。")
        }
        return Report(frameworkLoaded: true, classFound: false,
                      detail: "已加载 CoreAccessories，但取不到 ACCTransportClient；可能是符号改名或权限限制。")
    }

    /// 提供给诊断页展示的设备与构建信息。
    static func environmentSummary() -> String {
        let device = UIDevice.current
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(device.model) · \(device.systemName) \(device.systemVersion) · App \(version)(\(build))"
    }
}
