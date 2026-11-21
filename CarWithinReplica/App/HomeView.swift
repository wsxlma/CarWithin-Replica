import SwiftUI
import UIKit

/// 首页：与原版截图一致的两张卡片。
/// 真正的 CarPlay 会话由 `CarPlayEngine` 提供，当前是占位实现。
struct HomeView: View {
    @EnvironmentObject private var diagnostics: DiagnosticsLog
    @StateObject private var engine = StubCarPlayEngine()
    @State private var showSettings = false
    @State private var showEngineAlert = false
    @State private var localIP: String = BrowserOutput.localIPv4() ?? "—"
    @State private var copied = false
    @State private var showHTTPS = false

    // 与原版一致：首页卡片跟随「当前输出」变化，而不是固定一张九号卡片。
    @AppStorage("output.mode") private var outputMode: String = "browser"
    @AppStorage("output.host") private var receiverHost: String = "192.168.1.1"
    @AppStorage("output.port") private var receiverPort: String = "9888"
    @AppStorage("wifi.ssid") private var wifiSSID: String = ""
    @AppStorage("wifi.open") private var wifiOpen: Bool = false
    @AppStorage("https.port") private var httpsPort: String = "9889"

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
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
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
        .onAppear { localIP = BrowserOutput.localIPv4() ?? "—" }
        .onChange(of: showSettings) { showing in
            if !showing { localIP = BrowserOutput.localIPv4() ?? "—" }
        }
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
                if engine.state == .running {
                    engine.stop()
                } else {
                    Task {
                        do {
                            try await engine.start(configuration: .placeholder)
                        } catch {
                            diagnostics.append("启动失败：\(error.localizedDescription)", level: .error)
                            showEngineAlert = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: engine.state == .running ? "stop.fill" : "play.fill")
                    Text(engine.state == .running ? "停止 CarPlay 推送" : "启动本机 CarPlay")
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    engine.state == .running
                    ? Color(red: 0.72, green: 0.20, blue: 0.22)
                    : Color(red: 0.04, green: 0.52, blue: 1.0),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Text("\(engine.state.title) · \(engine.state.detail)")
                .font(.system(size: 14))
                .foregroundStyle(engine.state == .running ? Color.green : Color.secondary)

            if engine.state == .running {
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前 Wi-Fi").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(wifiSSID.isEmpty ? "未连接" : wifiSSID)
                            .font(.system(size: 16, weight: .medium))
                        if wifiOpen {
                            Text("开放网络 · 无密码")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Text("编辑 Wi-Fi")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
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
        default: return "http://\(localIP):\(receiverPort)"
        }
    }

    @ViewBuilder
    private var outputCard: some View {
        if outputMode == "browser" {
            browserCard
        } else {
            deviceCard
        }
    }

    /// 浏览器输出：显示本机实时 IP，可复制，HTTPS 可折叠。
    private var browserCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                Text("局域网浏览器访问")
                    .font(.system(size: 18, weight: .semibold))
            }

            Text("兼容模式（HTTP）")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("http://\(localIP):\(receiverPort)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Button {
                    UIPasteboard.general.string = "http://\(localIP):\(receiverPort)"
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制").font(.system(size: 15, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.10, green: 0.22, blue: 0.36), in: Capsule())
                    .foregroundStyle(Color(red: 0.35, green: 0.66, blue: 1.0))
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showHTTPS.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("HTTPS（低延迟）")
                        .font(.system(size: 16, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(showHTTPS ? 180 : 0))
                }
                .foregroundStyle(Color(red: 0.35, green: 0.66, blue: 1.0))
            }
            .buttonStyle(.plain)

            if showHTTPS {
                Text("需在接收设备安装并信任证书后访问 https://\(localIP):\(httpsPort)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Text("启动后最多 4 台同时观看。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    private var deviceCard: some View {
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
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
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
