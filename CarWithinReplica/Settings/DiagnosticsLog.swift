import Foundation
import Combine

/// 进程内的诊断日志。层级与原版一致：设置 → 支持 → 诊断与实验。
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let limit = 2000

    enum Level: String {
        case verbose, error
    }

    func append(_ message: String, level: Level = .verbose) {
        let setting = SettingsStore.logLevel
        if setting == "无" { return }
        if setting == "错误", level != .error { return }
        let stamp = formatter.string(from: Date())
        lines.append("[\(stamp)] \(message)")
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func clear() {
        lines.removeAll()
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}
