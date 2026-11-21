import Foundation
import Combine

/// 输出引擎。
///
/// 已实现：九号 5 寸 / 七寸仪表链路（H.264 → 私有 RTP → 五寸裸 UDP / 七寸 KCP）。
/// 未实现：CarPlay 会话本身。它依赖 CoreAccessories 私有配件传输与对应签名权限，
/// 原版二进制里也明确提示过 `CoreAccessories refused the connection`。
final class StubCarPlayEngine: ObservableObject, CarPlayEngine {
    static let unavailableReason = """
    当前输出不是仪表链路。CarPlay 会话依赖 CoreAccessories 私有接口，\
    该接口受签名权限约束，未接入前无法启动。
    """

    @Published private(set) var state: EngineState = .idle
    private var output: NinebotOutput?
    private var browser: BrowserOutput?
    private var carplay: CarPlaySession?

    func start(configuration: ReceiverConfiguration) async throws {
        if state == .running {
            DiagnosticsLog.shared.append("已在推送中，忽略重复启动")
            return
        }
        let mode = SettingsStore.output
        state = .connecting

        // CarPlay 会话始终先起：它负责产出画面，具体往哪送由输出类型决定。
        let session = CarPlaySession()
        session.onLog = { message in DiagnosticsLog.shared.append("[CarPlay] " + message) }
        session.onVideo = { [weak self] frame, key in self?.output?.push(frame: frame, key: key) }
        session.start()
        self.carplay = session

        if mode == "browser" {
            let port = UInt16(SettingsStore.receiverPort) ?? 9888
            let browser = BrowserOutput(port: port)
            browser.onState = { message in
                DiagnosticsLog.shared.append(message)
                DispatchQueue.main.async {
                    self.state = message.contains("已停止") ? .idle : .running
                }
            }
            do {
                try browser.start()
                self.browser = browser
                state = .running
            } catch {
                state = .failed
                DiagnosticsLog.shared.append("浏览器输出失败：\(error.localizedDescription)")
                throw error
            }
            return
        }

        guard mode == "ninebot5" || mode == "ninebot7" else {
            // CarPlay 已在监听，画面等对端接入；其他输出类型暂不额外启动 sink。
            state = .running
            return
        }
        let isSeven = mode == "ninebot7"
        let output = NinebotOutput(config: .init(
            host: SettingsStore.receiverHost,
            width: isSeven ? 1024 : 848,
            height: isSeven ? 600 : 480,
            fps: isSeven ? 25 : 30,
            useKCP: isSeven))

        output.onState = { [weak self] message in
            DiagnosticsLog.shared.append(message)
            DispatchQueue.main.async {
                self?.state = message == "已停止" ? .idle : .running
            }
        }
        output.onStats = { frames, retransmits in
            if frames % 125 == 0 {
                DiagnosticsLog.shared.append("已发送 \(frames) 帧 · 重传 \(retransmits)")
            }
        }

        do {
            try output.start()
            self.output = output
            state = .running
        } catch {
            state = .failed
            DiagnosticsLog.shared.append("启动失败：\(error.localizedDescription)")
            throw error
        }
    }

    func stop() {
        carplay?.stop()
        carplay = nil
        output?.stop()
        output = nil
        browser?.stop()
        browser = nil
        state = .idle
    }
}
