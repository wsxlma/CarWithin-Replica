import SwiftUI

/// 根视图：与原版一致，首页即全部内容，设置以 sheet 呈现。
struct RootView: View {
    var body: some View {
        HomeView()
    }
}

#Preview {
    RootView().environmentObject(DiagnosticsLog.shared)
}
