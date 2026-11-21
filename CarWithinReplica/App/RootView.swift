import SwiftUI
import UIKit

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "car.fill") }
            SettingsTab()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

/// 把 UIKit 的 `ReceiverViewController` 放进 SwiftUI 的 TabView。
/// 原版设置页就是 `UITableViewController`，这里保持一致，不改成 SwiftUI。
struct SettingsTab: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ReceiverViewController())
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

#Preview {
    RootView().environmentObject(DiagnosticsLog.shared)
}
