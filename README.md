# CarWithin Replica

> 逐模块完成度对照见 [docs/PARITY.md](docs/PARITY.md)。

按原版结构复刻的 CarWithin，**设置页只保留「诊断与实验」**。
仓库自带 GitHub Actions，推上去即可产出未签名 IPA。

> 状态：设置页与 App 外壳已按符号表还原；CarPlay 核心通道尚未接入（原因见下）。
> 这不是一个"能投屏"的成品，是一个**可继续施工的 1:1 骨架**。

## 设置页的改动（本次需求）

原版「支持」分组有五项：

| 入口 | 处理 |
| --- | --- |
| 支持页 | ❌ 删除 |
| 关注作者 | ❌ 删除 |
| 请我喝杯咖啡 | ❌ 删除 |
| **诊断与实验** | ✅ **唯一保留** |
| 关于 | ❌ 删除 |

实现落在 `ReceiverViewController.aboutLinks()`：只返回一项，其余不构造，
所以界面上不存在，也没有"隐藏但仍可触发"的路径。

**「支持」以上所有分组保持完整**：

| 分组 | 内容 |
| --- | --- |
| 通用 | 使用说明、Wi-Fi 与网络（SSID/密码）、Wi-Fi 预设（增删与切换）、当前输出（6 种）、输出设置（地址/端口）、HTTPS 设置（端口/域名方案） |
| 画面 | 跟随车机、固定分辨率、帧率、编码（H.264/H.265）、屏幕适配（完整/裁满/拉伸） |
| CarPlay | 外观（自动/浅色/深色）、右舵驾驶位、声音输出（iPhone/随画面） |
| 后台与画中画 | 画中画时机、锁定时允许 CarPlay |
| 实验 | 同机 CarPlay 探测 |
| 浏览器输出 | HTTP 与 HTTPS、证书配置 |
| **支持** | **仅「诊断与实验」** |

## 为什么是 UIKit

反查符号表发现原版设置页不是 SwiftUI：

```
_TtC9TDSCarKit22SettingsPageController   ← UITableViewController 子类
_TtC9TDSCarKit11SettingsRow
_TtC9TDSCarKit15SettingsSection
_TtC9TDSCarKit12SettingsIcon
```

所以复刻也用 `UITableViewController` + `SettingsSection` / `SettingsRow` 数据驱动，
与 `SettingsPageController(title:build:)` 的构造方式一致。详见
[docs/REVERSED_API.md](docs/REVERSED_API.md)。

## 构建现状（已验证）

仓库已推到 <https://github.com/wsxlma/CarWithin-Replica>，CI 跑通：

| 项 | 结果 |
| --- | --- |
| Runner | `macos-15`（`macos-14` 已退役，任务会被直接取消，无日志） |
| 编译 | 成功，产物 `CarWithin.app`，arm64，最低 iOS 16.0 |
| 包名 | `local.carwithin.replica`，显示名 `CarWithin` |
| Release | `v0.1.0` 已附未签名 IPA 与 `SHA256SUMS` |

文案核对说明：`请我喝杯咖啡`（18 字节）在产物二进制里确认不存在；
但 `诊断与实验`、`使用说明` 这类 **≤15 字节**的中文串会被 Swift 小字符串优化
内联进指令，静态扫描查不到，只能以源码为准。

## 用 GitHub Actions 出包

推上 GitHub 后：

1. **每次 push / PR**：跑一次构建，产物在 Actions 的 Artifacts 里
   （`CarWithinReplica-unsigned-ipa`，含 `SHA256SUMS`）
2. **打 tag**：`git tag v0.1.0 && git push origin v0.1.0`
   → 自动创建 Release 并附上 IPA

工作流用的是 `macos-15` + `xcodegen` + `xcodebuild`，关键开关：

```
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

产物是**未签名 IPA**，装法与原版一致：用 Sideloadly / AltStore 等工具
拿自己的证书重签后安装。

> Bundle ID 默认 `local.carwithin.replica`。若要覆盖安装原版需改成原版 ID，
> 但两者的签名与数据不通用，不建议混装。

## 本地构建（需要 macOS）

```bash
brew install xcodegen
xcodegen generate
open CarWithinReplica.xcodeproj
```

Windows 上无法编译 iOS 工程，这是硬约束。

## 目录

```
project.yml                      XcodeGen 工程定义
.github/workflows/build.yml      macOS 构建 → 未签名 IPA → Artifact / Release
CarWithinReplica/
  App/                           入口、TabView、首页
  Engine/                        CarPlayEngine 协议 + 占位实现
  Settings/
    SettingsPageController.swift 与原版同构的 UITableView 容器
    SettingsRow.swift            行模型与工厂方法
    SettingsSection.swift        分组模型 + 图标缓存
    ReceiverViewController.swift 设置页内容（aboutLinks 只留诊断与实验）
    DiagnosticsViewController.swift 诊断与实验页
    DiagnosticsLog.swift         日志
tools/extract_manifest.py        Mach-O 符号/中文串清单（REA 的替代品）
docs/REVERSED_API.md             符号表还原出的接口
```

## 还没做的部分（诚实清单）

| 模块 | 状态 | 卡在哪 |
| --- | --- | --- |
| 设置页 / 导航 / 日志 | ✅ 已复刻 | — |
| GitHub Actions 出包 | ✅ 已配置 | 未在真 runner 上跑过 |
| CarPlay 会话 | ❌ 未实现 | 需要 `ACCTransportClient` 私有接口 |
| 视频编码 / 浏览器输出 | ❌ 未实现 | 依赖上一条 |
| 九号 / 台铃输出 | ❌ 未实现 | 可参考 [SevenInchDash](https://github.com/) 的七寸实现 |

二进制里自己写着：

```
CoreAccessories refused the connection.
This signed app may lack access to the private transport.
```

也就是说这条通道**受签名权限约束**。即使把代码 1:1 写对，自签包也可能被系统拒绝。
这一点必须在真机上先验证，否则后面的工作量可能白费。

## 关于 REA

本机 REA 没有可用后端：Ghidra 未配置、Hopper 不支持 Windows、IDA/Kuna 未配置，
且 Windows 版 Ghidra 不接受 Mach-O arm64。等后端就绪后：

```bash
python tools/extract_manifest.py path/to/TDSCarKit -o analysis/manifest.json
```

先用它做基线，再用 REA 反编译对照，避免"凭感觉复刻"。

## 许可

原版 CarWithin 为 GPL-3.0-or-later，本复刻沿用同一许可。
与 Ninebot / Segway / Apple 均无关联，仅供协议与界面研究。
