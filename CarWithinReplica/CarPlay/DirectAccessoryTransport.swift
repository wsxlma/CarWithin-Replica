import Foundation

/// 直连配件传输 —— 逐行照原版 `DirectAccessoryTransport`（ObjC）反编译重写
/// （`analysis/acc.c`，地址 0x100004000 起）。
///
/// 原版真实行为（与之前手写的版本差异极大）：
/// 1. `transportType` **只接受 2 或 8**，其余直接报错。
/// 2. `createConnectionWithType:andIdentifier:` 的 identifier 传的是 **self（transport 对象）**，
///    不是配件名字符串；先试 type=2，失败回退 type=1。
/// 3. `createEndpoint...` 的 `protocol` 恒为 **4**，`identifier` 恒为 **nil**，
///    `publishConnection` 恒为 **YES**，transportType 用入参。
/// 4. dataOutHandler 是三参数 block `(NSString, NSString, NSData)`；
///    数据长度 > 0x10000 直接丢弃；拷贝后派发到 **主队列**，
///    并用 `generation`（NSUUID）校验，避免旧连接的回调串进来。
/// 5. `sendData:error:` 走 `processIncomingData:forEndpointWithUUID:`。
/// 6. `stop` 先清 generation，再 destroy endpoint / connection（都带 HasMethod 检查）。
final class DirectAccessoryTransport: NSObject {
    static let shared = DirectAccessoryTransport()

    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var client: AnyObject?
    private(set) var connection: String?
    private(set) var endpoint: String?
    private(set) var generation: UUID?

    private override init() { super.init() }

    var isOpen: Bool { endpoint != nil }

    // MARK: - 启动

    @discardableResult
    func start(identifier: String, transportType: Int = 2) -> Bool {
        stop()

        guard transportType == 2 || transportType == 8 else {
            onLog?("[直连] transportType=\(transportType) 不被原版接受（只允许 2 或 8）")
            return false
        }

        guard let client = ACCBridge.sharedTransportClient() else {
            onLog?("[直连] ACCTransportClient 不可用（CoreAccessories 未加载或系统不支持）")
            return false
        }
        self.client = client

        let requiredMethods: [(String, Int)] = [
            ("createConnectionWithType:andIdentifier:", 2),
            ("createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:", 6),
            ("processIncomingData:forEndpointWithUUID:", 2),
            ("destroyEndpointWithUUID:", 1),
            ("destroyConnectionWithUUID:", 1)
        ]
        for (name, count) in requiredMethods {
            guard ACCBridge.hasMethod(client, name, argumentCount: count) else {
                onLog?("[直连] ACC 缺少方法 \(name)（或参数个数不是 \(count)）")
                stop()
                return false
            }
        }
        onLog?("[直连] ACC 五个 transport 方法齐备")

        // 原版：identifier 传 self，不是配件名。
        var connection = ACCBridge.createConnection(client, type: 2, identifier: self)
        if let value = connection {
            onLog?("[直连] createConnection(type=2) → \(value)")
        } else {
            onLog?("[直连] createConnection(type=2) 返回 nil，回退 type=1")
            connection = ACCBridge.createConnection(client, type: 1, identifier: self)
            if let value = connection {
                onLog?("[直连] createConnection(type=1) → \(value)")
            }
        }

        guard let connectionUUID = connection else {
            onLog?("[直连] CoreAccessories 拒绝建立连接（此签名 App 可能缺少私有 transport 权限）")
            stop()
            return false
        }
        self.connection = connectionUUID
        let currentGeneration = UUID()
        generation = currentGeneration
        onLog?("[直连] connection=\(connectionUUID) generation=\(currentGeneration.uuidString.prefix(8))")

        // dataOutHandler：三参数，长度上限 0x10000，拷贝后回主队列，校验 generation。
        let handler: @convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void = {
            [weak self] _, _, payload in
            guard let self else { return }
            guard let data = payload as? NSData else {
                self.onLog?("[直连] dataOutHandler 第三参数不是 NSData（实际 \(type(of: payload as Any))）")
                return
            }
            guard data.length <= 0x10000 else {
                self.onLog?("[直连] 丢弃超长数据 \(data.length)B（上限 65536）")
                return
            }
            let copy = Data(referencing: data)
            DispatchQueue.main.async {
                guard self.generation == currentGeneration else {
                    self.onLog?("[直连] 丢弃旧 generation 的回调 \(copy.count)B")
                    return
                }
                self.onData?(copy)
            }
        }

        guard let endpointUUID = ACCBridge.createEndpoint(client,
                                                          transportType: transportType,
                                                          protocolType: 4,
                                                          identifier: nil,
                                                          dataOutHandler: handler,
                                                          connectionUUID: connectionUUID,
                                                          publishConnection: true) else {
            onLog?("[直连] CoreAccessories 拒绝发布 iAP2 端点（type=\(transportType) protocol=4 publish=YES）")
            stop()
            return false
        }
        self.endpoint = endpointUUID
        onLog?("[直连] endpoint=\(endpointUUID)（type=\(transportType) protocol=4 publish=YES）")
        onLog?("[直连] 直连配件通道已建立，等待 iOS 侧 iAP2 交互")
        return true
    }

    // MARK: - 发送

    @discardableResult
    func sendData(_ data: Data) -> Bool {
        guard let client, let endpoint else {
            onLog?("[直连] sendData 失败：直连通道未打开")
            return false
        }
        let ok = ACCBridge.processIncomingData(client, data: data, endpointUUID: endpoint)
        onLog?("[直连] → 发送 \(data.count)B（processIncomingData=\(ok)）")
        return ok
    }

    // MARK: - 停止

    func stop() {
        generation = nil
        if let client, let endpoint {
            _ = ACCBridge.destroyEndpoint(client, uuid: endpoint)
        }
        if let client, let connection {
            _ = ACCBridge.destroyConnection(client, uuid: connection)
        }
        endpoint = nil
        connection = nil
        client = nil
    }

    deinit {
        stop()
    }
}

// MARK: - 照原版 `HasMethod` 与各 objc_msgSend 调用的底层封装

extension ACCBridge {
    /// 原版 `HasMethod(target, sel, argCount)`：方法存在且参数个数为 argCount + 2（self、_cmd）。
    static func hasMethod(_ target: AnyObject, _ name: String, argumentCount: Int) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let cls = object_getClass(target),
              let method = class_getInstanceMethod(cls, selector) else {
            return false
        }
        return Int(method_getNumberOfArguments(method)) == argumentCount + 2
    }

    /// `createConnectionWithType:andIdentifier:`，identifier 传对象（原版传 self）。
    static func createConnection(_ client: AnyObject, type: Int, identifier: AnyObject) -> String? {
        let selector = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, Int, AnyObject) -> AnyObject?
        guard let created = unsafeBitCast(imp, to: Fn.self)(client, selector, type, identifier) else {
            return nil
        }
        return created as? String
    }

    /// `createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:`
    static func createEndpoint(_ client: AnyObject,
                               transportType: Int,
                               protocolType: Int,
                               identifier: AnyObject?,
                               dataOutHandler: AnyObject,
                               connectionUUID: String,
                               publishConnection: Bool) -> String? {
        let selector = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, Int, Int, AnyObject?,
                                       AnyObject, AnyObject, Bool) -> AnyObject?
        guard let created = unsafeBitCast(imp, to: Fn.self)(client, selector,
                                                            transportType, protocolType,
                                                            identifier, dataOutHandler,
                                                            connectionUUID as NSString,
                                                            publishConnection) else {
            return nil
        }
        return created as? String
    }

    /// `processIncomingData:forEndpointWithUUID:` —— 配件 → 系统方向。
    static func processIncomingData(_ client: AnyObject, data: Data, endpointUUID: String) -> Bool {
        let selector = NSSelectorFromString("processIncomingData:forEndpointWithUUID:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, selector,
                                              data as NSData, endpointUUID as NSString)
    }

    static func destroyEndpoint(_ client: AnyObject, uuid: String) -> Bool {
        let selector = NSSelectorFromString("destroyEndpointWithUUID:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, selector, uuid as NSString)
    }

    static func destroyConnection(_ client: AnyObject, uuid: String) -> Bool {
        let selector = NSSelectorFromString("destroyConnectionWithUUID:")
        guard let cls = object_getClass(client),
              let imp = class_getMethodImplementation(cls, selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, selector, uuid as NSString)
    }
}
