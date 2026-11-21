import Foundation
import Darwin

/// 九号仪表输出：H.264 → 私有 RTP →（七寸可选 KCP）→ UDP 5012。
/// 五寸：裸 RTP；七寸：同一份 RTP 作为 KCP 负载，conv=3。
final class NinebotOutput {
    struct Configuration {
        var host: String
        var width: Int
        var height: Int
        var fps: Int
        var useKCP: Bool
        var videoPort: UInt16 = 5012
        var bitrate: Int = 2_000_000
    }

    private let config: Configuration
    private let queue = DispatchQueue(label: "carwithin.ninebot")
    private var socketFD: Int32 = -1
    private var kcp: KCP?
    private var encoder: H264Encoder?
    private var timer: DispatchSourceTimer?
    private var readSource: DispatchSourceRead?
    private var frameIndex = 0
    private var startedAt = Date()

    var onState: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?

    init(config: Configuration) {
        self.config = config
    }

    func start() throws {
        guard let encoder = H264Encoder(width: config.width, height: config.height,
                                        fps: config.fps, bitrate: config.bitrate) else {
            throw NSError(domain: "NinebotOutput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 H.264 编码器"])
        }
        self.encoder = encoder

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "NinebotOutput", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 UDP socket"])
        }
        socketFD = fd

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd); socketFD = -1
            throw NSError(domain: "NinebotOutput", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "绑定本地端口失败"])
        }

        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = config.videoPort.bigEndian
        remote.sin_addr.s_addr = inet_addr(config.host)
        let connectResult = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd); socketFD = -1
            throw NSError(domain: "NinebotOutput", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法连接到仪表 \(config.host)"])
        }

        if config.useKCP {
            let kcp = KCP(conv: 3) { [weak self] data in self?.sendRaw(data) }
            kcp.setNoDelay()
            kcp.setWindow()
            kcp.setMTU(1400)
            self.kcp = kcp
        }

        encoder.onFrame = { [weak self] data, key in
            self?.sendFrame(data, key: key)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(config.fps))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        startReadLoop()
        onState?("正在发送 \(config.width)×\(config.height) · \(config.useKCP ? "KCP" : "RTP")")
    }

    func stop() {
        timer?.cancel(); timer = nil
        readSource?.cancel(); readSource = nil
        if socketFD >= 0 {
            sendRaw(NinebotRTP.bye)
            close(socketFD)
            socketFD = -1
        }
        encoder?.invalidate()
        encoder = nil
        kcp = nil
        onState?("已停止")
    }

    // MARK: - 发送

    private func tick() {
        guard let encoder, socketFD >= 0 else { return }
        let index = frameIndex
        frameIndex += 1

        guard let buffer = TestPattern.makeBuffer(width: config.width,
                                                 height: config.height,
                                                 frame: index) else { return }
        let pts = Int64(Date().timeIntervalSince(startedAt) * 1000)
        encoder.encode(buffer, ptsMS: pts)

        if let kcp {
            kcp.update(UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
            onStats?(frameIndex, kcp.retransmits)
        }
    }

    private func sendFrame(_ data: Data, key: Bool) {
        let ts = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(startedAt) * 1000))
        let packets = NinebotRTP.packets(for: data, timestampMs: ts, key: key, repeatKey: false)
        for packet in packets {
            if let kcp {
                kcp.send(packet)
            } else {
                sendRaw(packet)
            }
        }
    }

    private func sendRaw(_ data: Data) {
        guard socketFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.send(socketFD, base, data.count, 0)
        }
    }

    private func startReadLoop() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.socketFD >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = recv(self.socketFD, &buffer, buffer.count, 0)
            guard count > 0, let kcp = self.kcp else { return }
            kcp.input(Data(buffer[0..<count]))
        }
        source.resume()
        readSource = source
    }
}
