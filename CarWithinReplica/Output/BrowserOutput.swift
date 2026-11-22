import Foundation
import Network
import UIKit
import CryptoKit

/// 浏览器输出：HTTP 服务 + WebSocket 视频通道。
/// 页面优先用 WebCodecs 解码 H.265/H.264 并渲染 canvas；
/// 浏览器不支持时回退到 MJPEG。
final class BrowserOutput {
    private let port: UInt16
    private let width: Int
    private let height: Int
    private let fps: Int

    private let queue = DispatchQueue(label: "carwithin.browser")
    private var listener: NWListener?
    private var mjpegStreams: [ObjectIdentifier: NWConnection] = [:]
    private var webSocketStreams: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var latestJPEG: Data?
    private var startAttempts = 0

    // 访问单元装配：把单个 NAL 聚成一帧
    private var pendingUnit: Data = Data()
    private var hasPendingUnit = false

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

        VideoSink.shared.onFrame = { [weak self] jpeg in
            self?.queue.async {
                self?.latestJPEG = jpeg
                self?.pushFrame()
            }
        }
        VideoSink.shared.onAccessUnit = { [weak self] nal, keyframe in
            self?.queue.async {
                self?.appendAccessUnit(nal, keyframe: keyframe)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        mjpegStreams.values.forEach { $0.cancel() }
        mjpegStreams.removeAll()
        webSocketStreams.values.forEach { $0.cancel() }
        webSocketStreams.removeAll()
        onState?("浏览器输出已停止")
    }

    // MARK: - 帧

    private func renderFrame() {
        if latestJPEG != nil {
            pushFrame()
            return
        }
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
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let text = "等待 CarPlay 画面\n\nCarPlay 会话尚未建立"
            text.draw(in: CGRect(x: 0, y: size.height / 2 - 90, width: size.width, height: 180),
                      withAttributes: attributes)
        }
        latestJPEG = image.jpegData(compressionQuality: 0.6)
        pushFrame()
    }

    private func pushFrame() {
        guard let data = latestJPEG, !mjpegStreams.isEmpty else { return }
        let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(data.count)\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(data)
        packet.append(Data("\r\n".utf8))
        for connection in mjpegStreams.values {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// 把单个 NAL 装配成访问单元，推给 WebSocket。
    private func appendAccessUnit(_ nal: Data, keyframe: Bool) {
        if hasPendingUnit && keyframe {
            flushAccessUnit()
        }
        if !hasPendingUnit {
            hasPendingUnit = true
            pendingUnit.removeAll(keepingCapacity: true)
        }
        var length = UInt32(nal.count).bigEndian
        pendingUnit.append(withUnsafeBytes(of: &length) { Data($0) })
        pendingUnit.append(nal)
    }

    private func flushAccessUnit() {
        guard hasPendingUnit, !pendingUnit.isEmpty, !webSocketStreams.isEmpty else {
            pendingUnit.removeAll(keepingCapacity: true)
            hasPendingUnit = false
            return
        }
        var header = Data([0x82]) // 二进制帧，FIN
        let size = pendingUnit.count
        if size < 126 {
            header.append(UInt8(0x80 | size))
        } else if size < 65536 {
            header.append(UInt8(0x80 | 126))
            var big = UInt16(size).bigEndian
            header.append(withUnsafeBytes(of: &big) { Data($0) })
        } else {
            header.append(UInt8(0x80 | 127))
            var big = UInt64(size).bigEndian
            header.append(withUnsafeBytes(of: &big) { Data($0) })
        }
        var packet = header
        packet.append(pendingUnit)
        for connection in webSocketStreams.values {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        pendingUnit.removeAll(keepingCapacity: true)
        hasPendingUnit = false
    }

    // MARK: - HTTP / WebSocket

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            if request.contains("GET /stream") {
                self.startStream(connection)
            } else if request.contains("GET /ws"),
                      let key = Self.webSocketKey(from: request) {
                self.startWebSocket(connection, key: key)
            } else {
                self.respondIndex(connection)
            }
        }
    }

    private func startStream(_ connection: NWConnection) {
        mjpegStreams[ObjectIdentifier(connection)] = connection
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.mjpegStreams.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
    }

    private func startWebSocket(_ connection: NWConnection, key: String) {
        webSocketStreams[ObjectIdentifier(connection)] = connection
        let accept = Self.webSocketAccept(key)
        let header = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.webSocketStreams.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
    }

    private static func webSocketKey(from request: String) -> String? {
        for line in request.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("sec-websocket-key:") {
                return line.dropFirst("sec-websocket-key:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func webSocketAccept(_ key: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    private func respondIndex(_ connection: NWConnection) {
        let codec = SettingsStore.codec.contains("264") ? "avc1.42E01F" : "hvc1.1.6.L123.B0"
        let html = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>CarWithin</title>
        <style>
        body{margin:0;background:#0b0f16;color:#e6edf7;font:16px -apple-system,sans-serif;
        display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh}
        canvas,img{width:100%;max-width:1280px;border-radius:12px;box-shadow:0 8px 30px #0008}
        .status{opacity:.6;margin-top:12px;font-size:14px}
        </style>
        <canvas id="video" width="\(width)" height="\(height)"></canvas>
        <img id="fallback" src="/stream" style="display:none">
        <div class="status" id="status">正在连接…</div>
        <script>
        const codec="\(codec)";
        const canvas=document.getElementById('video');
        const ctx=canvas.getContext('2d');
        const status=document.getElementById('status');
        let decoder=null, ws=null, keyframeReady=false;

        function showFallback(){canvas.style.display='none';document.getElementById('fallback').style.display='block';}

        function initDecoder(){
          if(typeof VideoDecoder==='undefined'){showFallback();return;}
          try{
            decoder=new VideoDecoder({output:(frame)=>{ctx.drawImage(frame,0,0,canvas.width,canvas.height);frame.close();},error:(e)=>{status.textContent='解码错误：'+e.message;}});
            decoder.configure({codec:codec, optimizeForLatency:true});
            status.textContent='WebCodecs 就绪，等待视频…';
          }catch(e){showFallback();}
        }

        function connect(){
          ws=new WebSocket('ws://'+location.host+'/ws');
          ws.binaryType='arraybuffer';
          ws.onopen=()=>{status.textContent='已连接，等待视频…';};
          ws.onmessage=(event)=>{
            const data=new Uint8Array(event.data);
            if(data.length<5||!decoder)return;
            const isKey=(data[4]&0x1F)===5||((data[4]>>1)&0x3F)===19||((data[4]>>1)&0x3F)===20;
            if(!keyframeReady){if(!isKey)return;keyframeReady=true;}
            try{
              decoder.decode(new EncodedVideoChunk({type:isKey?'key':'delta',timestamp:performance.now(),data:data}));
            }catch(e){status.textContent='解码失败：'+e.message;}
          };
          ws.onclose=()=>{status.textContent='连接断开，3 秒后重连…';keyframeReady=false;setTimeout(connect,3000);};
          ws.onerror=()=>{showFallback();};
        }

        initDecoder();
        connect();
        </script>
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
