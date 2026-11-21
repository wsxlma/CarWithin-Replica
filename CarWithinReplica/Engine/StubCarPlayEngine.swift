import Foundation
import Combine

/// 占位实现：保留状态机与调用路径，真正的工作留给 REA 还原后的实现。
final class StubCarPlayEngine: ObservableObject, CarPlayEngine {
    static let unavailableReason = """
    原版通过 CoreAccessories 私有接口建立虚拟配件传输，二进制里对应 ACCTransportClient。\
    该接口受签名权限约束，未接入前无法启动真实会话。
    """

    @Published private(set) var state: EngineState = .idle

    func start(configuration: ReceiverConfiguration) async throws {
        state = .connecting
        try await Task.sleep(nanoseconds: 300_000_000)
        state = .failed
        throw EngineError.notImplemented
    }

    func stop() {
        state = .idle
    }
}
