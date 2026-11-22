import Foundation
import Network

/// 自建端点总编排：Bonjour 广播 → RTSP 控制 → 视频通道 → 输出。
/// 这条链路不依赖 ACCTransportClient，也不需要配件 entitlement。
final class CarPlayReceiver {
    static let shared = CarPlayReceiver()

    var onLog: ((String) -> Void)?
    private var videoListener: NWListener?
    private let queue = DispatchQueue(label: "carwithin.video")

    private init() {}

    func start() {
        stop()
        BonjourPublisher.shared.onLog = { [weak self] in self?.onLog?("[端点] " + $0) }
        RTSPControlServer.shared.onLog = { [weak self] in self?.onLog?("[端点] " + $0) }
        VideoSink.shared.onLog = { [weak self] in self?.onLog?("[视频] " + $0) }
        RTSPControlServer.shared.onMedia = { data in
            SessionWatchdog.shared.noteActivity()
            VideoSink.shared.feed(data)
        }
        VideoSink.shared.start()
        AudioSink.shared.onLog = { [weak self] in self?.onLog?("[音频] " + $0) }
        AudioSink.shared.start()

        do {
            try RTSPControlServer.shared.start(port: 7000)
        } catch {
            onLog?("[端点] RTSP 启动失败：\(error.localizedDescription)")
        }

        startVideoListener()
        CarPlayConfiguration.applyAppearance()
        BonjourPublisher.shared.start(port: 7000)
        onLog?("[端点] 自建端点已启动，等待 iOS 的 CarPlay 栈接入")
    }

    func stop() {
        AudioSink.shared.stop()
        VideoSink.shared.stop()
        RTSPControlServer.shared.stop()
        BonjourPublisher.shared.stop()
        videoListener?.cancel()
        videoListener = nil
    }

    private func startVideoListener() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 50219) ?? 50219) else { return }
        videoListener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.onLog?("[端点] 视频 TCP 通道已连接（50219）")
            self?.readVideo(connection)
        }
        listener.start(queue: queue)
        onLog?("[端点] 视频监听器已在端口 50219 就绪")
    }

    private func readVideo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] content, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            if let content, !content.isEmpty {
                SessionWatchdog.shared.noteActivity()
                VideoSink.shared.feed(content)
            }
            if isComplete { connection.cancel(); return }
            self.readVideo(connection)
        }
    }
}
