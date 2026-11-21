import Foundation
import Network
import UIKit

/// 浏览器输出：App 内起一个 HTTP 服务，同局域网设备用 `http://IP:端口` 打开。
///
/// 当前实现为 MJPEG 推流（multipart/x-mixed-replace），兼容性最好；
/// 原版是 WebSocket + MSE/WebCodecs，画质更低延迟，但需要浏览器端播放器。
final class BrowserOutput {
    private let port: UInt16
    private let width: Int
    private let height: Int
    private let fps: Int

    private let queue = DispatchQueue(label: "carwithin.browser")
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var latestJPEG: Data?

    var onState: ((String) -> Void)?

    init(port: UInt16 = 9888, width: Int = 1280, height: Int = 720, fps: Int = 15) {
        self.port = port
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 9888)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let address = Self.localIPv4() ?? "127.0.0.1"
                let port = self?.port ?? 9888
                self?.onState?("浏览器输出已启动：http://\(address):\(port)")
            case .failed(let error):
                self?.onState?("浏览器输出启动失败：\(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        streams.values.forEach { $0.cancel() }
        streams.removeAll()
        onState?("浏览器输出已停止")
    }

    // MARK: - 帧

    private func renderFrame() {
        let index = frameIndex
        frameIndex += 1
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1).cgColor,
                          UIColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: 0, y: size.height), options: [])
            }
            let barWidth = CGFloat(max(24, width / 21))
            let x = CGFloat((index * 7) % max(1, width - Int(barWidth)))
            cg.setFillColor(UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1).cgColor)
            cg.fill(CGRect(x: x, y: 0, width: barWidth, height: size.height))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let text = "CarWithin\n\(index)"
            text.draw(in: CGRect(x: 0, y: size.height / 2 - 110, width: size.width, height: 220),
                      withAttributes: attributes)
        }
        latestJPEG = image.jpegData(compressionQuality: 0.6)
        pushFrame()
    }

    private func pushFrame() {
        guard let data = latestJPEG, !streams.isEmpty else { return }
        let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(data.count)\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(data)
        packet.append(Data("\r\n".utf8))
        for connection in streams.values {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            if request.contains("GET /stream") {
                self.startStream(connection)
            } else {
                self.respondIndex(connection)
            }
        }
    }

    private func respondIndex(_ connection: NWConnection) {
        let html = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>CarWithin</title>
        <style>
        body{margin:0;background:#0b0f16;color:#e6edf7;font:16px -apple-system,sans-serif;
        display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh}
        img{width:100%;max-width:1280px;border-radius:12px;box-shadow:0 8px 30px #0008}
        p{opacity:.6;margin-top:12px}
        </style>
        <img src="/stream" alt="CarWithin">
        <p>CarWithin · MJPEG \(width)×\(height)</p>
        </html>
        """
        let body = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func startStream(_ connection: NWConnection) {
        streams[ObjectIdentifier(connection)] = connection
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8),
                        completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.streams.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
    }

    // MARK: - 地址

    static func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                if name == "en0" { break }
            }
        }
        return address
    }
}
