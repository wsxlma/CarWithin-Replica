import UIKit

/// 一行设置项。图标是「圆角色块 + 白色 SF Symbol」，与原版一致。
struct SettingsRow {
    enum Accessory {
        case none
        case chevron
        case upDown                       // 右侧上下箭头，表示可切换的枚举
        case toggle(Bool, (Bool) -> Void)
    }

    let title: String
    let detail: (() -> String?)?
    let symbol: String
    let tint: UIColor
    let accessory: Accessory
    let handler: (() -> Void)?

    init(_ title: String,
         symbol: String,
         tint: UIColor,
         detail: (() -> String?)? = nil,
         accessory: Accessory = .chevron,
         handler: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
        self.accessory = accessory
        self.handler = handler
    }

    var resolvedDetail: String? {
        detail?()
    }
}

struct SettingsSection {
    let header: String?
    let footer: String?
    let rows: [SettingsRow]

    init(_ header: String?, footer: String? = nil, rows: [SettingsRow]) {
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

/// 原版图标是彩色圆角方块。这里统一渲染，避免每行单独处理。
enum SettingsIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(_ symbol: String, tint: UIColor) -> UIImage? {
        UIImage(systemName: symbol)
    }

    static func tile(_ symbol: String, tint: UIColor, size: CGFloat = 29) -> UIImage? {
        let key = "\(symbol)|\(tint.description)|\(size)"
        if let cached = cache[key] { return cached }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        let image = renderer.image { context in
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.24)
            tint.setFill()
            path.fill()

            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let glyphSize = glyph.size
            let origin = CGPoint(x: (size - glyphSize.width) / 2,
                                 y: (size - glyphSize.height) / 2)
            glyph.draw(at: origin)
            _ = context
        }
        cache[key] = image
        return image
    }
}
