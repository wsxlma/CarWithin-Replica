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

    /// 日志同时落盘到 Documents，闪退后还能捞回来。
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carwithin-log.txt")
    }

    enum Level: String {
        case verbose, error
    }

    /// 所有写入都串到主线程：@Published 被多线程同时改会触发
    /// Combine 的锁竞争直接崩溃（真机崩溃栈：ObservableObjectPublisher.send → EXC_CRASH）。
    func append(_ message: String, level: Level = .verbose) {
        let setting = SettingsStore.logLevel
        if setting == "无" { return }
        if setting == "错误", level != .error { return }
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)"
        if Thread.isMainThread {
            commit(line)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.commit(line)
            }
        }
    }

    private func commit(_ line: String) {
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        persist(line)
    }

    /// 追加写入文件（每次 open/write/close，避免闪退丢缓冲）。
    private func persist(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 会话启动时调用：切掉过大的旧日志，保留最近 256KB。
    func rotateIfNeeded() {
        let url = fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > 262_144,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = content.suffix(200_000)
        try? ("…日志已轮转…\n" + tail).write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        lines.removeAll()
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}
