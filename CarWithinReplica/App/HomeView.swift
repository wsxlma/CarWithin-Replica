import SwiftUI
import UIKit

/// 首页：与原版截图一致的两张卡片。
/// 真正的 CarPlay 会话由 `CarPlayEngine` 提供，当前是占位实现。
struct HomeView: View {
    @EnvironmentObject private var diagnostics: DiagnosticsLog
    @StateObject private var engine = StubCarPlayEngine()
    @State private var showSettings = false
    @State private var showEngineAlert = false

    // 与原版一致：首页卡片跟随「当前输出」变化，而不是固定一张九号卡片。
    @AppStorage("output.mode") private var outputMode: String = "browser"
    @AppStorage("output.host") private var receiverHost: String = "192.168.1.1"
    @AppStorage("output.port") private var receiverPort: String = "9888"

    private let cardBackground = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    carPlayCard
                    outputCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.black)
            .navigationTitle("CarWithin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(white: 0.22), in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .preferredColorScheme(.dark)
            }
            .alert("核心通道未接入", isPresented: $showEngineAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(StubCarPlayEngine.unavailableReason)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 卡片

    private var carPlayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机 CarPlay")
                        .font(.system(size: 28, weight: .bold))
                    Text("(1.0.2)")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            Text("无需外接盒子，直接在这台 iPhone 上启动并显示 CarPlay。")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("准备就绪")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(red: 0.06, green: 0.15, blue: 0.24), in: RoundedRectangle(cornerRadius: 10))

            Text("先在系统设置连接 Wi-Fi，再在 CarWithin 选择对应预设。")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Text("请在设置中添加或选择 Wi-Fi 预设。")
                .font(.system(size: 16, weight: .semibold))

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
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("启动本机 CarPlay").font(.system(size: 18, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(red: 0.04, green: 0.52, blue: 1.0), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Text("\(engine.state.title) · \(engine.state.detail)")
                .font(.system(size: 14))
                .foregroundStyle(engine.state == .running ? Color.green : Color.secondary)
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    // 当前输出对应的卡片。原版不是固定展示「九号 5 寸」，而是跟着设置变化。
    private var outputTitle: String {
        switch outputMode {
        case "ninebot5": return "九号 5 寸连接"
        case "ninebot7": return "九号 7 寸连接"
        case "tailing": return "台铃 4.3 寸连接"
        case "carlife": return "无线 CarLife"
        case "airplay": return "AirPlay 接收"
        default: return "浏览器输出"
        }
    }

    private var outputSymbol: String {
        switch outputMode {
        case "browser": return "safari"
        case "carlife": return "car.side"
        case "airplay": return "airplayvideo"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }

    private var outputHint: String {
        switch outputMode {
        case "browser": return "让接收设备连到同一 Wi-Fi，打开 App 显示的地址。"
        case "carlife": return "让车机与 iPhone 连到同一 Wi-Fi，再打开车机上的 CarLife。"
        case "airplay": return "启动后从主界面连接卡片选择同一网络中的接收器。"
        default: return "让 iPhone 加入仪表 Wi-Fi，打开仪表投屏后启动 CarPlay。"
        }
    }

    private var outputDetail: String {
        switch outputMode {
        case "ninebot5": return "等待启动 CarPlay · 仪表 IP: \(receiverHost) · 848×480"
        case "ninebot7": return "等待启动 CarPlay · 仪表 IP: \(receiverHost) · 1024×600"
        case "tailing": return "等待启动 CarPlay · 仪表 IP: \(receiverHost) · 480×272"
        case "carlife": return "等待启动 CarPlay · 车机地址: \(receiverHost)"
        case "airplay": return "等待启动 CarPlay · 请在接收设备选择 AirPlay"
        default: return "接收地址 · \(receiverHost):\(receiverPort)"
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: outputSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
                Text(outputTitle)
                    .font(.system(size: 18, weight: .semibold))
            }

            Text(outputHint)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Text(outputDetail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Button {
                showSettings = true
            } label: {
                Text("连接设置")
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.10, green: 0.22, blue: 0.36), in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(Color(red: 0.35, green: 0.66, blue: 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// 把 UIKit 的设置页装进 SwiftUI 的 sheet。
struct SettingsSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: ReceiverViewController())
        navigation.navigationBar.prefersLargeTitles = false
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

#Preview {
    HomeView().environmentObject(DiagnosticsLog.shared)
}
