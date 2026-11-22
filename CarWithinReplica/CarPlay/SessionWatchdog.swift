import Foundation
import UIKit

/// 会话守护：自动重启 + 卡顿降级。
///
/// 设置页「自动重启」的说明是「先降到 30 FPS，再降到 720P，每次连接最多两次」，
/// 这里按同一规则实现：降级只作用于本次连接（内存覆盖，不改用户设置）。
final class SessionWatchdog {
    static let shared = SessionWatchdog()

    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "carwithin.watchdog")
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var expectedRunning = false
    private var lastActivityAt = Date()
    private var restartCount = 0
    private var restarting = false
    private var lastSignature = ""

    private init() {}

    func start() {
        stop()
        lastSignature = CarPlayConfiguration.signature

        // 回前台观察与「自动重启」无关，始终注册，用于热应用改过的设置。
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.onLog?("[守护] 回到前台，检查服务状态与设置变更")
                self?.applyChangedSettings()
                self?.queue.async { self?.check(force: true) }
            }

        guard CarPlayConfiguration.autoRestart else {
            onLog?("[守护] 自动重启已关闭（设置热应用仍生效）")
            return
        }
        expectedRunning = true
        lastActivityAt = Date()
        restartCount = 0
        CarPlayConfiguration.degradation = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer

        onLog?("[守护] 自动重启已启用（5 秒巡检，卡顿最多降级两次）")
    }

    func stop() {
        expectedRunning = false
        timer?.cancel()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
        CarPlayConfiguration.degradation = 0
        restartCount = 0
    }

    /// 设置改动后，热应用不需要重建监听器的部分。
    private func applyChangedSettings() {
        let signature = CarPlayConfiguration.signature
        guard signature != lastSignature else { return }
        lastSignature = signature
        CarPlayConfiguration.applyAppearance()
        BonjourPublisher.shared.republish()
        VideoSink.shared.applyConfiguration()
        onLog?("[守护] 设置已变更：外观 / 广播 / 解码器已热应用（分辨率与帧率需重启 CarPlay）")
    }

    /// 视频/音频有数据进来时调用，作为「链路还活着」的证据。
    func noteActivity() {
        lastActivityAt = Date()
    }

    /// 浏览器端上报卡顿时调用。
    func reportStutter() {
        queue.async { [weak self] in
            guard let self, self.expectedRunning else { return }
            self.onLog?("[守护] 浏览器上报卡顿，准备降级重启")
            self.performRestart(reason: "浏览器卡顿")
        }
    }

    private func check(force: Bool = false) {
        guard expectedRunning, !restarting else { return }

        if !RTSPControlServer.shared.isReady {
            performRestart(reason: "RTSP 监听器掉线")
            return
        }

        guard force || RTSPControlServer.shared.lastClientAt != nil else { return }
        let idle = Date().timeIntervalSince(lastActivityAt)
        guard idle > 30 else { return }
        performRestart(reason: String(format: "连接后 %.0f 秒无媒体数据", idle))
    }

    private func performRestart(reason: String) {
        guard !restarting else { return }
        guard restartCount < 2 else {
            onLog?("[守护] 本次连接已降级两次，不再自动重启")
            return
        }
        restarting = true
        restartCount += 1
        CarPlayConfiguration.degradation = restartCount
        let level = restartCount == 1 ? "30 FPS" : "30 FPS + 720P"
        onLog?("[守护] \(reason) → 第 \(restartCount) 次自动重启（降级至 \(level)）")

        DispatchQueue.main.async { [weak self] in
            CarPlayReceiver.shared.stop()
            CarPlayReceiver.shared.start()
            self?.lastActivityAt = Date()
            self?.queue.async { self?.restarting = false }
        }
    }
}
