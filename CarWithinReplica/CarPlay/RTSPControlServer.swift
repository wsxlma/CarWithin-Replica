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
    /// SETUP 里协商出来的音频 interleaved 通道号。
    private var audioChannels = Set<UInt8>()
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
        audioChannels.removeAll()
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
            var buffer = Data(accumulated)
            if let content { buffer.append(content) }
            guard error == nil else { connection.cancel(); return }

            // 同一条 TCP 连接上可能交替出现 RTSP 文本与 RTP 交错帧（以 0x24 开头），
            // 必须逐帧剥离，否则媒体数据会被当成请求行解析而整条连接作废。
            while !buffer.isEmpty {
                if buffer[buffer.startIndex] == 0x24 {
                    guard buffer.count >= 4 else { break }
                    let start = buffer.startIndex
                    let channel = buffer[start + 1]
                    let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                    guard buffer.count >= 4 + length else { break }
                    let payload = buffer.subdata(in: (start + 4)..<(start + 4 + length))
                    self.handleInterleaved(channel: channel, payload: payload)
                    buffer = Data(buffer.dropFirst(4 + length))
                    continue
                }
                guard let (request, consumed) = self.parse(buffer) else { break }
                self.handle(request, connection: connection)
                buffer = Data(buffer.dropFirst(consumed))
            }

            if buffer.isEmpty, isComplete {
                connection.cancel()
                return
            }
            self.readRequest(connection, accumulated: buffer)
        }
    }

    /// RTP 交错帧：channel 奇偶区分音频/视频，具体由 SETUP 的 interleaved 参数决定。
    private func handleInterleaved(channel: UInt8, payload: Data) {
        SessionWatchdog.shared.noteActivity()
        if audioChannels.contains(channel) {
            AudioSink.shared.feed(payload)
        } else {
            onMedia?(payload)
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
        case "OPTIONS":
            // iOS 连上来的第一句就是 OPTIONS。拿不到 Public 列表它直接放弃整台车机。
            extraHeaders.append("Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER")
            onLog?("OPTIONS 已应答（宣告 9 个方法）")
        case "ANNOUNCE":
            let sdp = String(decoding: request.body, as: UTF8.self)
            onLog?("ANNOUNCE 收到 SDP \(request.body.count)B")
            for line in sdp.components(separatedBy: "\r\n") where line.hasPrefix("a=") {
                onLog?("  SDP " + line)
            }
            extraHeaders.append("Session: \(sessionIdentifier());timeout=60")
        case "FLUSH", "PAUSE", "TEARDOWN", "SET_PARAMETER", "GET_PARAMETER":
            onLog?("\(method) 已应答")
            if method != "TEARDOWN" {
                extraHeaders.append("Session: \(sessionIdentifier())")
            }
        case "SETUP":
            let session = sessionIdentifier()
            extraHeaders.append("Session: \(session);timeout=60")
            let bodyText = String(decoding: request.body, as: UTF8.self)
            // AirPlay 的 SETUP 路径形如 rtsp://host/streamid=0，音频流在 path 或 SDP 里有 audio 标记。
            let isAudio = request.path.lowercased().contains("audio")
                || bodyText.localizedCaseInsensitiveContains("m=audio")
                || bodyText.localizedCaseInsensitiveContains("AAC")
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
            extraHeaders.append("Audio-Latency: 11025")
            extraHeaders.append("Audio-Jack-Status: connected; type=analog")
            onLog?("已接受 RECORD，媒体流开始")
        case "GET", "POST", "ANNOUNCE":
            break
        default:
            break
        }

        var head = "RTSP/1.0 200 OK\r\n"
        head += "CSeq: \(request.headers["cseq"] ?? "1")\r\n"
        // iOS 会核对 Server 里的 AirTunes 版本，缺失时部分版本会直接断开。
        head += "Server: AirTunes/\(AirPlayIdentity.sourceVersion)\r\n"
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
        // 声明的是 application/x-apple-binary-plist，就必须真的回二进制 plist。
        // 之前直接发 XML 字符串，iOS 按二进制解析必然失败。
        let xml = Data(CarPlayConfiguration.infoPlist().utf8)
        guard let object = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let binary = try? PropertyListSerialization.data(fromPropertyList: object,
                                                              format: .binary,
                                                              options: 0) else {
            onLog?("警告：/info plist 转换失败，退回 XML")
            return xml
        }
        return binary
    }

    private struct MediaTransport {
        var header: String
        var port: Int
        var kind: String
    }

    /// 根据 SETUP 的 Transport 头分配媒体端口，等 iPhone 把视频送进来。
    private func setupTransport(_ requested: String, audio: Bool) -> MediaTransport? {
        let upper = requested.uppercased()
        let isTCP = upper.contains("TCP")
        let isUDP = upper.contains("UDP")
        guard isTCP || isUDP else { return nil }

        // 视频用 0-1，音频用 2-3；若 iOS 自己指定了 interleaved 就按它来。
        var channel: UInt8 = audio ? 2 : 0
        if let range = requested.range(of: "interleaved=") {
            let tail = requested[range.upperBound...]
            let head = tail.split(separator: ";").first ?? tail[...]
            let nums = head.split(separator: "-")
            if let first = nums.first, let value = UInt8(first) {
                channel = value
            }
        }
        if audio {
            audioChannels.insert(channel)
            audioChannels.insert(channel &+ 1)
        }

        // TCP 交错模式：媒体与控制复用同一条连接，不另开端口。
        if isTCP {
            let header = "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel &+ 1);mode=record"
            return MediaTransport(header: header, port: 0, kind: "TCP")
        }

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

        let header = "RTP/AVP/UDP;unicast;server_port=\(base)-\(base + 1);mode=record"
        return MediaTransport(header: header, port: Int(base), kind: "UDP")
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
