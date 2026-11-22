import Foundation

/// 媒体总线：把 CarPlay 视频通道收到的字节交给解码器，
/// 再把 JPEG 帧和原始访问单元分发给浏览器输出。
final class VideoSink {
    static let shared = VideoSink()

    private var decoder: CarPlayVideoDecoder?
    var onFrame: ((Data) -> Void)?
    var onAccessUnit: ((Data, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private init() {}

    func start() {
        let created = CarPlayVideoDecoder(codec: SettingsStore.codec)
        created.onLog = { [weak self] in self?.onLog?($0) }
        created.onFrame = { [weak self] jpeg in
            self?.onFrame?(jpeg)
        }
        created.onAccessUnit = { [weak self] unit, keyframe in
            self?.onAccessUnit?(unit, keyframe)
        }
        decoder = created
    }

    func stop() {
        decoder?.reset()
        decoder = nil
    }

    func feed(_ data: Data) {
        guard let decoder else { return }
        decoder.feed(data)
    }
}
