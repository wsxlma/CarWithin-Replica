import Foundation

/// 直连配件传输：照原版 `DirectAccessoryTransport` 的接口自己实现。
///
/// 原版这个类就在它 App 二进制里（`_OBJC_CLASS_$_DirectAccessoryTransport`
/// 带完整方法/属性表），是对 ACCTransportClient 的封装：
///   client / connection / endpoint / generation
///   - startWithIdentifier:transportType:error:   （原版用 transportType=2）
///   - sendData:error:
///   - stop
///   @property (copy) void (^onData)(NSData *)
///
/// 关键：它不是系统私有框架的类，所以之前 dlopen 查找必然落空。
/// 这里照同样的调用序列自己建端点：createConnection → createEndpoint，
/// 并把 transportType/protocol/publish/identifier 的组合全试一遍，
/// 直到 createEndpoint 返回非 nil——那组参数就是原版用的。
final class DirectAccessoryTransport: NSObject {
    static let shared = DirectAccessoryTransport()

    /// 收到系统送来的数据（对应原版 onData）。
    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var client: AnyObject?
    private(set) var connectionUUID: String?
    private(set) var endpointUUID: String?
    private(set) var generation = 0
    private var started = false
    private var parser = IAP2Parser()

    private override init() { super.init() }

    // MARK: - 对外接口（与原版同名同参）

    @discardableResult
    func start(identifier: String, transportType: Int32 = 2) -> Bool {
        stop()
        generation += 1

        guard let client = ACCBridge.sharedTransportClient() else {
            onLog?("[直连] ACCTransportClient 不可用")
            return false
        }
        self.client = client

        // 1) 建连接（原版日志里 type=0 返回 nil，type=1 成功）
        var connectionUUID: String?
        for type: Int32 in [1, 0, 2] {
            if let uuid = ACCBridge.createConnection(type: type, identifier: identifier) {
                connectionUUID = uuid
                onLog?("[直连] createConnection(type=\(type)) → \(uuid)")
                break
            }
        }
        guard let connectionUUID else {
            onLog?("[直连] createConnection 全部失败")
            return false
        }
        self.connectionUUID = connectionUUID

        // 2) 建端点：把 transportType / protocol / publish / identifier 的组合全试一遍。
        //    原版日志明确写「传输类型 2」，所以 2 排在最前。
        var found: String?
        let transportTypes: [Int32] = [transportType, 2, 1, 0, 3, 4]
        let protocols: [Int32] = Array(0...10) + [4, 16, 17]
        let identifiers = [identifier, connectionUUID]

        outer: for tt in transportTypes {
            for proto in protocols {
                for publish in [false, true] {
                    for ident in identifiers {
                        if let endpoint = ACCBridge.createEndpoint(
                            transportType: tt,
                            protocolType: proto,
                            identifier: ident,
                            connectionUUID: connectionUUID,
                            publishConnection: publish,
                            onData: { [weak self] data in
                                self?.receive(data)
                            }) {
                            endpointUUID = endpoint
                            found = "transport=\(tt) protocol=\(proto) publish=\(publish) identifier=\(ident)"
                            onLog?("[直连] createEndpoint 成功 → \(endpoint)")
                            onLog?("[直连] 参数组合：\(found!)")
                            break outer
                        }
                    }
                }
            }
        }

        guard found != nil else {
            onLog?("[直连] createEndpoint 全部组合均返回 nil（transportType=\(transportType)）")
            return false
        }

        // 3) 发布连接（原版这里也返回 false，但端点已建起来，不阻塞）
        let published = ACCBridge.publishConnection(uuid: connectionUUID)
        onLog?("[直连] publishConnection → \(published)")

        started = true
        onLog?("[直连] 本机配件端点已就绪（identifier=\(identifier), transportType=\(transportType)）")
        return true
    }

    /// 收到系统送来的字节流：切出 iAP2 封包，按认证流程回话。
    private func receive(_ data: Data) {
        onLog?("[直连] ← 收到配件数据 \(data.count)B")
        parser.append(data)
        while let packet = parser.next() {
            onLog?("[直连] iAP2 control=0x\(String(packet.control, radix: 16)) \(packet.payload.count)B")
            onData?(packet.payload)

            if packet.control & 0x02 == 0 {
                var reply = IAP2Packet.presence
                reply.session = packet.session
                send(reply.encoded())
                continue
            }
            guard packet.payload.count >= 2 else { continue }
            let start = packet.payload.startIndex
            let messageID = (UInt16(packet.payload[start]) << 8) | UInt16(packet.payload[start + 1])
            onLog?("[直连] iAP2 消息 0x\(String(messageID, radix: 16))")

            if messageID == IAP2MessageID.startIDPS {
                let ident = AccessoryMessages.identification(
                    name: CarPlayConfiguration.vehicleName,
                    deviceID: AccessoryMessages.deviceID)
                send(encode(ident, packet: packet))
                onLog?("[直连] → 已回送 identification（声明 CarPlay 车机）")
                send(encode(IAP2Configuration.message(), packet: packet))
                onLog?("[直连] → 已回送车机配置 0x1D00")
            } else if messageID == IAP2MessageID.requestAuthenticationCert,
                      let message = IAP2Authentication.certificateMessage() {
                send(encode(message, packet: packet))
                onLog?("[直连] → 已回送 MFi 证书链")
            } else if messageID == IAP2MessageID.requestAuthenticationSignature {
                let challenge = packet.payload.count > 4 ? Data(packet.payload[(start + 4)...]) : Data()
                if let message = IAP2Authentication.responseMessage(challenge: challenge) {
                    send(encode(message, packet: packet))
                    onLog?("[直连] → 已回送 MFi 签名")
                }
            } else if messageID == IAP2MessageID.authStatus {
                let host = BrowserOutput.localIPv4() ?? "127.0.0.1"
                let session = AccessoryMessages.startSession(
                    address: host, port: 7000,
                    deviceID: AccessoryMessages.deviceID, wifi: nil)
                send(encode(session, packet: packet))
                onLog?("[直连] → 已回送 startSession（\(host):7000）")
            }
        }
    }

    private func encode(_ message: IAP2Message, packet: IAP2Packet) -> Data {
        IAP2Packet(control: 0x02, session: packet.session,
                   sequence: packet.sequence,
                   acknowledgement: packet.acknowledgement,
                   payload: message.encoded()).encoded()
    }

    @discardableResult
    func sendData(_ data: Data) -> Bool {
        guard started, let endpointUUID, let connectionUUID else { return false }
        return ACCBridge.sendOutgoingData(data,
                                         endpointUUID: endpointUUID,
                                         connectionUUID: connectionUUID)
    }

    private func send(_ data: Data) {
        guard sendData(data) else {
            onLog?("[直连] 发送失败")
            return
        }
        onLog?("[直连] → 已发送 \(data.count)B")
    }

    func stop() {
        if let endpointUUID {
            _ = ACCBridge.destroyEndpoint(uuid: endpointUUID)
        }
        if let connectionUUID {
            _ = ACCBridge.destroyConnection(uuid: connectionUUID)
        }
        client = nil
        endpointUUID = nil
        connectionUUID = nil
        started = false
    }
}
