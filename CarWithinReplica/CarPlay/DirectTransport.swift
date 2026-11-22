import Foundation
import ObjectiveC

/// 原版真正使用的直连通道。
///
/// 证据：`SameDeviceProbe.start` 里调用
/// `[transport startWithIdentifier:identifier transportType:2 error:&err]`，
/// 并通过 `setOnData:` 接收数据。`DirectAccessoryTransport` 不在 App 二进制里，
/// 属于系统私有框架，所以这里运行时查找并调用。
final class DirectTransport {
    static let shared = DirectTransport()

    private var instance: NSObject?
    private var cls: AnyClass?
    var onData: ((Data) -> Void)?
    var onLog: ((String) -> Void)?

    private init() {}

    func start(identifier: String = "CarWithin", transportType: Int32 = 2) -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories",
            RTLD_NOW) else {
            onLog?("CoreAccessories 加载失败")
            return false
        }
        _ = handle

        guard let found = NSClassFromString("DirectAccessoryTransport") else {
            onLog?("未找到 DirectAccessoryTransport")
            return false
        }
        cls = found

        guard let object = (found as? NSObject.Type)?.init() else {
            onLog?("DirectAccessoryTransport 实例化失败")
            return false
        }
        instance = object
        onLog?("DirectAccessoryTransport 已创建")

        installOnData(object)
        return performStart(object, identifier: identifier, transportType: transportType)
    }

    func stop() {
        guard let object = instance else { return }
        let selector = NSSelectorFromString("stop")
        if let method = class_getInstanceMethod(type(of: object), selector) {
            typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(method_getImplementation(method), to: VoidFn.self)(object, selector)
            onLog?("DirectAccessoryTransport 已停止")
        }
        instance = nil
    }

    func send(_ data: Data) {
        guard let object = instance else { return }
        let selector = NSSelectorFromString("writeData:")
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return }
        typealias WriteFn = @convention(c) (AnyObject, Selector, NSData) -> Bool
        let ok = unsafeBitCast(method_getImplementation(method), to: WriteFn.self)(
            object, selector, data as NSData)
        if !ok { onLog?("writeData 返回 false") }
    }

    // MARK: - 私有

    private func installOnData(_ object: NSObject) {
        let selector = NSSelectorFromString("setOnData:")
        guard let method = class_getInstanceMethod(type(of: object), selector) else {
            onLog?("没有 setOnData:")
            return
        }
        typealias SetBlockFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let block: @convention(block) (AnyObject?) -> Void = { [weak self] payload in
            guard let self else { return }
            if let data = payload as? Data {
                self.onData?(data)
            } else if let data = payload as? NSData {
                self.onData?(data as Data)
            }
        }
        unsafeBitCast(method_getImplementation(method), to: SetBlockFn.self)(
            object, selector, block as AnyObject)
        onLog?("setOnData: 已安装")
    }

    private func performStart(_ object: NSObject, identifier: String, transportType: Int32) -> Bool {
        let selector = NSSelectorFromString("startWithIdentifier:transportType:error:")
        guard let method = class_getInstanceMethod(type(of: object), selector) else {
            onLog?("没有 startWithIdentifier:transportType:error:")
            return false
        }
        typealias StartFn = @convention(c) (AnyObject, Selector, NSString, Int32,
                                            UnsafeMutablePointer<NSError?>?) -> Bool
        var error: NSError?
        let ok = unsafeBitCast(method_getImplementation(method), to: StartFn.self)(
            object, selector, identifier as NSString, transportType, &error)
        if ok {
            onLog?("直连已启动（identifier=\(identifier), type=\(transportType)）")
        } else {
            onLog?("直连启动失败：\(error?.localizedDescription ?? "无错误信息")")
        }
        return ok
    }
}
