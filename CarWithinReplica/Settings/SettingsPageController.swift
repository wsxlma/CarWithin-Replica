import UIKit

final class SettingsCell: UITableViewCell {
    static let reuseID = "SettingsCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevronView = UIImageView()
    private let toggle = UISwitch()
    private var toggleHandler: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemGroupedBackground
        selectionStyle = .default

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 16)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronView.image = UIImage(systemName: "chevron.right")
        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .scaleAspectFit
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        toggle.addTarget(self, action: #selector(toggled), for: .valueChanged)

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(chevronView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 29),
            iconView.heightAnchor.constraint(equalToConstant: 29),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            chevronView.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 6),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        toggleHandler = nil
        accessoryView = nil
    }

    func configure(with row: SettingsRow) {
        titleLabel.text = row.title
        iconView.image = SettingsIcon.tile(row.symbol, tint: row.tint)
        detailLabel.text = row.resolvedDetail

        toggleHandler = nil
        accessoryView = nil
        chevronView.isHidden = true
        chevronView.image = UIImage(systemName: "chevron.right")
        detailLabel.isHidden = false
        accessoryType = .none
        selectionStyle = row.handler == nil ? .none : .default

        switch row.accessory {
        case .chevron:
            chevronView.isHidden = false
        case .upDown:
            chevronView.image = UIImage(systemName: "chevron.up.chevron.down")
            chevronView.isHidden = false
        case .toggle(let isOn, let handler):
            toggle.isOn = isOn
            toggleHandler = handler
            accessoryView = toggle
            detailLabel.isHidden = true
        case .none:
            detailLabel.isHidden = (row.resolvedDetail == nil)
        }
    }

    @objc private func toggled() {
        toggleHandler?(toggle.isOn)
    }
}

/// 与原版 `TDSCarKit.SettingsPageController` 对齐：`UITableViewController` + `build` 闭包。
class SettingsPageController: UITableViewController {
    private var sections: [SettingsSection] = []

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
        tableView.register(SettingsCell.self, forCellReuseIdentifier: SettingsCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50
        tableView.backgroundColor = .systemGroupedBackground
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        onAppear?()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        CarPlayConfiguration.applyAppearance()
        onLeave?()
    }

    func reload() {
        sections = buildSections?() ?? []
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    /// 供子类构造「点击后 push」的行。
    func pushRow(_ title: String,
                 symbol: String,
                 tint: UIColor,
                 detail: (() -> String?)? = nil,
                 accessory: SettingsRow.Accessory = .chevron,
                 make: @escaping () -> UIViewController) -> SettingsRow {
        SettingsRow(title, symbol: symbol, tint: tint, detail: detail, accessory: accessory) { [weak self] in
            self?.navigationController?.pushViewController(make(), animated: true)
        }
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
        let cell = tableView.dequeueReusableCell(withIdentifier: SettingsCell.reuseID, for: indexPath)
        if let cell = cell as? SettingsCell {
            cell.configure(with: sections[indexPath.section].rows[indexPath.row])
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        sections[indexPath.section].rows[indexPath.row].handler?()
    }
}
