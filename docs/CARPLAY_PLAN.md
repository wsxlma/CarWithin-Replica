# CarPlay 会话实施计划（基于符号表与反编译证据）

> 结论先行：这是 **iAP2 配件仿真**，不是薄封装。可以按阶段实现，但每一阶段都必须
> 在真机上对包，否则无法判断"写完"和"能跑"之间的距离。

## 一、证据

### 入口

```
NativeReceiver.start(configuration:identity:advertise:preferredViewer:)
```

`advertise: Bool` 说明它可以选择是否对外广播为配件；`identity: AccessoryIdentity`
是配件身份，`preferredViewer: UUID?` 指定首选显示端。

### 音频

```
CarPlayAudio.init(secret: CryptoKit.SymmetricKey,
                  peerAddress: String,
                  connectionID: UInt64,
                  format: ReceiverAudioFormat,
                  microphonePort: UInt16?)
```

有独立 `dataPort` / `controlPort` / `microphonePort`，媒体流是**加密**的（对称密钥）。
这不是普通 RTP，不能拿现成的 UDP 发送端直接套。

### iAP2 包结构

```
IAP2Packet: presence / control / session / sequence / acknowledgement / payload
IAP2Parser
IAP2Message: id + parameters
IAP2Parameter: id + value
```

标准的 iAP2 链路层：先 presence 探测，再开 session，然后按 control 位与序列号收发。

### HID 能力

```
CarPlayInfo.HID.touch / knob / media / telephony
CarPlayInfo.touchContacts
CarPlayInfo.defaultWidthPhysicalMM
```

屏幕物理尺寸要上报，触控要按 contact 索引回传，说明还有一套 HID 描述符要构造。

### 鉴权与配对

`MFiSAP`、`PairSetup`、`PairVerify`、`SRPServer`、`TLV8`、`BigInt`、`BigUInt`、
`ControlCipher`、`AccessoryIdentityStore`、`BLEBootstrap`、`BLEFrame`。

其中 `SRPServer` + `TLV8` 是 HomeKit 风格配对流程；`MFiSAP` 是 MFi 协处理器协议。

## 二、为什么"申请一份证书"不是捷径

CarPlay 接收端属于 **Made for iPhone / CarPlay 硬件认证**范畴：

- 需要企业主体、NDA、认证样机与实验室测试
- 证书绑定的是**配件硬件**，不是随便一个 App
- 应用商店不允许"把车机界面镜像到手机"这类用途

也就是说，即使拿到证书，也解决不了"这个 App 要伪装成车机"的合法性问题。
原版用私有接口 + 侧载分发，本质是绕开这条路。

这条路我可以帮你梳理申请口径，但它不会让代码明天就能跑。

## 三、可执行的分阶段计划

| 阶段 | 目标 | 验收标准 | 依赖 |
| --- | --- | --- | --- |
| S1 | 建连 | 拿到 `ACCTransportClient`，收到第一个 iAP2 presence 包 | 真机 + 诊断页探测通过 |
| S2 | 会话 | 完成 startSession，`sessionID` 稳定 | 真机抓包 |
| S3 | 鉴权 | PairSetup/PairVerify 通过，`ControlCipher` 建立 | 真机 + 证书/身份 |
| S4 | 屏幕 | 收到 H.264 分片并能解码出一帧 | 真机 |
| S5 | 触控 | 回传触控，车机界面可操作 | 真机 |
| S6 | 音频 | 加密音频通路可用 | 真机 |

每一阶段都需要一次真机验证，无法用静态分析替代。

## 四、当前仓库的边界

- ✅ 设置页、诊断、浏览器输出（MJPEG）、九号 5/7 寸链路
- ⛔ CarPlay（S1 未开始）、CarLife
- ❌ 台铃（按需求删除）

把 S1 写成代码并不难，难的是"写完就能用"这个判断。在拿到第一包之前，
任何声称"已完成 CarPlay"的说法都是猜的。
