import UIKit

/// 通用单选页：用于「当前输出」「分辨率」「声音输出」这类枚举项。
final class SelectionViewController: UITableViewController {
    struct Option {
        let id: String
        let title: String
        let subtitle: String?
    }

    private let options: [Option]
    private let currentProvider: () -> String
    private let onSelect: (String) -> Void

    init(title: String,
         options: [Option],
         current: @escaping () -> String,
         onSelect: @escaping (String) -> Void) {
        self.options = options
        self.currentProvider = current
        self.onSelect = onSelect
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
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let option = options[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = option.title
        content.secondaryText = option.subtitle
        cell.contentConfiguration = content
        cell.accessoryType = option.id == currentProvider() ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(options[indexPath.row].id)
        navigationController?.popViewController(animated: true)
    }
}
