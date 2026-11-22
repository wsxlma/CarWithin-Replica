import Foundation
import Network
import CryptoKit
import ObjectiveC

/// CoreAccessories 桥。只做「能不能用」和「有哪些方法」的探测，
/// 具体调用序列由我们自己的会话层决定。
enum ACCBridge {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories"
    static var delegateRef: ACCTransportDelegate?
    static let endpointSelector = "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:"

    static var isAvailable: Bool {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return NSClassFromString("ACCTransportClient") != nil
    }

    /// 把方法名和类型编码一起导出。类型编码就是参数表，不需要真的调用。
    static func selectorDump() -> String {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return "CoreAccessories 加载失败：\(dlerror().map { String(cString: $0) } ?? "未知")"
        }
        defer { dlclose(handle) }
        guard let cls = NSClassFromString("ACCTransportClient") else {
            return "未找到 ACCTransportClient"
        }

        var lines: [String] = []
        var count: UInt32 = 0

        if let methods = class_copyMethodList(cls, &count) {
            for index in 0..<Int(count) {
                let method = methods[index]
                let name = NSStringFromSelector(method_getName(method))
                lines.append("- " + name + "  " + signature(of: method))
            }
            free(UnsafeMutableRawPointer(methods))
        }
        if let meta = object_getClass(cls), let methods = class_copyMethodList(meta, &count) {
            for index in 0..<Int(count) {
                let method = methods[index]
                let name = NSStringFromSelector(method_getName(method))
                lines.append("+ " + name + "  " + signature(of: method))
            }
            free(UnsafeMutableRawPointer(methods))
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// 只输出 endpoint 方法的参数表，便于直接照抄调用。
    static func endpointSignature() -> String {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return "CoreAccessories 加载失败" }
        defer { dlclose(handle) }
        guard let cls = NSClassFromString("ACCTransportClient") else { return "未找到 ACCTransportClient" }

        let selector = NSSelectorFromString(endpointSelector)
        var result = "未找到 \(endpointSelector)"

        if let method = class_getInstanceMethod(cls, selector) {
            result = "createEndpoint 参数表：\n" + signature(of: method)
        } else if let meta = object_getClass(cls),
                  let method = class_getInstanceMethod(meta, selector) {
            result = "createEndpoint（类方法）参数表：\n" + signature(of: method)
        }
        return result
    }

    /// 按真实签名建立连接与 endpoint。block 先传 nil，避免未知 block 签名导致崩溃。
    static func connect() -> [String] {
        var steps: [String] = []
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return ["CoreAccessories 加载失败"]
        }
        defer { dlclose(handle) }
        guard let cls = NSClassFromString("ACCTransportClient") else {
            return ["未找到 ACCTransportClient"]
        }
        guard let meta = object_getClass(cls) else { return ["无法取到元类"] }

        let sharedSelector = NSSelectorFromString("sharedClient")
        guard let sharedIMP = class_getMethodImplementation(meta, sharedSelector) else {
            return ["没有 +sharedClient"]
        }
        typealias SharedFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let sharedFn = unsafeBitCast(sharedIMP, to: SharedFn.self)
        guard let client = sharedFn(cls as AnyObject, sharedSelector) else {
            return ["+sharedClient 返回 nil"]
        }
        steps.append("sharedClient → \(type(of: client))")
        steps.append("entitlements：\(entitlementsSummary())")

        let delegate = ACCTransportDelegate()
        delegate.onEvent = { steps.append("回调：" + $0) }
        ACCBridge.delegateRef = delegate
        let setDelegateSelector = NSSelectorFromString("setDelegate:")
        if let imp = class_getMethodImplementation(cls, setDelegateSelector) {
            typealias ObjectFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(imp, to: ObjectFn.self)(client, setDelegateSelector, delegate)
            steps.append("delegate 已设置")
        }
        let setQueueSelector = NSSelectorFromString("setEndpointEventHandlerQueue:")
        if let imp = class_getMethodImplementation(cls, setQueueSelector) {
            typealias ObjectFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(imp, to: ObjectFn.self)(client, setQueueSelector, DispatchQueue.main as AnyObject)
            steps.append("endpointEventHandlerQueue 已设置")
        }

        // launchServer（无参数、无返回）
        let launchSelector = NSSelectorFromString("launchServer")
        if let imp = class_getMethodImplementation(cls, launchSelector) {
            typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(imp, to: VoidFn.self)(client, launchSelector)
            steps.append("launchServer 已调用")
        }

        // launchServer 之后，服务连接可能才是建端点的前提
        let serverSelector = NSSelectorFromString("serverConnection")
        if let imp = class_getMethodImplementation(cls, serverSelector) {
            typealias GetFn = @convention(c) (AnyObject, Selector) -> AnyObject?
            let server = unsafeBitCast(imp, to: GetFn.self)(client, serverSelector)
            steps.append("serverConnection → \(server.map { String(describing: $0) } ?? "nil")")
            if let server {
                let setSelector = NSSelectorFromString("setServerConnection:")
                if let setIMP = class_getMethodImplementation(cls, setSelector) {
                    typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                    unsafeBitCast(setIMP, to: SetFn.self)(client, setSelector, server)
                    steps.append("setServerConnection 已调用")
                }
            }
        }

        // createConnectionWithType:andIdentifier: (i, @)
        let connectionSelector = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        guard let connectionIMP = class_getMethodImplementation(cls, connectionSelector) else {
            return steps + ["没有 createConnection"]
        }
        typealias ConnectionFn = @convention(c) (AnyObject, Selector, Int32, NSString) -> AnyObject?
        let connectionFn = unsafeBitCast(connectionIMP, to: ConnectionFn.self)
        let accessoryID = MFIIdentity.shared.identifier

        var connectionUUID: NSUUID?
        for type in Int32(0)...Int32(8) {
            guard let created = connectionFn(client, connectionSelector, type, accessoryID as NSString) else {
                steps.append("createConnection(type=\(type)) → nil")
                continue
            }
            steps.append("createConnection(type=\(type)) → \(created)")
            if let uuid = created as? NSUUID {
                connectionUUID = uuid
            } else if let text = created as? String, let uuid = UUID(uuidString: text) {
                connectionUUID = uuid as NSUUID
            }
            if connectionUUID != nil { break }
        }

        guard let uuid = connectionUUID else {
            return steps + ["未拿到 connection UUID，停止"]
        }

        // createEndpointWithTransportType:... (i, i, @, @?, @, B)
        let endpointSelector = NSSelectorFromString(endpointSelector)
        guard let endpointIMP = class_getMethodImplementation(cls, endpointSelector) else {
            return steps + ["没有 createEndpoint"]
        }
        typealias EndpointFn = @convention(c) (AnyObject, Selector,
                                               Int32, Int32, NSString,
                                               AnyObject?, NSUUID, Bool) -> AnyObject?
        let endpointFn = unsafeBitCast(endpointIMP, to: EndpointFn.self)

        // 先 publish，很多实现要求连接先发布才允许挂 endpoint。
        let publishSelector = NSSelectorFromString("publishConnectionWithUUID:")
        if let imp = class_getMethodImplementation(cls, publishSelector) {
            typealias PublishFn = @convention(c) (AnyObject, Selector, NSUUID) -> Bool
            let published = unsafeBitCast(imp, to: PublishFn.self)(client, publishSelector, uuid)
            steps.append("publishConnection → \(published)")
        }

        // 看这条连接自己的标识与配件信息，endpoint 的 identifier 可能要跟它一致
        let idSelector = NSSelectorFromString("identifierForConnectionWithUUID:")
        if let imp = class_getMethodImplementation(cls, idSelector) {
            typealias IdFn = @convention(c) (AnyObject, Selector, NSUUID) -> AnyObject?
            let value = unsafeBitCast(imp, to: IdFn.self)(client, idSelector, uuid)
            steps.append("connection identifier → \(value.map { String(describing: $0) } ?? "nil")")
        }
        let infoSelector = NSSelectorFromString("accessoryInfoForConnectionWithUUID:")
        if let imp = class_getMethodImplementation(cls, infoSelector) {
            typealias InfoFn = @convention(c) (AnyObject, Selector, NSUUID) -> AnyObject?
            let value = unsafeBitCast(imp, to: InfoFn.self)(client, infoSelector, uuid)
            steps.append("accessoryInfo → \(value.map { String(describing: $0) } ?? "nil")")
        }

        // 打印连接属性，确认该连接声明支持的 transport 类型
        let propsSelector = NSSelectorFromString("propertiesForConnectionWithUUID:")
        if let imp = class_getMethodImplementation(cls, propsSelector) {
            typealias PropsFn = @convention(c) (AnyObject, Selector, NSUUID) -> AnyObject?
            let props = unsafeBitCast(imp, to: PropsFn.self)(client, propsSelector, uuid)
            steps.append("connection 属性：\(props.map { String(describing: $0) } ?? "nil")")
        }

        // 看看系统是否已经给了 endpoint
        let listSelector = NSSelectorFromString("endpointUUIDsForConnectionWithUUID:")
        if let imp = class_getMethodImplementation(cls, listSelector) {
            typealias ListFn = @convention(c) (AnyObject, Selector, NSUUID) -> AnyObject?
            let endpoints = unsafeBitCast(imp, to: ListFn.self)(client, listSelector, uuid)
            steps.append("endpoints → \(endpoints.map { String(describing: $0) } ?? "nil")")
        }

        // 只试一次：transport=1, protocol=4, publish=false（block 仍为 nil）
        let attempt = endpointFn(client, endpointSelector, 1, 4,
                                 accessoryID as NSString, nil, uuid, false)
        steps.append("createEndpoint(transport=1, protocol=4, publish=false) → \(attempt.map { String(describing: $0) } ?? "nil")")

        return steps
    }

    /// 验证 B：给 dataOutHandler 传真实 block，再试建 endpoint。
    /// 这一步可能因 block 签名不符而崩溃，所以单独成一个开关。
    static func createEndpointWithBlock() -> [String] {
        var steps: [String] = []
        guard let handle = dlopen(frameworkPath, RTLD_NOW),
              let cls = NSClassFromString("ACCTransportClient"),
              let meta = object_getClass(cls) else {
            return ["CoreAccessories 不可用"]
        }
        defer { dlclose(handle) }

        let sharedSelector = NSSelectorFromString("sharedClient")
        guard let sharedIMP = class_getMethodImplementation(meta, sharedSelector) else {
            return ["没有 +sharedClient"]
        }
        typealias SharedFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        guard let client = unsafeBitCast(sharedIMP, to: SharedFn.self)(cls as AnyObject, sharedSelector) else {
            return ["sharedClient 返回 nil"]
        }

        let connectionSelector = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        guard let connectionIMP = class_getMethodImplementation(cls, connectionSelector) else {
            return steps + ["没有 createConnection"]
        }
        typealias ConnectionFn = @convention(c) (AnyObject, Selector, Int32, NSString) -> AnyObject?
        guard let created = unsafeBitCast(connectionIMP, to: ConnectionFn.self)(
            client, connectionSelector, 0, "CarWithin" as NSString) else {
            return steps + ["createConnection 返回 nil"]
        }
        let uuid: NSUUID
        if let value = created as? NSUUID {
            uuid = value
        } else if let text = created as? String, let parsed = UUID(uuidString: text) {
            uuid = parsed as NSUUID
        } else {
            return steps + ["createConnection 返回值不是 UUID：\(created)"]
        }
        steps.append("connection → \(uuid)")

        // 真实 block：收到 endpoint 数据时写日志
        let handler: @convention(block) (AnyObject?) -> Void = { payload in
            let count = (payload as? NSData)?.length ?? 0
            DiagnosticsLog.shared.append("[ACC] endpoint 收到 \(count)B")
        }

        let endpointSelector = NSSelectorFromString(endpointSelector)
        guard let endpointIMP = class_getMethodImplementation(cls, endpointSelector) else {
            return steps + ["没有 createEndpoint"]
        }
        typealias EndpointFn = @convention(c) (AnyObject, Selector, Int32, Int32,
                                               NSString, AnyObject?, NSUUID, Bool) -> AnyObject?
        let endpointFn = unsafeBitCast(endpointIMP, to: EndpointFn.self)

        for transport in Int32(1)...Int32(3) {
            for proto in Int32(0)...Int32(5) {
                let result = endpointFn(client, endpointSelector, transport, proto,
                                        MFIIdentity.shared.identifier as NSString, handler as AnyObject, uuid, true)
                if let result {
                    steps.append("createEndpoint(transport=\(transport), protocol=\(proto), identifier=UUID) → \(result)")
                    return steps
                }
            }
        }
        steps.append("createEndpoint 全组 nil（identifier 用 connection UUID）")
        return steps
    }

    /// 从 embedded.mobileprovision 读取 entitlements 键名。
    static func entitlementsSummary() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return "无 embedded.mobileprovision（TrollStore / 越狱安装）"
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            return "描述文件里找不到 plist"
        }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return "未解析出 Entitlements"
        }
        return entitlements.keys.sorted().joined(separator: ", ")
    }

    // MARK: - DirectAccessoryTransport 用的封装（照原版接口）

    private static func accClass() -> AnyClass? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil else { return nil }
        return NSClassFromString("ACCTransportClient")
    }

    static func sharedTransportClient() -> AnyObject? {
        guard let cls = accClass(), let meta = object_getClass(cls) else { return nil }
        let sel = NSSelectorFromString("sharedClient")
        guard let imp = class_getMethodImplementation(meta, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(cls as AnyObject, sel)
    }

    static func createConnection(type: Int32, identifier: String) -> String? {
        guard let cls = accClass(), let client = sharedTransportClient() else { return nil }
        let sel = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, Int32, NSString) -> AnyObject?
        guard let created = unsafeBitCast(imp, to: Fn.self)(
            client, sel, type, identifier as NSString) else { return nil }
        return (created as? String) ?? (created as? NSString).map { $0 as String }
    }

    /// 建配件端点。dataOutHandler 用单参数 block（与原版 onData: void(^)(NSData*) 一致）。
    static func createEndpoint(transportType: Int32,
                               protocolType: Int32,
                               identifier: String,
                               connectionUUID: String,
                               publishConnection: Bool,
                               onData: @escaping (Data) -> Void) -> String? {
        guard let cls = accClass(), let client = sharedTransportClient() else { return nil }
        let sel = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return nil }

        typealias Fn = @convention(c) (AnyObject, Selector, Int32, Int32, NSString,
                                       AnyObject, NSString, Bool) -> AnyObject?
        // dataOutHandler 的真实签名是 (endpointUUID, data) 双参数。
        // 单参数声明会把 UUID 字符串当数据，as? Data 失败后静默丢弃（onData 永远不触发）。
        let handler: @convention(block) (AnyObject, AnyObject, AnyObject) -> Void = { endpoint, payload, extra in
            if let data = extra as? Data {
                onData(data)
            } else if let nsdata = extra as? NSData {
                onData(Data(referencing: nsdata))
            } else if let data = payload as? Data {
                onData(data)
            } else if let nsdata = payload as? NSData {
                onData(Data(referencing: nsdata))
            }
        }
        guard let created = unsafeBitCast(imp, to: Fn.self)(
            client, sel, transportType, protocolType,
            identifier as NSString, handler as AnyObject,
            connectionUUID as NSString, publishConnection) else {
            return nil
        }
        return (created as? String) ?? (created as? NSString).map { $0 as String }
    }

    static func publishConnection(uuid: String) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("publishConnectionWithUUID:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, sel, uuid as NSString)
    }

    /// 告诉 ACC 这条连接的认证状态（原版有 authenticated 状态跟踪，我们一直没调）。
    static func setConnectionAuthenticated(uuid: String, state: Bool) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("setConnectionAuthenticated:state:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, uuid as NSString, state)
        return true
    }

    /// 单独注册端点的数据回调（ACC 的字典属性，可能才是 onData 的真正入口）。
    static func setEndpointDataOutHandlers(_ handlers: [String: Any]) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("setEndpointDataOutHandlers:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, handlers as NSDictionary)
        return true
    }

    /// 数据方向：配件 → 系统。主动发 iAP2 消息给 iOS 用这个。
    static func processIncomingData(_ data: Data, endpointUUID: String) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("processIncomingData:forEndpointWithUUID:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSData, NSString) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, sel, data as NSData, endpointUUID as NSString)
    }

    /// 数据方向：系统 → 配件（原版 onData 收的是这条）。
    static func sendOutgoingData(_ data: Data, endpointUUID: String, connectionUUID: String) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("sendOutgoingData:forEndpointWithUUID:connectionUUID:withReply:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSData, NSString, NSString, AnyObject?) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, data as NSData,
                                       endpointUUID as NSString,
                                       connectionUUID as NSString, nil)
        return true
    }

    static func destroyEndpoint(uuid: String) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("destroyEndpointWithUUID:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, sel, uuid as NSString)
    }

    static func destroyConnection(uuid: String) -> Bool {
        guard let cls = accClass(), let client = sharedTransportClient() else { return false }
        let sel = NSSelectorFromString("destroyConnectionWithUUID:")
        guard let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(client, sel, uuid as NSString)
    }

    private static func signature(of method: Method) -> String {
        guard let encoding = method_getTypeEncoding(method) else { return "（无类型编码）" }
        let raw = String(cString: encoding)
        let tokens = decode(raw)
        return "返回 \(tokens.first ?? "?")  参数 [\(tokens.dropFirst().joined(separator: ", "))]  原始 \(raw)"
    }

    /// 解析 Objective-C 类型编码为可读 token。
    private static func decode(_ encoding: String) -> [String] {
        var tokens: [String] = []
        var index = encoding.startIndex
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V"]

        while index < encoding.endIndex {
            let char = encoding[index]
            if qualifiers.contains(char) || char.isNumber {
                index = encoding.index(after: index)
                continue
            }
            switch char {
            case "@":
                var next = encoding.index(after: index)
                if next < encoding.endIndex, encoding[next] == "?" {
                    tokens.append("@?")
                    index = encoding.index(after: next)
                } else if next < encoding.endIndex, encoding[next] == "\"" {
                    var name = ""
                    next = encoding.index(after: next)
                    while next < encoding.endIndex, encoding[next] != "\"" {
                        name.append(encoding[next])
                        next = encoding.index(after: next)
                    }
                    if next < encoding.endIndex { next = encoding.index(after: next) }
                    tokens.append("@\"\(name)\"")
                    index = next
                } else {
                    tokens.append("@")
                    index = next
                }
            case "^":
                var next = encoding.index(after: index)
                var text = "^"
                if next < encoding.endIndex {
                    text.append(encoding[next])
                    next = encoding.index(after: next)
                }
                tokens.append(text)
                index = next
            case "{", "(":
                let closing: Character = char == "{" ? "}" : ")"
                var next = index
                var text = ""
                while next < encoding.endIndex {
                    text.append(encoding[next])
                    let done = encoding[next] == closing
                    next = encoding.index(after: next)
                    if done { break }
                }
                tokens.append(text)
                index = next
            default:
                tokens.append(String(char))
                index = encoding.index(after: index)
            }
        }
        return tokens
    }
}

/// 本机配件身份。用 P-256 自签，不依赖 MFi 协处理器。
struct PairingIdentity {
    let privateKey: P256.Signing.PrivateKey
    let name: String
    let model: String
    let manufacturer: String

    var publicKeyData: Data { privateKey.publicKey.x963Representation }

    static func load() -> PairingIdentity {
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
        return PairingIdentity(privateKey: privateKey,
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
    private let identity = PairingIdentity.load()
    private let probe = SameDeviceProbe()
    private var controlListener: NWListener?
    private var dataListener: NWListener?
    private var controlConnections: [ObjectIdentifier: NWConnection] = [:]
    private var parsers: [ObjectIdentifier: IAP2Parser] = [:]
    private var sequence: UInt8 = 0
    private var touch = TouchHID()
    private var directParser = IAP2Parser()
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
        if SettingsStore.logLevel == "详细",
           !UserDefaults.standard.bool(forKey: "acc.dump.shown") {
            UserDefaults.standard.set(true, forKey: "acc.dump.shown")
            onLog?(ACCBridge.endpointSignature())
            onLog?("ACCTransportClient 方法列表：\n" + ACCBridge.selectorDump())
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

        MFIIdentity.shared.load().forEach { onLog?("[MFI] " + $0) }
        onLog?("[MFI] 状态：" + (MFIIdentity.shared.isReady ? "就绪" : "未就绪"))
        if let chain = MFIIdentity.shared.certificateChain {
            onLog?("[iAP2] 0xAA01 证书链 \(chain.count)B 已就绪")
        } else {
            onLog?("[iAP2] 0xAA01 证书链缺失（certificate.p7b 未加载，0xAA00 将无法应答）")
        }
        // 用固定 32 字节挑战做一次 RFC4754 签名自检，确认私钥真能用。
        let selfTestChallenge = Data(repeating: 0x5A, count: 32)
        if let signature = try? MFIIdentity.shared.sign(challenge: selfTestChallenge) {
            onLog?("[iAP2] 签名自检通过（RFC4754，\(signature.count)B）")
        } else {
            onLog?("[iAP2] 签名自检失败（私钥不可用）")
        }

        // 自建端点：Bonjour 广播 + RTSP 控制 + 视频通道，等 iOS 的 CarPlay 栈接入。
        // 这条链路不依赖 ACCTransportClient，也不需要配件 entitlement。
        CarPlayConfiguration.applyAppearance()
        onLog?("[配置] 车机参数已加载：")
        CarPlayConfiguration.summary().forEach { onLog?("[配置] " + $0) }
        onLog?("[iAP2] " + IAP2Configuration.summary())

        // 直连配件端：照原版 SameDeviceProbe 编排完整 iAP2 状态机
        // （transport → presence → 0x1D00/0xAA00/0xAA02/0x4300 逐条应答）。
        DiagnosticsLog.shared.rotateIfNeeded()
        probe.onLog = { [weak self] message in self?.onLog?(message) }
        probe.onStage = { [weak self] message in self?.onLog?("[阶段] " + message) }
        probe.onFinished = { [weak self] message in self?.onLog?("[结束] " + message) }
        // 0x4301 里要告诉 iPhone 去哪连 RTSP —— 用 CarPlayReceiver 实际监听的 7000，
        // 不是本类自建控制通道的 52700。
        let host = BrowserOutput.localIPv4() ?? "127.0.0.1"
        probe.sessionEndpoint = (address: host, port: 7000, wifi: nil)
        onLog?("[探测] 会话地址 \(host):7000（RTSP）")
        probe.start(name: CarPlayConfiguration.vehicleName,
                    identity: AccessoryIdentity.shared,
                    transportType: 2)

        CarPlayReceiver.shared.onLog = { [weak self] message in self?.onLog?(message) }
        CarPlayReceiver.shared.start()

        SessionWatchdog.shared.onLog = { [weak self] message in self?.onLog?(message) }
        SessionWatchdog.shared.start()
    }

    func stop() {
        probe.stop()
        SessionWatchdog.shared.stop()
        CarPlayReceiver.shared.stop()
        DirectTransport.shared.stop()
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

    /// 直连通道收到的字节按 iAP2 拆包。
    private func consumeDirect(_ data: Data) {
        directParser.append(data)
        while let packet = directParser.next() {
            onLog?("← 直连 control=0x\(String(packet.control, radix: 16)) \(packet.payload.count)B")
            if packet.control == 0xFF {
                let reply = IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: packet.sequence, session: 0)
                DirectTransport.shared.send(reply.encoded())
                onLog?("→ 直连 presence 应答")
            }
        }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        controlConnections[id] = connection
        parsers[id] = IAP2Parser()
        connection.stateUpdateHandler = { [weak self] state in
            self?.onLog?("连接状态：\(String(describing: state))")
        }
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
        let data = packet.encoded()
        if SettingsStore.logLevel == "详细" {
            onLog?("→ control=0x\(String(packet.control, radix: 16)) session=\(packet.session) seq=\(packet.sequence) ack=\(packet.acknowledgement) \(data.count)B \(Self.hex(data))")
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private static func hex(_ data: Data, limit: Int = 64) -> String {
        data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func nextSequence() -> UInt8 {
        sequence = sequence &+ 1
        return sequence
    }

    private func handle(_ packet: IAP2Packet, on connection: NWConnection) {
        if SettingsStore.logLevel == "详细" {
            onLog?("← control=0x\(String(packet.control, radix: 16)) session=\(packet.session) seq=\(packet.sequence) ack=\(packet.acknowledgement) \(packet.payload.count)B \(Self.hex(packet.payload))")
        }
        if packet.control == 0xFF {
            state = .handshaking
            onLog?("收到 presence，回送配件信息")
            let info = IAP2Message(id: IAP2MessageID.accessoryInfo, parameters: [
                IAP2Parameter(id: 0, value: Data(identity.name.utf8) + Data([0])),
                IAP2Parameter(id: 1, value: Data(identity.model.utf8) + Data([0])),
                IAP2Parameter(id: 2, value: Data(identity.manufacturer.utf8) + Data([0])),
                IAP2Parameter(id: 3, value: identity.publicKeyData),
            ])
            send(IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: packet.sequence, session: 0,
                            payload: info.encoded()), on: connection)
            return
        }

        guard let message = IAP2Message.parse(packet.payload) else {
            onLog?("收到未知包 control=0x\(String(packet.control, radix: 16)) len=\(packet.payload.count)")
            return
        }

        switch message.id {
        case IAP2MessageID.requestAuthentication:
            let challenge = message.parameters.first?.value ?? Data()
            let signature = identity.sign(challenge) ?? Data()
            let response = IAP2Message(id: IAP2MessageID.requestAuthenticationSignature,
                                       parameters: [IAP2Parameter(id: 0, value: signature)])
            send(IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: packet.sequence, session: packet.session,
                            payload: response.encoded()), on: connection)
            onLog?("已回签鉴权挑战（\(challenge.count) 字节）")

        case IAP2MessageID.startSession:
            state = .authenticated
            let ack = IAP2Message(id: IAP2MessageID.authenticationSignature, parameters: [
                IAP2Parameter(id: 0, value: Data([0x00])),
            ])
            send(IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: packet.sequence, session: packet.session,
                            payload: ack.encoded()), on: connection)
            state = .running
            onLog?("会话已建立（session=\(packet.session)）")

        case IAP2MessageID.stopSession:
            state = .authenticated
            onLog?("对端结束会话")

        case IAP2MessageID.authenticationCertificate:
            let cert = IAP2Message(id: IAP2MessageID.authenticationCertificate,
                                   parameters: [IAP2Parameter(id: 0, value: identity.publicKeyData)])
            send(IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: packet.sequence, session: packet.session,
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
        send(IAP2Packet(control: 0x02, sequence: nextSequence(), acknowledgement: 0, session: 0,
                        payload: message.encoded()), on: connection)
    }
}


/// ACCTransportClient 的 delegate 实现。只用于接收回调并写日志。
final class ACCTransportDelegate: NSObject {
    var onEvent: ((String) -> Void)?
    var onSecureData: ((Data) -> Void)?

    @objc func propertiesDidChange(_ properties: NSDictionary?,
                                   forConnectionWithUUID uuid: NSUUID?,
                                   previousProperties: NSDictionary?) {
        onEvent?("connection 属性变化：\(properties?.description ?? "nil")")
    }

    @objc func propertiesDidChange(_ properties: NSDictionary?,
                                   forEndpointWithUUID uuid: NSUUID?,
                                   previousProperties: NSDictionary?,
                                   connectionUUID: NSUUID?) {
        onEvent?("endpoint 属性变化：\(properties?.description ?? "nil")")
    }

    /// 系统把数据送进来的真正入口（此前只挂了 dataOutHandler，那是发送确认回调）。
    @objc func receivedSecureTunnelData(_ data: NSData, forEndpoint endpoint: NSString) {
        let payload = Data(referencing: data)
        onEvent?("收到安全隧道数据 \(payload.count)B endpoint=\(endpoint)")
        onSecureData?(payload)
    }

    @objc func processOutgoingSecureTunnelData(_ data: NSData,
                                               forEndpoint endpoint: NSString,
                                               forType type: UInt8) -> Bool {
        onEvent?("系统请求输出隧道数据 \(data.length)B type=\(type)")
        return true
    }

    @objc func authStateDidChange(_ state: Int32,
                                  forConnectionWithUUID uuid: NSUUID?,
                                  previousAuthState: Int32,
                                  authType: Int32,
                                  connectionIsAuthenticated: Bool,
                                  connectionWasAuthenticated: Bool) {
        onEvent?("鉴权状态：\(state) 类型 \(authType) 已认证 \(connectionIsAuthenticated)")
    }
}
