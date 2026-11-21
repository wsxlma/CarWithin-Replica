import UIKit

struct SettingsSection {
    let header: String?
    let footer: String?
    let rows: [SettingsRow]

    init(header: String? = nil, footer: String? = nil, rows: [SettingsRow]) {
        self.header = header
        self.footer = footer
        self.rows = rows
    }

    /// 与原版 `SettingsSection(footer:_:)` 对齐。
    init(footer: String?, _ rows: [SettingsRow]) {
        self.init(header: nil, footer: footer, rows: rows)
    }

    init(_ rows: [SettingsRow]) {
        self.init(header: nil, footer: nil, rows: rows)
    }
}

enum SettingsIcon {
    private static var cache: [String: UIImage] = [:]

    /// 原版签名是 `SettingsIcon.image(_ symbol: String, color: UIColor)`。
    static func image(_ symbol: String, color: UIColor) -> UIImage? {
        let key = "\(symbol)|\(color.description)"
        if let cached = cache[key] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        guard let base = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        cache[key] = base
        return base
    }
}
