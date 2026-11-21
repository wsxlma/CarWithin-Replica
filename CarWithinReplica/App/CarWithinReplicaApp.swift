import SwiftUI

@main
struct CarWithinReplicaApp: App {
    @StateObject private var diagnostics = DiagnosticsLog.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(diagnostics)
        }
    }
}
