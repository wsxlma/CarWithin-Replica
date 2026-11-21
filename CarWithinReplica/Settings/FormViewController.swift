import UIKit

/// 通用表单页：标签 + 输入框，失焦或回车时提交。
final class FormViewController: UITableViewController {
    struct Field {
        let title: String
        let placeholder: String
        let value: () -> String
        let onCommit: (String) -> Void
        var keyboard: UIKeyboardType = .default
        var secure: Bool = false
    }

    private let fields: [Field]
    private let footer: String?
    private var activeField: UITextField?

    init(title: String, fields: [Field], footer: String? = nil) {
        self.fields = fields
        self.footer = footer
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
        tableView.keyboardDismissMode = .interactive
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitActiveField()
    }

    private func commitActiveField() {
        guard let field = activeField else { return }
        commit(field)
    }

    private func commit(_ textField: UITextField) {
        guard let index = fields.firstIndex(where: { $0.title == textField.accessibilityLabel }) else { return }
        fields[index].onCommit(textField.text ?? "")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        fields.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        footer
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fields[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)

        var content = cell.defaultContentConfiguration()
        content.text = field.title
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let input = UITextField()
        input.text = field.value()
        input.placeholder = field.placeholder
        input.textAlignment = .right
        input.keyboardType = field.keyboard
        input.isSecureTextEntry = field.secure
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.returnKeyType = .done
        input.accessibilityLabel = field.title
        input.frame = CGRect(x: 0, y: 0, width: 190, height: 34)
        input.addTarget(self, action: #selector(editingChanged(_:)), for: .editingChanged)
        input.addTarget(self, action: #selector(editingEnded(_:)), for: .editingDidEndOnExit)
        input.addTarget(self, action: #selector(beganEditing(_:)), for: .editingDidBegin)
        cell.accessoryView = input

        return cell
    }

    @objc private func beganEditing(_ sender: UITextField) {
        activeField = sender
    }

    @objc private func editingChanged(_ sender: UITextField) {
        commit(sender)
    }

    @objc private func editingEnded(_ sender: UITextField) {
        commit(sender)
        sender.resignFirstResponder()
        activeField = nil
    }
}
