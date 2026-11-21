# CarWithin Replica

按原版结构复刻的 CarWithin，加入了实验性的 **九号七寸仪表适配**
进入GitHub Actions，沙箱环境选择macOS即可产出编译后的IPA文件
产物是**未签名 IPA**，用 Sideloadly / AltStore 等工具
使用证书重签后安装。

## 本地构建（mac must）

```bash
brew install xcodegen
xcodegen generate
open CarWithinReplica.xcodeproj
```


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



## 许可
GPL-3.0-or-later
本软体与 Ninebot / Segway / Apple 均无关联，仅供协议与界面研究，安装研究后请于 24 小时内删除软体及其数据

by 小刘不柒糖
