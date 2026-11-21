import UIKit

/// 把闭包接到 `UISwitch` 上，便于直接放进 `SettingsRow.control`。
final class ClosureSwitch: UISwitch {
    private let handler: (Bool) -> Void

    init(isOn: Bool, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.isOn = isOn
        addTarget(self, action: #selector(toggled), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    @objc private func toggled() {
        handler(isOn)
    }
}

/// Wi-Fi 预设列表：点选切换、左滑删除。
final class WiFiPresetsViewController: UITableViewController {
    private var presets: [String] = []

    init() {
        super.init(style: .insetGrouped)
        title = "Wi-Fi 预设"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addPreset))
        reload()
    }

    private func reload() {
        presets = SettingsStore.presets
        tableView.reloadData()
    }

    @objc private func addPreset() {
        let alert = UIAlertController(title: "添加预设", message: "输入 Wi-Fi 名称", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "SSID"
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            var updated = SettingsStore.presets
            if !updated.contains(name) { updated.append(name) }
            SettingsStore.presets = updated
            SettingsStore.wifiSSID = name
            self.reload()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        presets.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let name = presets[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = name
        cell.contentConfiguration = content
        cell.accessoryType = name == SettingsStore.wifiSSID ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        SettingsStore.wifiSSID = presets[indexPath.row]
        reload()
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self else { return done(false) }
            var updated = SettingsStore.presets
            updated.remove(at: indexPath.row)
            SettingsStore.presets = updated
            self.reload()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
