import Foundation
import CryptoKit

/// iAP2 消息层参数 —— 照原版 `IAP2Parameter.encoded()` / `.parse()` 反编译实现。
///
/// 布局：`[length BE16 = value.count + 4][id BE16][value…]`
/// length 语义为「包含自身 2 字节在内的整条参数长度」。
struct IAP2Parameter: Equatable {
    var id: UInt16
    var value: Data

    init(id: UInt16, value: Data) {
        self.id = id
        self.value = value
    }

    func encoded() -> Data {
        let length = value.count + 4
        precondition(length <= 0xFFFF, "iAP2 parameter too long: \(length)")
        var data = Data(capacity: length)
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(UInt8((id >> 8) & 0xFF))
        data.append(UInt8(id & 0xFF))
        data.append(value)
        return data
    }

    /// 从字节流起始位置解一条参数，返回参数与其占用长度。
    static func parseOne(_ bytes: [UInt8], at offset: Int) -> (parameter: IAP2Parameter, size: Int)? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        guard length >= 4, offset + length <= bytes.count else { return nil }
        let id = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
        let value = Data(bytes[(offset + 4)..<(offset + length)])
        return (IAP2Parameter(id: id, value: value), length)
    }

    static func parse(_ data: Data) -> [IAP2Parameter] {
        let bytes = [UInt8](data)
        var result: [IAP2Parameter] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            guard let (parameter, size) = parseOne(bytes, at: offset), size > 0 else { break }
            result.append(parameter)
            offset += size
        }
        return result
    }
}

/// iAP2 消息 —— 照原版 `IAP2Message.encoded()` / `.parse()` 反编译实现。
///
/// 布局（原版 parse 逐字节校验过）：
/// ```
///  0..1  sync = 0x40 0x40      （静态字面量 DAT_1001b5398 = 40 40）
///  2..3  length BE16 = 整条消息总长（含自身）
///  4..5  messageID BE16
///  6..   parameters 串联
/// ```
/// **注意**：此前实现漏掉了 `40 40` 这 2 字节同步头，导致 length 少算 2、
/// 整个消息体错位 —— 这是 iOS 侧完全不解析我们消息的直接原因。
struct IAP2Message: Equatable {
    static let sync: [UInt8] = [0x40, 0x40]
    /// 固定头长度：sync(2) + length(2) + messageID(2)
    static let headerSize = 6

    var id: UInt16
    var parameters: [IAP2Parameter]

    init(id: UInt16, parameters: [IAP2Parameter] = []) {
        self.id = id
        self.parameters = parameters
    }

    func encoded() -> Data {
        var body = Data()
        for parameter in parameters {
            body.append(parameter.encoded())
        }
        let length = body.count + IAP2Message.headerSize
        precondition(length <= 0xFFFF, "iAP2 message too long: \(length)")

        var data = Data(capacity: length)
        data.append(IAP2Message.sync[0])
        data.append(IAP2Message.sync[1])
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(UInt8((id >> 8) & 0xFF))
        data.append(UInt8(id & 0xFF))
        data.append(body)
        return data
    }

    static func parse(_ payload: Data) -> IAP2Message? {
        let bytes = [UInt8](payload)
        guard bytes.count >= IAP2Message.headerSize else { return nil }
        guard bytes[0] == IAP2Message.sync[0], bytes[1] == IAP2Message.sync[1] else { return nil }
        let length = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length == bytes.count else { return nil }
        let id = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
        let parameters = IAP2Parameter.parse(Data(bytes[IAP2Message.headerSize...]))
        return IAP2Message(id: id, parameters: parameters)
    }

    func parameter(_ parameterID: UInt16) -> IAP2Parameter? {
        parameters.first { $0.id == parameterID }
    }

    func data(_ parameterID: UInt16) -> Data? {
        parameter(parameterID)?.value
    }

    /// 取字符串参数，iAP2 里常见 UTF-8 带结尾 0。
    func string(_ parameterID: UInt16) -> String? {
        guard let value = parameter(parameterID)?.value else { return nil }
        var bytes = [UInt8](value)
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// 按 offset 遍历参数（原版 handle 里 `while psVar41` 的等价写法）。
    func group(_ parameterID: UInt16) -> [IAP2Parameter] {
        parameters.filter { $0.id == parameterID }
    }

    var summary: String {
        "0x" + String(format: "%04X", id) + "[" +
        parameters.map { "\($0.id):\($0.value.count)B" }.joined(separator: ",") + "]"
    }
}

/// TLV8，用于配对阶段传键值（RTSP Pair-Setup / Pair-Verify）。
enum TLV8 {
    struct Item {
        var type: UInt8
        var value: Data
    }

    static func encode(_ items: [Item]) -> Data {
        var data = Data()
        for item in items {
            var value = item.value
            repeat {
                let chunk = value.prefix(255)
                data.append(item.type)
                data.append(UInt8(chunk.count))
                data.append(chunk)
                value = value.dropFirst(chunk.count)
            } while !value.isEmpty
        }
        return data
    }

    static func decode(_ data: Data) -> [Item] {
        var items: [Item] = []
        var index = data.startIndex
        while index + 2 <= data.endIndex {
            let type = data[index]
            let length = Int(data[index + 1])
            let start = index + 2
            guard start + length <= data.endIndex else { break }
            let value = data[start..<start + length]
            if let last = items.last, last.type == type, last.value.count % 255 == 0 {
                items[items.count - 1].value.append(value)
            } else {
                items.append(Item(type: type, value: Data(value)))
            }
            index = start + length
        }
        return items
    }
}
