import Foundation
import Network
import CryptoKit
import ObjectiveC

/// CoreAccessories 桥。只做「能不能用」和「有哪些方法」的探测，
/// 具体调用序列由我们自己的会话层决定。
enum ACCBridge {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories"

    static var isAvailable: Bool {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return NSClassFromString("ACCTransportClient") != nil
    }

    /// 把 ACCTransportClient 的方法名全部导出，便于按真机结果补齐调用。
    static func selectorDump() -> String {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return "CoreAccessories 加载失败：\(dlerror().map { String(cString: $0) } ?? "未知")"
        }
        defer { dlclose(handle) }

        guard let cls = NSClassFromString("ACCTransportClient") else {
            return "未找到 ACCTransportClient"
        }

        var names: [String] = []
        var count: UInt32 = 0
        if let methods = class_copyMethodList(cls, &count) {
            for index in 0..<Int(count) {
                names.append(NSStringFromSelector(method_getName(methods[index])))
            }
            free(UnsafeMutableRawPointer(methods))
        }
        if let meta = object_getClass(cls), let methods = class_copyMethodList(meta, &count) {
            for index in 0..<Int(count) {
                names.append("+" + NSStringFromSelector(method_getName(methods[index])))
            }
            free(UnsafeMutableRawPointer(methods))
        }
        return names.isEmpty ? "ACCTransportClient 无可见方法" : names.sorted().joined(separator: "\n")
    }
}

/// 本机配件身份。用 P-256 自签，不依赖 MFi 协处理器。
struct AccessoryIdentity {
    let privateKey: P256.Signing.PrivateKey
    let name: String
    let model: String
    let manufacturer: String

    var publicKeyData: Data { privateKey.publicKey.x963Representation }

    static func load() -> AccessoryIdentity {
        let defaults = UserDefaults.standard
        let key = "carplay.identity.private"
        let privateKey: P256.Signing.PrivateKey
        if let raw = defaults.data(forKey: key),
           let restored = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            privateKey = restored
        } else {
            let created = P256.Signing.PrivateKey()
            defaults.set(created.rawRepresentation, forKey: key)
            privateKey = created
        }
        return AccessoryIdentity(privateKey: privateKey,
                                 name: "CarWithin",
                                 model: "CarWithin-Replica",
                                 manufacturer: "CarWithin")
    }

    func sign(_ challenge: Data) -> Data? {
        try? privateKey.signature(for: challenge).derRepresentation
    }
}

/// 触控槽位，最多 10 点。
struct TouchHID {
    struct Contact {
        var id: UInt8
        var x: UInt16
        var y: UInt16
        var down: Bool
    }

    private(set) var contacts: [UInt8: Contact] = [:]

    mutating func update(id: UInt8, x: UInt16, y: UInt16, down: Bool) {
        if down {
            contacts[id] = Contact(id: id, x: x, y: y, down: true)
        } else {
            contacts.removeValue(forKey: id)
        }
    }

    /// 我们的触控载荷格式：count(1) + [id(1) x(2) y(2) state(1)]*count
    func payload() -> Data {
        var data = Data([UInt8(contacts.count)])
        for contact in contacts.values {
            data.append(contact.id)
            data.append(UInt8((contact.x >> 8) & 0xFF))
            data.append(UInt8(contact.x & 0xFF))
            data.append(UInt8((contact.y >> 8) & 0xFF))
            data.append(UInt8(contact.y & 0xFF))
            data.append(contact.down ? 1 : 0)
        }
        return data
    }
}

/// 我们自己的 CarPlay 配件侧会话。
///
/// 设计：本机开两个 TCP 端口（控制 52700 / 数据 52701），对端连上后按
/// `presence → accessoryInfo → startSession → 鉴权 → 屏幕/触控` 的顺序走。
/// 这是自建协议，不逐字复刻原版；真机若要求不同字段，按日志调整即可。
final class CarPlaySession {
    enum State: String {
        case idle, listening, handshaking, authenticated, running, failed
    }

    private(set) var state: State = .idle {
        didSet { onLog?("状态：\(state.rawValue)") }
    }

    var onLog: ((String) -> Void)?
    var onVideo: ((Data, Bool) -> Void)?
    var onTouchRequest: (() -> Data)?

    private let queue = DispatchQueue(label: "carwithin.carplay")
    private let identity = AccessoryIdentity.load()
    private var controlListener: NWListener?
    private var dataListener: NWListener?
    private var controlConnections: [ObjectIdentifier: NWConnection] = [:]
    private var parsers: [ObjectIdentifier: IAP2Parser] = [:]
    private var sequence: UInt8 = 0
    private var touch = TouchHID()
    private var startAttempts = 0

    let controlPort: UInt16
    let dataPort: UInt16

    init(controlPort: UInt16 = 52700, dataPort: UInt16 = 52701) {
        self.controlPort = controlPort
        self.dataPort = dataPort
    }

    // MARK: - 生命周期

    func start() {
        guard controlListener == nil else {
            onLog?("会话已在监听，跳过重复启动")
            return
        }
        onLog?("CoreAccessories：\(ACCBridge.isAvailable ? "可用" : "不可用（仍尝试自建通道）")")
        if !ACCBridge.isAvailable {
            onLog?(ACCBridge.selectorDump())
        }

        do {
            controlListener = try makeListener(port: controlPort)
            dataListener = try makeListener(port: dataPort)
        } catch {
            startAttempts += 1
            if startAttempts <= 3 {
                onLog?("端口占用，0.8 秒后重试（第 \(startAttempts) 次）")
                queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.start() }
            } else {
                state = .failed
                onLog?("监听失败：\(error.localizedDescription)")
            }
            return
        }
        startAttempts = 0
        state = .listening
        onLog?("等待连接：控制 \(controlPort) / 数据 \(dataPort)")
    }

    func stop() {
        controlListener?.cancel(); controlListener = nil
        dataListener?.cancel(); dataListener = nil
        controlConnections.values.forEach { $0.cancel() }
        controlConnections.removeAll()
        parsers.removeAll()
        state = .idle
    }

    private func makeListener(port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters,
                                      on: NWEndpoint.Port(rawValue: port) ?? 52700)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onLog?("端口 \(port) 失败：\(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
        return listener
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        controlConnections[id] = connection
        parsers[id] = IAP2Parser()
        connection.start(queue: queue)
        onLog?("对端接入：\(String(describing: connection.endpoint))")
        send(.presence, on: connection)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            if let data, !data.isEmpty, var parser = self.parsers[id] {
                parser.append(data)
                while let packet = parser.next() {
                    self.handle(packet, on: connection)
                }
                self.parsers[id] = parser
            }
            if done || error != nil {
                self.controlConnections.removeValue(forKey: id)
                self.parsers.removeValue(forKey: id)
                return
            }
            self.receive(on: connection)
        }
    }

    // MARK: - 协议

    private func send(_ packet: IAP2Packet, on connection: NWConnection) {
        connection.send(content: packet.encoded(), completion: .contentProcessed { _ in })
    }

    private func nextSequence() -> UInt8 {
        sequence = sequence &+ 1
        return sequence
    }

    private func handle(_ packet: IAP2Packet, on connection: NWConnection) {
        if packet.control == 0xFF {
            state = .handshaking
            onLog?("收到 presence，回送配件信息")
            let info = IAP2Message(id: IAP2MessageID.accessoryInfo, parameters: [
                IAP2Parameter(id: 0, value: Data(identity.name.utf8) + Data([0])),
                IAP2Parameter(id: 1, value: Data(identity.model.utf8) + Data([0])),
                IAP2Parameter(id: 2, value: Data(identity.manufacturer.utf8) + Data([0])),
                IAP2Parameter(id: 3, value: identity.publicKeyData),
            ])
            send(IAP2Packet(control: 0x02, session: 0,
                            sequence: nextSequence(), acknowledgement: packet.sequence,
                            payload: info.encoded()), on: connection)
            return
        }

        guard let message = IAP2Message.decode(packet.payload) else {
            onLog?("收到未知包 control=0x\(String(packet.control, radix: 16)) len=\(packet.payload.count)")
            return
        }

        switch message.id {
        case IAP2MessageID.requestAuthentication:
            let challenge = message.parameters.first?.value ?? Data()
            let signature = identity.sign(challenge) ?? Data()
            let response = IAP2Message(id: IAP2MessageID.requestAuthenticationSignature,
                                       parameters: [IAP2Parameter(id: 0, value: signature)])
            send(IAP2Packet(control: 0x02, session: packet.session,
                            sequence: nextSequence(), acknowledgement: packet.sequence,
                            payload: response.encoded()), on: connection)
            onLog?("已回签鉴权挑战（\(challenge.count) 字节）")

        case IAP2MessageID.startSession:
            state = .authenticated
            let ack = IAP2Message(id: IAP2MessageID.authStatus, parameters: [
                IAP2Parameter(id: 0, value: Data([0x00])),
            ])
            send(IAP2Packet(control: 0x02, session: packet.session,
                            sequence: nextSequence(), acknowledgement: packet.sequence,
                            payload: ack.encoded()), on: connection)
            state = .running
            onLog?("会话已建立（session=\(packet.session)）")

        case IAP2MessageID.stopSession:
            state = .authenticated
            onLog?("对端结束会话")

        case IAP2MessageID.requestAuthenticationCert:
            let cert = IAP2Message(id: IAP2MessageID.requestAuthenticationCert,
                                   parameters: [IAP2Parameter(id: 0, value: identity.publicKeyData)])
            send(IAP2Packet(control: 0x02, session: packet.session,
                            sequence: nextSequence(), acknowledgement: packet.sequence,
                            payload: cert.encoded()), on: connection)

        default:
            // 屏幕数据：以 Annex-B 起始码判定
            let payload = packet.payload
            if let range = payload.range(of: Data([0, 0, 0, 1])) {
                let frame = payload[range.lowerBound...]
                let key = frame.count > 4 && (frame[frame.startIndex + 4] & 0x1F) == 5
                onVideo?(Data(frame), key)
            } else {
                onLog?("消息 0x\(String(message.id, radix: 16)) 未处理，\(payload.count) 字节")
            }
        }
    }

    // MARK: - 触控

    func sendTouch(id: UInt8, x: UInt16, y: UInt16, down: Bool) {
        touch.update(id: id, x: x, y: y, down: down)
        guard let connection = controlConnections.values.first else { return }
        let message = IAP2Message(id: 0xE100, parameters: [
            IAP2Parameter(id: 0, value: touch.payload()),
        ])
        send(IAP2Packet(control: 0x02, session: 0,
                        sequence: nextSequence(), acknowledgement: 0,
                        payload: message.encoded()), on: connection)
    }
}
