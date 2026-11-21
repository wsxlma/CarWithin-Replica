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

    func start(configuration: ReceiverConfiguration) async throws {
        let mode = SettingsStore.output
        guard mode == "ninebot5" || mode == "ninebot7" else {
            state = .failed
            throw EngineError.notImplemented
        }

        state = .connecting
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
        output?.stop()
        output = nil
        state = .idle
    }
}
