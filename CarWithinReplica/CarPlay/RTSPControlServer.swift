import Foundation
import Network

/// 自建端点第二步：本机 RTSP / 控制服务（原版日志中为端口 7000）。
/// 负责 /pair-setup、/pair-verify、/auth-setup、/info、/feedback、
/// SETUP、RECORD、POST /command，并把收到的媒体流交给输出端。
final class RTSPControlServer {
    static let shared = RTSPControlServer()

    var onLog: ((String) -> Void)?
    var onMedia: ((Data) -> Void)?

    private var listener: NWListener?
    private var mediaListeners: [NWListener] = []
    private var sessionID: String?
    private var nextPort: UInt16 = 50220
    private let queue = DispatchQueue(label: "carwithin.rtsp")

    /// 供自动重启守护判断服务是否还活着。
    private(set) var isReady = false
    private(set) var lastClientAt: Date?

    private init() {}

    func start(port: UInt16 = 7000) throws {
        stop()
        PairingState.shared.onLog = { [weak self] message in self?.onLog?("[配对] " + message) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 7000)
        listener = created
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.stateUpdateHandler = { [weak self] state in
            self?.onLog?("RTSP 监听状态：\(String(describing: state))")
            switch state {
            case .ready: self?.isReady = true
            case .failed, .cancelled: self?.isReady = false
            default: break
            }
        }
        created.start(queue: queue)
        onLog?("原生 RTSP 监听器已就绪，端口 \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        mediaListeners.forEach { $0.cancel() }
        mediaListeners.removeAll()
        sessionID = nil
        nextPort = 50220
        isReady = false
        lastClientAt = nil
        PairingState.shared.reset()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        lastClientAt = Date()
        onLog?("收到控制连接：\(String(describing: connection.endpoint))")
        readRequest(connection, accumulated: Data())
    }

    private func readRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let content { buffer.append(content) }
            guard error == nil else { connection.cancel(); return }

            if let (request, consumed) = self.parse(buffer) {
                self.handle(request, connection: connection)
                let rest = buffer.dropFirst(consumed)
                if !rest.isEmpty {
                    self.readRequest(connection, accumulated: Data(rest))
                } else {
                    self.readRequest(connection, accumulated: Data())
                }
            } else if isComplete {
                connection.cancel()
            } else {
                self.readRequest(connection, accumulated: buffer)
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func parse(_ data: Data) -> (Request, Int)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).lowercased()
                headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let bodyStart = headerEnd.upperBound
        let length = Int(headers["content-length"] ?? "") ?? 0
        let available = data.count - bodyStart
        guard available >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let consumed = bodyStart + length
        return (Request(method: String(parts[0]), path: String(parts[1]),
                        headers: headers, body: Data(body)), consumed)
    }

    private func handle(_ request: Request, connection: NWConnection) {
        let fields = Array(request.headers.keys).sorted().joined(separator: ", ")
        onLog?("\(request.method) \(request.path) [\(request.body.count) 字节] 字段：\(fields)")

        var payload = Data()
        var extraHeaders: [String] = []
        var contentType = "application/octet-stream"

        switch request.path {
        case "/pair-setup":
            payload = PairingState.shared.pairSetup(request.body)
            // AirPlay 规定配对接口必须回 application/pairing+tlv8，
            // 用 octet-stream 的话 iOS 会直接放弃握手。
            contentType = "application/pairing+tlv8"
            onLog?("Pair-Setup 状态 \(PairingState.shared.setupState)（回 \(payload.count)B TLV8）")
        case "/pair-verify":
            payload = PairingState.shared.pairVerify(request.body)
            contentType = "application/pairing+tlv8"
            onLog?("Pair-Verify 状态 \(PairingState.shared.setupState)（回 \(payload.count)B TLV8，已验证=\(PairingState.shared.verifiedController)）")
        case "/auth-setup":
            payload = PairingState.shared.authSetup(request.body)
            onLog?("已生成 MFiSAP 响应 \(payload.count)B（身份：\(MFIIdentity.shared.isReady ? "就绪" : "缺失")）")
            onLog?(IAP2Configuration.summary())
        case "/info":
            payload = infoPayload()
            contentType = "application/x-apple-binary-plist"
        case "/config":
            payload = Data(CarPlayConfiguration.summary().joined(separator: "\n").utf8)
            contentType = "text/plain; charset=utf-8"
        case "/stutter":
            SessionWatchdog.shared.reportStutter()
            onLog?("收到浏览器卡顿上报")
        case "/feedback", "/command":
            onLog?("控制反馈：\(String(decoding: request.body.prefix(160), as: UTF8.self))")
        default:
            break
        }

        let method = request.method.uppercased()
        switch method {
        case "SETUP":
            let session = sessionIdentifier()
            extraHeaders.append("Session: \(session);timeout=60")
            let bodyText = String(decoding: request.body, as: UTF8.self)
            let isAudio = bodyText.localizedCaseInsensitiveContains("audio")
                || bodyText.localizedCaseInsensitiveContains("AAC")
                || bodyText.contains("4194304")
            if let transport = setupTransport(request.headers["transport"] ?? "", audio: isAudio) {
                extraHeaders.append("Transport: \(transport.header)")
                onLog?("SETUP 已分配媒体端口 \(transport.port)，类型 \(transport.kind)")
            }
            extraHeaders.append("x-apple-video-codec: \(CarPlayConfiguration.isH265 ? "H.265" : "H.264")")
            extraHeaders.append("x-apple-display: \(CarPlayConfiguration.displayWidth)x\(CarPlayConfiguration.displayHeight)@\(CarPlayConfiguration.fps)")
            extraHeaders.append("x-apple-aspect-ratio: \(CarPlayConfiguration.aspectRatioText)")
            if !isAudio {
                onLog?("视频参数：\(CarPlayConfiguration.codecName) \(CarPlayConfiguration.displayWidth)×\(CarPlayConfiguration.displayHeight) @ \(CarPlayConfiguration.fps)FPS")
            }
        case "RECORD":
            extraHeaders.append("Session: \(sessionIdentifier())")
            onLog?("已接受 CarPlay RECORD，开始接收媒体")
        case "GET", "POST", "ANNOUNCE":
            break
        default:
            break
        }

        var head = "RTSP/1.0 200 OK\r\nCSeq: \(request.headers["cseq"] ?? "1")\r\n"
        if !payload.isEmpty {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(payload.count)\r\n"
        for extra in extraHeaders { head += extra + "\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sessionIdentifier() -> String {
        if let existing = sessionID { return existing }
        let created = UUID().uuidString.prefix(8)
        sessionID = String(created)
        return sessionID!
    }

    private func infoPayload() -> Data {
        return Data(CarPlayConfiguration.infoPlist().utf8)
    }

    private struct MediaTransport {
        var header: String
        var port: Int
        var kind: String
    }

    /// 根据 SETUP 的 Transport 头分配媒体端口，等 iPhone 把视频送进来。
    private func setupTransport(_ requested: String, audio: Bool) -> MediaTransport? {
        let isTCP = requested.uppercased().contains("TCP")
        let isUDP = requested.uppercased().contains("UDP")
        guard isTCP || isUDP else { return nil }

        let base = nextPort
        nextPort += 2
        let pair = base...(base + 1)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        for port in pair {
            guard let portNumber = NWEndpoint.Port(rawValue: port),
                  let listener = try? NWListener(using: parameters, on: portNumber) else {
                continue
            }
            listener.newConnectionHandler = { [weak self] (connection: NWConnection) in
                connection.start(queue: self?.queue ?? .main)
                self?.onLog?("媒体连接已建立（端口 \(port)，\(audio ? "音频" : "视频")）")
                self?.readMedia(connection, audio: audio)
            }
            listener.start(queue: queue)
            mediaListeners.append(listener)
        }

        let kind = isTCP ? "TCP" : "UDP"
        let header = isTCP
            ? "RTP/AVP/TCP;unicast;interleaved=0-1;server_port=\(base)"
            : "RTP/AVP/UDP;unicast;server_port=\(base)-\(base + 1)"
        return MediaTransport(header: header, port: Int(base), kind: kind)
    }

    private func readMedia(_ connection: NWConnection, audio: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) {
            [weak self] content, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            if let content, !content.isEmpty {
                SessionWatchdog.shared.noteActivity()
                if audio {
                    AudioSink.shared.feed(content)
                } else {
                    self.onMedia?(content)
                }
            }
            if isComplete { connection.cancel(); return }
            self.readMedia(connection, audio: audio)
        }
    }
}
