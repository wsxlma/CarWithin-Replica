import UIKit

/// 与原版 `TDSCarKit.SettingsRow` 同构的行模型。
///
/// 原版通过一组工厂方法构造行（符号表里可见）：
/// `page(_:icon:detail:)`、`externalLink(_:icon:detail:)`、`action(_:icon:destructive:detail:)`、
/// `control(_:icon:)`、`field(_:placeholder:)`、`info(_:)`、`note(_:)`、`view(_:)`、`guide(_:icon:)`。
struct SettingsRow {
    enum Kind {
        case page(() -> UIViewController)
        case external(URL)
        case action(() -> Void)
        case control(UIView)
        case field(UITextField)
        case info
        case note(UILabel)
        case custom(UIView)
    }

    let title: String
    let detail: String?
    let icon: UIImage?
    let destructive: Bool
    let kind: Kind

    private init(title: String, detail: String?, icon: UIImage?,
                 destructive: Bool = false, kind: Kind) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.destructive = destructive
        self.kind = kind
    }

    // MARK: 工厂

    static func page(_ title: String, icon: String? = nil, detail: String? = nil,
                     _ make: @escaping () -> UIViewController) -> SettingsRow {
        SettingsRow(title: title, detail: detail, icon: icon.flatMap(iconImage), kind: .page(make))
    }

    static func externalLink(_ title: String, icon: String? = nil,
                             detail: String? = nil, url: URL) -> SettingsRow {
        SettingsRow(title: title, detail: detail, icon: icon.flatMap(iconImage), kind: .external(url))
    }

    static func action(_ title: String, icon: String? = nil, destructive: Bool = false,
                       detail: String? = nil,
                       _ handler: @escaping () -> Void) -> SettingsRow {
        SettingsRow(title: title, detail: detail, icon: icon.flatMap(iconImage),
                    destructive: destructive, kind: .action(handler))
    }

    static func control(_ title: String, icon: String? = nil,
                        _ control: UIView) -> SettingsRow {
        SettingsRow(title: title, detail: nil, icon: icon.flatMap(iconImage), kind: .control(control))
    }

    static func field(_ title: String, placeholder: String? = nil) -> SettingsRow {
        let field = UITextField()
        field.placeholder = placeholder
        field.textAlignment = .right
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        return SettingsRow(title: title, detail: nil, icon: nil, kind: .field(field))
    }

    static func info(_ text: String) -> SettingsRow {
        SettingsRow(title: text, detail: nil, icon: nil, kind: .info)
    }

    static func note(_ label: UILabel) -> SettingsRow {
        SettingsRow(title: "", detail: nil, icon: nil, kind: .note(label))
    }

    static func view(_ view: UIView) -> SettingsRow {
        SettingsRow(title: "", detail: nil, icon: nil, kind: .custom(view))
    }

    static func guide(_ title: String, icon: String? = nil, text: String) -> SettingsRow {
        page(title, icon: icon) { GuideViewController(title: title, text: text) }
    }

    private static func iconImage(_ name: String) -> UIImage? {
        SettingsIcon.image(name, color: .secondaryLabel)
    }
}

/// 简易说明页，对应原版 guide 型行打开的内容。
final class GuideViewController: UIViewController {
    private let body: String

    init(title: String, text: String) {
        self.body = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.text = body
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }
}
