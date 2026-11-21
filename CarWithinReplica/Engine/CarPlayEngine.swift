import SwiftUI

enum EngineState: String, Equatable {
    case idle
    case connecting
    case running
    case failed

    var title: String {
        switch self {
        case .idle: return "未启动"
        case .connecting: return "正在连接 CarPlay"
        case .running: return "正在投屏"
        case .failed: return "启动失败"
        }
    }

    var detail: String {
        switch self {
        case .idle: return "选择输出方式后启动会话"
        case .connecting: return "等待本机接收端就绪"
        case .running: return "画面与触控已接管"
        case .failed: return "检查签名权限与输出设置"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "car"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .running: return "car.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .connecting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
}

struct ReceiverConfiguration: Equatable {
    var host: String
    var port: UInt16
    var width: Int
    var height: Int
    var fps: Int

    static let placeholder = ReceiverConfiguration(
        host: "192.168.1.1", port: 9888, width: 1024, height: 600, fps: 25)
}

enum EngineError: LocalizedError {
    case notImplemented
    case transportRefused

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "CarPlay 核心通道尚未接入"
        case .transportRefused:
            return "私有配件传输被系统拒绝"
        }
    }
}

/// CarPlay 会话的抽象。真实实现需要：
///   1. 通过 CoreAccessories 私有接口建立虚拟配件传输；
///   2. 完成 iAP2 认证与 CarPlay 会话协商；
///   3. 取出 H.264 画面与音频，并把触控回传。
///
/// 这三步都依赖二进制里的 `ACCTransportClient`，且需要对应签名权限，
/// 因此当前只提供协议与占位实现。
protocol CarPlayEngine: AnyObject {
    var state: EngineState { get }
    func start(configuration: ReceiverConfiguration) async throws
    func stop()
}
