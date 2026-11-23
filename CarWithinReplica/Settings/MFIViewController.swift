import UIKit
import UniformTypeIdentifiers

/// MFi 身份材料管理页。
///
/// 证书与私钥**不随仓库、不随安装包分发**，必须由使用者自己导入到
/// 应用 Documents 目录。这一页负责：显示当前状态、给出导入指引、
/// 允许从「文件」App 直接选取文件、以及在导入后重新载入。
final class MFIViewController: UIViewController {

    private let statusLabel = UILabel()
    private let detailView = UITextView()
    /// 最近一次载入的结果，避免每次刷新都重复读盘。
    private var lastLog: [String] = []

    private static let requiredFiles = ["private.x963", "leaf.cer", "certificate.p7b"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MFi 材料"
        view.backgroundColor = .systemGroupedBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // 状态卡
        let statusCard = UIView()
        statusCard.backgroundColor = .secondarySystemGroupedBackground
        statusCard.layer.cornerRadius = 12

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -16),
        ])
        stack.addArrangedSubview(statusCard)

        // 操作按钮
        let pickButton = makeButton("从「文件」选择材料…", symbol: "square.and.arrow.down",
                                    action: #selector(pickFiles))
        let reloadButton = makeButton("重新载入", symbol: "arrow.clockwise",
                                      action: #selector(reloadIdentity))
        let buttons = UIStackView(arrangedSubviews: [pickButton, reloadButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)

        // 详情
        detailView.isEditable = false
        detailView.alwaysBounceVertical = false
        detailView.backgroundColor = .secondarySystemGroupedBackground
        detailView.layer.cornerRadius = 12
        detailView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        detailView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailView.textColor = .label
        detailView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(detailView)
        detailView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
        ])

        reload(force: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(force: true)
    }

    // MARK: - 状态

    /// 重新读盘并刷新界面。`force` 为 false 时只重绘、不重复读文件。
    private func reload(force: Bool) {
        let identity = AccessoryIdentity.shared
        if force || lastLog.isEmpty {
            lastLog = identity.load()
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        var lines: [String] = []
        lines.append("Documents 目录：")
        lines.append(documents?.path ?? "不可用")
        lines.append("")
        lines.append("材料检查：")
        for name in Self.requiredFiles {
            let found = locateInDocuments(name) != nil
            lines.append("  \(found ? "✓" : "✗")  \(name)")
        }

        if identity.isReady {
            statusLabel.text = "状态：就绪（\(identity.identifier)）"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.text = "状态：未就绪 —— 缺少 MFi 材料，CarPlay 认证无法完成"
            statusLabel.textColor = .systemRed
        }

        lines.append("")
        lines.append("载入详情：")
        lines.append(contentsOf: lastLog.isEmpty
                     ? AccessoryIdentity.importHint.components(separatedBy: "\n")
                     : lastLog)

        detailView.text = lines.joined(separator: "\n")
    }

    private func locateInDocuments(_ name: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        for root in [documents, documents.appendingPathComponent("MFI", isDirectory: true)] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - 操作

    @objc private func pickFiles() {
        // 允许选任意类型：x963/cer/p7b 都没有系统 UTType，用 data 兜底。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item],
                                                   asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func reloadIdentity() {
        let steps = AccessoryIdentity.shared.load()
        reload(force: true)
        let ready = AccessoryIdentity.shared.isReady
        let alert = UIAlertController(
            title: ready ? "MFi 材料已就绪" : "仍未就绪",
            message: steps.suffix(6).joined(separator: "\n"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 8
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemBlue
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.perform(action)
        })
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return button
    }
}

// MARK: - 导入

extension MFIViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let mfiDir = documents.appendingPathComponent("MFI", isDirectory: true)
        try? FileManager.default.createDirectory(at: mfiDir, withIntermediateDirectories: true)

        var moved: [String] = []
        var failed: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            // Documents 根目录与 MFI 子目录都写一份，两种放法都能被 locate 命中。
            for target in [documents.appendingPathComponent(name), mfiDir.appendingPathComponent(name)] {
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                } catch {
                    failed.append("\(name)：\(error.localizedDescription)")
                }
            }
            moved.append(name)
        }

        let steps = AccessoryIdentity.shared.load()
        reload(force: true)

        var message = "已导入：\n" + moved.joined(separator: "\n")
        if !failed.isEmpty {
            message += "\n\n失败：\n" + failed.joined(separator: "\n")
        }
        message += "\n\n载入结果：\n" + steps.suffix(5).joined(separator: "\n")
        let alert = UIAlertController(
            title: AccessoryIdentity.shared.isReady ? "材料已就绪" : "导入完成，但未就绪",
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}