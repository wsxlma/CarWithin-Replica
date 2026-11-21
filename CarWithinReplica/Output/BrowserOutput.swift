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
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var latestJPEG: Data?
    private var startAttempts = 0

    var onState: ((String) -> Void)?

    init(port: UInt16 = 9888, width: Int = 1280, height: Int = 720, fps: Int = 15) {
        self.port = port
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() throws {
        guard listener == nil else {
            onState?("浏览器输出已在运行，跳过重复启动")
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 9888)
        } catch {
            startAttempts += 1
            if startAttempts <= 3 {
                onState?("端口 \(port) 占用，0.8 秒后重试（第 \(startAttempts) 次）")
                queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    try? self?.start()
                }
                return
            }
            throw error
        }
        startAttempts = 0

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
            if request.contains("GET /frame.jpg") {
                self.respondFrame(connection)
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
        html,body{margin:0;height:100%;background:#000}
        body{display:flex;align-items:center;justify-content:center}
        img{width:100%;height:100%;object-fit:contain;display:block}
        </style>
        <img id="v" src="/frame.jpg" alt="CarWithin">
        <script>
        const img=document.getElementById('v');
        setInterval(()=>{img.src='/frame.jpg?t='+Date.now();},80);
        </script>
        </html>
        """
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respondFrame(_ connection: NWConnection) {
        guard let frame = latestJPEG else {
            let empty = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(empty.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n"
            + "Content-Length: \(frame.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(frame)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
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
