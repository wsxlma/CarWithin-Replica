import UIKit

/// 「诊断与实验」页：展示运行日志，可复制与清空。
final class DiagnosticsViewController: UIViewController {
    private let log = DiagnosticsLog.shared
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "诊断与实验"
        view.backgroundColor = .systemGroupedBackground

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.addSubview(textView)

        let copy = UIButton(type: .system)
        copy.setTitle("复制全部", for: .normal)
        copy.addTarget(self, action: #selector(copyAll), for: .touchUpInside)

        let clear = UIButton(type: .system)
        clear.setTitle("清空", for: .normal)
        clear.setTitleColor(.systemRed, for: .normal)
        clear.addTarget(self, action: #selector(clearAll), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [copy, clear])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 24
        stack.distribution = .fillEqually
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])

        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func refresh() {
        textView.text = log.lines.isEmpty ? "暂无日志。启动会话后会在这里显示。" : log.text
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = log.text
        navigationItem.prompt = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.navigationItem.prompt = nil
        }
    }

    @objc private func clearAll() {
        log.clear()
        refresh()
    }
}
