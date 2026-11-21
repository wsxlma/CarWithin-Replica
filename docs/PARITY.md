# 功能对照表（对照 TDSCarKit 的 136 个 Swift 类型）

> 证据来源：`analysis/manifest.json`（LC_SYMTAB，22,214 符号）与
> `analysis/decompiled-*.c`（Ghidra 12.2 反编译）。
> 本表只描述**当前仓库的真实状态**，不写"应该能行"。

## 总览

| 模块 | 原版类型数 | 当前状态 | 说明 |
| --- | --- | --- | --- |
| 设置与界面 | 9 | ✅ 已复刻 | 分组、行样式、图标色块、开关与枚举行 |
| 诊断与实验 | — | ✅ 可用 | 进程内日志、复制、清空；仅此入口留在「支持」 |
| 九号 5 寸输出 | 5 | ✅ 可用（待真机） | 裸 RTP + UDP 5012，VideoToolbox 编码 |
| 九号 7 寸输出 | — | ✅ 可用（待真机） | RTP 封装进 KCP(conv=3)，1024×600 / 25 FPS |
| CarPlay 会话 | 36 | ⛔ 未实现 | 依赖 `ACCTransportClient` 私有配件传输 |
| 浏览器输出 / HTTPS | 7 | ◐ 部分实现 | HTTP + MJPEG 已可用；WebSocket/WebCodecs 与自签 HTTPS 未做 |
| 无线 CarLife | 7 | ⛔ 未实现 | 协议移植量大，且需车机实测 |
| 台铃 4.3 寸 | 16 | ⛔ 未实现 | JPEG/TCP + RSA 身份协商 |
| 版本与更新 | 14 | ❌ 按需求删除 | 「关于」整组移除，含检查更新与版本记录 |
| 配对与蓝牙 | 18 | ⛔ 未实现 | BLE 引导、SRP、TLV8、MFiSAP |

> 「按需求删除」是产品决定；其余 ⛔ 是能力缺口，不是已完成。

## 逐项说明

### ✅ 已复刻：设置与界面

反编译里能看到 `rootSettingsPage` / `displayPage` / `screensPage` / `presetsPage` /
`vehiclePage` / `headUnitPage` / `aboutLinks` 这些真实方法名。当前实现对应：

| 原版页面 | 当前实现 | 备注 |
| --- | --- | --- |
| `rootSettingsPage` | `ReceiverViewController.makeSections` | 连接与输出 / CarPlay / 后台与画中画 / 支持 |
| `presetsPage` | `WiFiPresetsViewController` | 点选、左滑删除、新增 |
| `displayPage` / `screensPage` | `SelectionViewController`（画面 / 固定分辨率） | 枚举选择 |
| `vehiclePage` | `GuideViewController`（车辆） | 仅说明页，未做图标选择 |
| `headUnitPage` | `FormViewController`（输出设置） | 地址 / 端口 |
| `aboutLinks` | **只返回「诊断与实验」** | 其余四项按需求不构造 |

`SettingsRow` 的 `detail` 在原版是闭包（符号表可见 `...SSSgyyc`），当前用
`detail: (() -> String?)?` 保留同样语义，副标题会随设置变化。

### ✅ 九号链路（本轮新增，可真机验证）

| 环节 | 实现 | 与原版一致性 |
| --- | --- | --- |
| 私有 RTP 分片 | `NinebotRTP.packets` | 20 字节头、1380 分片，逐字节对照过作者 MIT 实现（Python 侧测试） |
| KCP | `Output/KCP.swift` | conv/MTU/重传/窗口，参数按 APK 字符串 `conv=3, nodelay/10ms` |
| 编码 | `H264Encoder` | VideoToolbox Baseline，Annex-B，关键帧补 SPS/PPS |
| 传输 | `NinebotOutput` | 五寸裸 UDP 5012；七寸 KCP over UDP 5012 |

未验证项：仪表是否接受首段、七寸 KCP MTU 实际值、24 字节控制回复含义。

### ⛔ CarPlay 会话：为什么没做

原版类型：`CarPlayControl`、`CarPlayAudio`、`CarPlayMediaSession`、`CarPlayHLS`、
`CarPlayPictureInPicture`、`IAP2Packet`、`IAP2Parser`、`AccessoryIdentity`、
`MFiSAP`、`PairSetup` / `PairVerify` / `SRPServer`、`TouchSlots`、`ScreenStream`、
`VideoOutputServer`、`NativeReceiver`、`SameDeviceProbe` 等 36 个。

二进制里自己印着：

```
CoreAccessories refused the connection.
This signed app may lack access to the private transport.
```

也就是说这条通道**受签名权限约束**。自签包可能拿不到 transport，代码写对也没用。
在真机验证权限之前投入逆向，风险是白干。

### ⛔ 浏览器输出：为什么没做

原版是 `BrowserReceiverPage` + `BrowserDisplay` + WebSocket + MSE/WebCodecs，
还有 `HTTPSConfiguration` / `LocalTLSIdentity` 负责自签证书。等于要在 App 内
实现一个 HTTP/WS 服务端 + 播放页 + 证书管理，工作量与仪表链路相当。

一个低成本的替代是先做 MJPEG over HTTP，但画质与延迟都不如原版，且会误导
"已经支持浏览器输出"，所以暂不提供。

### ❌ 版本与更新：按需求删除

`ReleaseDetailView`、`ReleaseDownloadView`、`ReleaseHistoryView`、`ReleaseNotesView`、
`ReleaseShareSheet`、`AppReleaseService`、`AppUpdatePolicy`、`IOSUpdateMetadata` 等
14 个类型对应「关于 → 检查更新」。需求要求移除整个「关于」入口，因此这些也一并不可达。

## 本轮自检发现并修正的问题

| 问题 | 现象 | 处理 |
| --- | --- | --- |
| `SettingsSection` / `SettingsIcon` 重复定义 | CI 报 `ambiguous for type lookup` | 删除重复文件 |
| `GuideViewController` 被误删 | CI 报 `cannot find in scope` | 单独建文件恢复 |
| `KCP.check` 混用 `Int32` 与 `Int` | CI 报 `cannot assign Int to Int32` | 改 `Int` |
| 首页卡片写死「九号 5 寸」 | 与"跟随当前输出"不符 | 改为读 `output.mode` |
| 设置分组名与真机不符 | 截图是「连接与输出」 | 已改名并补 `车辆` 行 |

## 下一步建议顺序

1. **真机验证九号链路**：装 v0.2.0，选九号 7 寸，看仪表是否出画、日志里 ACK 是否增长。
2. **验证私有 transport**：写一个最小 `dlopen` 探测，确认自签包能否拿到 `ACCTransportClient`。
3. 只有第 2 步通过，才值得投入 36 个 CarPlay 类型的逆向。
