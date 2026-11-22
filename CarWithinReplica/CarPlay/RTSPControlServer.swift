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
    private let queue = DispatchQueue(label: "carwithin.rtsp")

    private init() {}

    func start(port: UInt16 = 7000) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 7000)
        listener = created
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.stateUpdateHandler = { [weak self] state in
            self?.onLog?("RTSP 监听状态：\(String(describing: state))")
        }
        created.start(queue: queue)
        onLog?("原生 RTSP 监听器已就绪，端口 \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        PairingState.shared.reset()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
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
        if request.path.hasPrefix("rtsp://") {
            onMedia?(request.body)
        }

        var payload = Data()
        switch request.path {
        case "/pair-setup":
            payload = PairingState.shared.pairSetup(request.body)
            onLog?("Pair-Setup 状态 \(PairingState.shared.setupState)")
        case "/pair-verify":
            payload = PairingState.shared.pairVerify(request.body)
            onLog?("Pair-Verify 已通过，启用加密控制")
        case "/auth-setup":
            payload = PairingState.shared.authSetup(request.body)
            onLog?("已生成 MFiSAP 响应（身份：\(MFIIdentity.shared.isReady ? "就绪" : "缺失")）")
        case "/info":
            payload = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>name</key><string>CarWithin</string></dict></plist>".utf8)
        default:
            break
        }

        if request.method.uppercased() == "SETUP" {
            onLog?("SETUP 字段：\(fields)")
        } else if request.method.uppercased() == "RECORD" {
            onLog?("已接受 CarPlay RECORD，等待视频")
        }

        let response = "RTSP/1.0 200 OK\r\nCSeq: \(request.headers["cseq"] ?? "1")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(payload.count)\r\n\r\n"
        var data = Data(response.utf8)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
