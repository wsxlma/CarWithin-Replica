import UIKit

/// 与原版 `TDSCarKit.SettingsPageController` 对齐：一个 `UITableViewController`，
/// 分组内容由 `build` 闭包提供，`reload()` 时重建。
class SettingsPageController: UITableViewController {
    private var sections: [SettingsSection] = []

    /// 子类在 `super.init` 之后赋值（闭包需要引用 self）。
    var buildSections: (() -> [SettingsSection])?

    var onAppear: (() -> Void)?
    var onLeave: (() -> Void)?

    init(title: String, build: (() -> [SettingsSection])? = nil) {
        self.buildSections = build
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        onAppear?()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onLeave?()
    }

    func reload() {
        sections = buildSections?() ?? []
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    // MARK: - 数据源

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.detail
        content.image = row.icon
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        if row.destructive {
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content

        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch row.kind {
        case .page, .external, .action:
            cell.accessoryType = .disclosureIndicator
        case .control(let control):
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .field(let field):
            cell.accessoryView = field
            field.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
            cell.selectionStyle = .none
        case .info:
            cell.selectionStyle = .none
        case .note(let label):
            cell.accessoryView = label
            cell.selectionStyle = .none
        case .custom(let view):
            cell.accessoryView = view
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = sections[indexPath.section].rows[indexPath.row]
        tableView.deselectRow(at: indexPath, animated: true)

        switch row.kind {
        case .page(let make):
            navigationController?.pushViewController(make(), animated: true)
        case .external(let url):
            UIApplication.shared.open(url)
        case .action(let handler):
            handler()
        case .control, .field, .info, .note, .custom:
            break
        }
    }
}
