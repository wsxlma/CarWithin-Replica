import Foundation
import Network
import UIKit
import CryptoKit

/// 浏览器输出：HTTP 服务 + 视频 WebSocket + 音频 WebSocket。
///
/// 页面从 CarPlayConfiguration 读取全部车机参数：外观主题、驾驶位方向、
/// 车辆名称/按钮、图标大小、画面比例、性能档位、触摸点、声音路由。
/// 设置改了以后，刷新页面即可生效。
final class BrowserOutput {
    private let port: UInt16
    private let width: Int
    private let height: Int
    private let fps: Int

    private let queue = DispatchQueue(label: "carwithin.browser")
    private var listener: NWListener?
    private var mjpegStreams: [ObjectIdentifier: NWConnection] = [:]
    private var webSocketStreams: [ObjectIdentifier: NWConnection] = [:]
    private var audioStreams: [ObjectIdentifier: NWConnection] = [:]
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
                self?.onState?("浏览器配置：\(CarPlayConfiguration.performanceMode.rawValue) / \(CarPlayConfiguration.themeName) / \(CarPlayConfiguration.aspectRatioText)")
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

        let effectiveFPS: Int
        let target = CarPlayConfiguration.performanceMode.targetFPS
        effectiveFPS = target > 0 ? min(fps, target) : fps
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, effectiveFPS)))
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
        audioStreams.values.forEach { $0.cancel() }
        audioStreams.removeAll()
        onState?("浏览器输出已停止")
    }

    // MARK: - 帧

    private func renderFrame() {
        // 每个渲染周期把攒着的 NAL 送出去，避免只有关键帧才 flush 导致不出画面。
        flushAccessUnit()
        if latestJPEG != nil {
            pushFrame()
            return
        }
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
                .font: UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let text = "等待 CarPlay 画面\n\n\(CarPlayConfiguration.vehicleName) · \(CarPlayConfiguration.codecName) · \(CarPlayConfiguration.displayWidth)×\(CarPlayConfiguration.displayHeight)"
            text.draw(in: CGRect(x: 0, y: size.height / 2 - 90, width: size.width, height: 180),
                      withAttributes: attributes)
        }
        latestJPEG = image.jpegData(compressionQuality: CGFloat(CarPlayConfiguration.performanceMode.jpegQuality))
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

    /// 把单个 NAL 装配成访问单元，推给 WebSocket（AVCC 长度前缀）。
    private func appendAccessUnit(_ nal: Data, keyframe: Bool) {
        if hasPendingUnit && keyframe {
            flushAccessUnit()
        }
        // 低延迟档：积压超限直接丢弃，避免越播越延迟。
        if hasPendingUnit,
           CarPlayConfiguration.performanceMode == .lowLatency,
           pendingUnit.count > 1 << 20 {
            pendingUnit.removeAll(keepingCapacity: true)
            hasPendingUnit = false
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
        guard hasPendingUnit, !pendingUnit.isEmpty else { return }
        defer {
            pendingUnit.removeAll(keepingCapacity: true)
            hasPendingUnit = false
        }
        guard !webSocketStreams.isEmpty else { return }
        let packet = Self.webSocketFrame(pendingUnit)
        for connection in webSocketStreams.values {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// Wi-Fi 伴音：把 AudioSink 解码出的 Float32 交错 PCM 推给浏览器。
    func broadcastAudio(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, !self.audioStreams.isEmpty, !pcm.isEmpty else { return }
            let packet = Self.webSocketFrame(pcm)
            for connection in self.audioStreams.values {
                connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    /// 服务端 WebSocket 二进制帧（不带 mask，服务端帧不允许设置 mask 位）。
    private static func webSocketFrame(_ payload: Data) -> Data {
        var header = Data([0x82]) // FIN + binary
        let size = payload.count
        if size < 126 {
            header.append(UInt8(size))
        } else if size < 65536 {
            header.append(126)
            var big = UInt16(size).bigEndian
            header.append(withUnsafeBytes(of: &big) { Data($0) })
        } else {
            header.append(127)
            var big = UInt64(size).bigEndian
            header.append(withUnsafeBytes(of: &big) { Data($0) })
        }
        var packet = header
        packet.append(payload)
        return packet
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
                self.startWebSocket(connection, key: key, streams: .video)
            } else if request.contains("GET /audio"),
                      let key = Self.webSocketKey(from: request) {
                self.startWebSocket(connection, key: key, streams: .audio)
            } else if request.contains("GET /stutter") {
                SessionWatchdog.shared.reportStutter()
                self.respondText(connection, body: "ok", type: "text/plain")
            } else if request.contains("GET /config") {
                self.respondText(connection,
                                 body: CarPlayConfiguration.summary().joined(separator: "\n"),
                                 type: "text/plain; charset=utf-8")
            } else {
                self.respondIndex(connection)
            }
        }
    }

    private enum StreamKind { case video, audio }

    private func startWebSocket(_ connection: NWConnection, key: String, streams: StreamKind) {
        let identifier = ObjectIdentifier(connection)
        switch streams {
        case .video: webSocketStreams[identifier] = connection
        case .audio: audioStreams[identifier] = connection
        }
        let accept = Self.webSocketAccept(key)
        let header = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.async {
                    switch streams {
                    case .video: self?.webSocketStreams.removeValue(forKey: identifier)
                    case .audio: self?.audioStreams.removeValue(forKey: identifier)
                    }
                }
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

    private func respondText(_ connection: NWConnection, body: String, type: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
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
        let codec = CarPlayConfiguration.webCodecsString
        let bootstrap = CarPlayConfiguration.browserBootstrap
        let html = """
        <!doctype html><html lang="zh-CN" data-theme="\(CarPlayConfiguration.themeName)" data-hud="\(CarPlayConfiguration.hudSide)">
        <head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>CarWithin</title>
        <style>
        :root{--bg:#0b0f16;--fg:#e6edf7;--panel:rgba(18,24,36,.82);--line:rgba(255,255,255,.12);
              --icon:calc(42px * \(CarPlayConfiguration.iconScale));--btn:calc(40px * \(CarPlayConfiguration.iconScale))}
        html[data-theme=light]{--bg:#eef2f8;--fg:#16202e;--panel:rgba(255,255,255,.88);--line:rgba(0,0,0,.1)}
        *{box-sizing:border-box}
        html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--fg);
                  font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        main{position:relative;width:100%;height:100%;display:flex;align-items:center;justify-content:center}
        #view,#fallback{display:block;max-width:100%;max-height:100%;object-fit:contain;background:#000}
        #fallback{display:none}
        #hud{position:absolute;top:12px;left:12px;right:12px;display:flex;gap:8px;align-items:flex-start;
             pointer-events:none;z-index:5}
        html[data-hud=right] #hud{flex-direction:row-reverse}
        .spacer{flex:1}
        .hudbox{display:flex;gap:8px;align-items:center;pointer-events:auto}
        button,.chip{border:1px solid var(--line);border-radius:13px;padding:9px 13px;
                     background:var(--panel);color:var(--fg);font:inherit;font-size:14px;
                     backdrop-filter:blur(16px);cursor:pointer;white-space:nowrap}
        #vehicleBtn{display:flex;gap:8px;align-items:center;min-height:var(--btn)}
        #vehicleBtn svg{width:var(--icon);height:var(--icon)}
        #vehicleBtn[hidden]{display:none}
        #stats{position:absolute;bottom:12px;left:12px;padding:8px 12px;border-radius:11px;
               background:var(--panel);font:12px ui-monospace,monospace;white-space:pre;z-index:5}
        #status{position:absolute;bottom:12px;left:50%;transform:translateX(-50%);
                padding:8px 14px;border-radius:11px;background:var(--panel);opacity:.92;z-index:5}
        .tp{position:fixed;width:26px;height:26px;border-radius:50%;
            background:rgba(0,170,255,.55);border:2px solid #fff;pointer-events:none;
            transform:translate(-50%,-50%);z-index:99;box-shadow:0 0 12px #0af}
        </style></head>
        <body><main>
        <canvas id="view" width="\(width)" height="\(height)"></canvas>
        <img id="fallback" src="/stream" alt="CarPlay 画面">
        <div id="hud">
          <div class="hudbox">
            <button id="vehicleBtn" title="车辆">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                <path d="M3 13l2-5h14l2 5v5h-2v-2H5v2H3z"/><circle cx="7" cy="16" r="1"/>
                <circle cx="17" cy="16" r="1"/></svg>
              <span id="vehicleName"></span>
            </button>
          </div>
          <div class="spacer"></div>
          <div class="hudbox">
            <button id="enableAudio" hidden>开启声音</button>
            <button id="statsButton">统计</button>
            <button id="full">全屏</button>
          </div>
        </div>
        <div id="stats" hidden>等待数据…</div>
        <div id="status" >正在连接…</div>
        </main>
        <script>
        const CFG=\(bootstrap);
        const codec="\(codec)";
        const canvas=document.getElementById('view');
        const ctx=canvas.getContext('2d');
        const fallback=document.getElementById('fallback');
        const status=document.getElementById('status');
        const stats=document.getElementById('stats');
        let decoder=null,ws=null,audioWs=null,audioCtx=null;
        let keyframeReady=false,frames=0,shownFps=0,lastStat=performance.now();
        let lastFrameAt=performance.now(),hadFrame=false,lastStutter=0;

        function applyAspect(){
          let w=CFG.width,h=CFG.height;
          if(CFG.followReceiver){
            const r=CFG.aspectValue;
            w=Math.min(window.innerWidth,Math.round(window.innerHeight*r));
            h=Math.round(w/r);
          }else{
            h=Math.round(w/CFG.aspectValue);
          }
          canvas.width=w;canvas.height=h;
          canvas.style.width=w+'px';canvas.style.height=h+'px';
          fallback.style.width=w+'px';fallback.style.height=h+'px';
        }
        applyAspect();
        window.addEventListener('resize',applyAspect);

        document.documentElement.dataset.theme=CFG.theme;
        document.documentElement.dataset.hud=CFG.hudSide;
        const vehicleBtn=document.getElementById('vehicleBtn');
        vehicleBtn.hidden=!CFG.showVehicleButton;
        document.getElementById('vehicleName').textContent=CFG.vehicleName;
        vehicleBtn.onclick=()=>{status.textContent='车辆：'+CFG.vehicleName+' · '+CFG.codec+' · '+CFG.aspect;};

        document.getElementById('full').onclick=()=>{
          if(!document.fullscreenElement){document.documentElement.requestFullscreen&&document.documentElement.requestFullscreen();}
          else{document.exitFullscreen&&document.exitFullscreen();}
        };
        document.getElementById('statsButton').onclick=()=>{stats.hidden=!stats.hidden;};

        function draw(frame){
          ctx.drawImage(frame,0,0,canvas.width,canvas.height);
          frame.close();
          frames++;hadFrame=true;lastFrameAt=performance.now();
          if(!CFG.useWebCodecs&&CFG.maxQueue>1){/* MJPEG 由 <img> 自行刷新 */}
        }

        function initDecoder(){
          if(!CFG.useWebCodecs||typeof VideoDecoder==='undefined'){
            canvas.style.display='none';fallback.style.display='block';
            status.textContent='兼容模式：MJPEG 画面';return;
          }
          try{
            decoder=new VideoDecoder({output:draw,error:(e)=>{status.textContent='解码错误：'+e.message;}});
            decoder.configure({codec:codec,optimizeForLatency:true});
            status.textContent='WebCodecs 就绪（'+CFG.codec+'），等待视频…';
          }catch(e){
            canvas.style.display='none';fallback.style.display='block';
            status.textContent='兼容模式：MJPEG 画面';
          }
        }

        function connectVideo(){
          ws=new WebSocket('ws://'+location.host+'/ws');
          ws.binaryType='arraybuffer';
          ws.onopen=()=>{status.textContent='已连接，等待 '+CFG.codec+' 关键帧…';};
          ws.onmessage=(event)=>{
            const data=new Uint8Array(event.data);
            if(data.length<5||!decoder)return;
            const isKey=(data[4]&0x1F)===5||((data[4]>>1)&0x3F)===19||((data[4]>>1)&0x3F)===20;
            if(!keyframeReady){if(!isKey)return;keyframeReady=true;status.textContent='正在播放 '+CFG.codec;}
            try{
              if(decoder.decodeQueueSize>CFG.maxQueue)return;
              decoder.decode(new EncodedVideoChunk({type:isKey?'key':'delta',
                timestamp:performance.now()*1000,data:data}));
            }catch(e){status.textContent='解码失败：'+e.message;}
          };
          ws.onclose=()=>{keyframeReady=false;status.textContent='连接断开，3 秒后重连…';setTimeout(connectVideo,3000);};
          ws.onerror=()=>{};
        }

        function connectAudio(){
          if(!CFG.audioOverWiFi)return;
          const button=document.getElementById('enableAudio');
          button.hidden=false;
          button.onclick=async()=>{
            audioCtx=new (window.AudioContext||window.webkitAudioContext)({sampleRate:44100});
            await audioCtx.resume();button.hidden=true;
          };
          audioWs=new WebSocket('ws://'+location.host+'/audio');
          audioWs.binaryType='arraybuffer';
          audioWs.onmessage=(event)=>{
            if(!audioCtx||audioCtx.state!=='running')return;
            const floats=new Float32Array(event.data);
            const frames=floats.length/2;
            if(frames<1)return;
            const buffer=audioCtx.createBuffer(2,frames,44100);
            const left=buffer.getChannelData(0),right=buffer.getChannelData(1);
            for(let i=0;i<frames;i++){left[i]=floats[i*2];right[i]=floats[i*2+1];}
            const source=audioCtx.createBufferSource();
            source.buffer=buffer;source.connect(audioCtx.destination);source.start();
          };
          audioWs.onclose=()=>{setTimeout(connectAudio,3000);};
        }

        if(CFG.showTouches){
          const dots=new Map();
          const dotFor=(id)=>{
            if(!dots.has(id)){const d=document.createElement('div');d.className='tp';document.body.appendChild(d);dots.set(id,d);}
            return dots.get(id);
          };
          const move=(e)=>{const d=dotFor(e.pointerId);d.style.left=e.clientX+'px';d.style.top=e.clientY+'px';};
          window.addEventListener('pointerdown',move,{passive:true});
          window.addEventListener('pointermove',(e)=>{if(dots.has(e.pointerId))move(e);},{passive:true});
          const end=(e)=>{const d=dots.get(e.pointerId);if(d){d.remove();dots.delete(e.pointerId);}};
          window.addEventListener('pointerup',end,{passive:true});
          window.addEventListener('pointercancel',end,{passive:true});
        }

        setInterval(()=>{
          const now=performance.now();
          shownFps=Math.round(frames*1000/(now-lastStat));frames=0;lastStat=now;
          stats.textContent='帧率 '+shownFps+' FPS · '+CFG.codec+' · '+CFG.perfMode
            +' · '+canvas.width+'x'+canvas.height+' · '+CFG.aspect+'\\n'
            +'外观 '+(CFG.theme==='dark'?'深色':'浅色')+' · 夜间模式 '+CFG.nightMode
            +' · 驾驶位 '+(CFG.hudSide==='right'?'右舵':'左舵')+'\\n'
            +'车辆 '+CFG.vehicleName+' · 图标 x'+CFG.iconScale+' · 触摸点 '+(CFG.showTouches?'开':'关');
          if(hadFrame&&now-lastFrameAt>2000&&now-lastStutter>10000){
            lastStutter=now;fetch('/stutter');
          }
        },1000);

        initDecoder();
        connectVideo();
        connectAudio();
        </script>
        </body></html>
        """
        respondText(connection, body: html, type: "text/html; charset=utf-8")
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
