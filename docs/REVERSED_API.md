# 从符号表还原的接口清单

> 来源：`TDSCarKit` Mach-O 的 `LC_SYMTAB`（22,214 个符号，其中 136 个 Swift 类型属于 TDSCarKit）。
> 这是**符号级证据**，不是反编译结果。方法体仍需 REA 接上 Ghidra/Hopper 后确认。

## 设置页是 UIKit，不是 SwiftUI

| 类型 | 角色 |
| --- | --- |
| `SettingsPageController` | `UITableViewController` 子类，设置页容器 |
| `SettingsSection` | 分组模型（header / footer / rows） |
| `SettingsRow` | 行模型 + 一组工厂方法 |
| `SettingsIcon` | 把 SF Symbol 渲染成带色 `UIImage`，带缓存 |

SwiftUI 只用于 `ReleaseNotesView` / `ReleaseDownloadView` 之类的叶子页面，
设置页本身是数据驱动的 UITableView。

## SettingsPageController

从 mangled name 还原：

```swift
init(title: String, build: @escaping () -> [SettingsSection])

func reload()
var onAppear: (() -> Void)?
var onLeave: (() -> Void)?

// UITableView 数据源/代理
override func numberOfSections(in: UITableView) -> Int
override func tableView(_:numberOfRowsInSection:) -> Int
override func tableView(_:cellForRowAt:) -> UITableViewCell
override func tableView(_:didSelectRowAt:)
override func tableView(_:titleForHeaderInSection:) -> String?
override func tableView(_:titleForFooterInSection:) -> String?
override func tableView(_:trailingSwipeActionsConfigurationForRowAt:) -> UISwipeActionsConfiguration?

// 内部
private var sections: [SettingsSection]
private var cells: [IndexPath: UITableViewCell]
private var build: () -> [SettingsSection]
private func containsEditingField(_ view: UIView) -> Bool
```

`cells` 字典说明它**自己缓存 cell 实例**（输入框行需要保留编辑状态），
复刻时不能只依赖 `dequeueReusableCell`。

## SettingsRow

工厂方法（原签名）：

```swift
static func page(_ title: String, icon: String, detail: (() -> String?)?,
                 _ make: () -> UIViewController) -> SettingsRow
static func externalLink(_ title: String, icon: String, detail: (() -> String?)?,
                         _ open: () -> Void) -> SettingsRow
static func action(_ title: String, icon: String, destructive: Bool,
                   detail: (() -> String?)?, _ handler: () -> Void) -> SettingsRow
static func control(_ title: String, icon: String, _ control: UIView) -> SettingsRow
static func field(_ title: String, placeholder: String?) -> SettingsRow
static func info(_ text: String) -> SettingsRow
static func note(_ label: UILabel) -> SettingsRow
static func view(_ view: UIView) -> SettingsRow
static func guide(_ title: String, icon: String,
                  _ body: @escaping () -> String) -> SettingsRow

enum Kind { ... }
```

`detail` 是闭包而不是字符串，说明副标题会跟着状态变化（例如当前 Wi-Fi、当前输出）。
复刻时如果写成常量字符串，界面会"看起来对但不会更新"。

## ReceiverViewController

```swift
private func aboutLinks() -> [SettingsRow]                 // 支持入口组
private func experimentSections() -> [SettingsSection]     // 实验组
private func browserOutputSections() -> [SettingsSection]  // 浏览器输出组
```

需求要求的改动就落在 `aboutLinks()`：原版返回五项，这里只返回一项。

## 支持入口的原始构成

README 与界面文案可对应到五个入口：

| 入口 | 原版行为 |
| --- | --- |
| 支持页 | 打开说明/FAQ 页面 |
| 关注作者 | 跳转抖音链接 |
| 请我喝杯咖啡 | 跳转支付宝收款码 |
| 诊断与实验 | 打开日志页（本次保留） |
| 关于 | 版本、检查更新、版本记录 |

二进制里能直接找到的旁证：

- `请我喝杯咖啡` —— 中文串表第 143 条附近
- `ReleaseDetailView` / `ReleaseDownloadView` / `ReleaseHistoryView` / `AppReleaseService`
  —— 说明「关于」是一个带更新下载的完整模块，不是一行链接
- `_OBJC_CLASS_$__TtC9TDSCarKit22SettingsPageController`

## 还缺什么

1. **方法体**：`aboutLinks()` 里五项的确切顺序与文案，需要反编译确认。
2. **`SettingsRow.Kind` 的完整分支**：目前从工厂方法反推，缺 `case` 名。
3. **权限路径**：`ACCTransportClient` 的调用点与所需 entitlement。
