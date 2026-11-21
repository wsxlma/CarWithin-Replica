import SwiftUI

/// 首页：连接状态 + 启动入口。
/// 真正的 CarPlay 会话由 `CarPlayEngine` 提供；当前是占位实现。
struct HomeView: View {
    @EnvironmentObject private var diagnostics: DiagnosticsLog
    @StateObject private var engine: StubCarPlayEngine = StubCarPlayEngine()
    @State private var showEngineAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: engine.state.symbolName)
                            .font(.system(size: 30))
                            .foregroundStyle(engine.state.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.state.title).font(.headline)
                            Text(engine.state.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button {
                        Task {
                            do {
                                try await engine.start(configuration: .placeholder)
                            } catch {
                                diagnostics.append("启动失败：\(error.localizedDescription)")
                                showEngineAlert = true
                            }
                        }
                    } label: {
                        Label("启动 CarPlay", systemImage: "play.fill")
                    }
                    .disabled(engine.state == .running)

                    Button(role: .destructive) {
                        engine.stop()
                        diagnostics.append("已停止会话")
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .disabled(engine.state != .running)
                } footer: {
                    Text("核心通道尚未接入。CarPlay 会话依赖私有配件传输，需要真机与对应签名权限。")
                }
            }
            .navigationTitle("CarWithin")
            .alert("核心通道未接入", isPresented: $showEngineAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(StubCarPlayEngine.unavailableReason)
            }
        }
    }
}

#Preview {
    HomeView().environmentObject(DiagnosticsLog())
}
