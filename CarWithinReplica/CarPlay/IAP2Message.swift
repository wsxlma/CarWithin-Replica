import Foundation

/// iAP2 消息层：消息 id + 一组 TLV 参数。
/// 格式：`messageID(2) | [paramID(2) | length(2) | value]*`
struct IAP2Parameter: Equatable {
    var id: UInt16
    var value: Data

    func encoded() -> Data {
        var data = Data(capacity: 4 + value.count)
        data.append(UInt8((id >> 8) & 0xFF))
        data.append(UInt8(id & 0xFF))
        data.append(UInt8((value.count >> 8) & 0xFF))
        data.append(UInt8(value.count & 0xFF))
        data.append(value)
        return data
    }

    static func decode(_ data: Data, offset: inout Int) -> IAP2Parameter? {
        let start = data.startIndex
        guard offset + 4 <= data.count else { return nil }
        let id = (UInt16(data[start + offset]) << 8) | UInt16(data[start + offset + 1])
        let length = (Int(data[start + offset + 2]) << 8) | Int(data[start + offset + 3])
        offset += 4
        guard length >= 0, offset + length <= data.count else { return nil }
        let value = data[(start + offset)..<(start + offset + length)]
        offset += length
        return IAP2Parameter(id: id, value: Data(value))
    }
}

struct IAP2Message: Equatable {
    var id: UInt16
    var parameters: [IAP2Parameter]

    func encoded() -> Data {
        var data = Data(capacity: 4 + parameters.count * 8)
        data.append(UInt8((id >> 8) & 0xFF))
        data.append(UInt8(id & 0xFF))
        for parameter in parameters {
            data.append(parameter.encoded())
        }
        return data
    }

    static func decode(_ payload: Data) -> IAP2Message? {
        guard payload.count >= 2 else { return nil }
        let start = payload.startIndex
        let id = (UInt16(payload[start]) << 8) | UInt16(payload[start + 1])
        var offset = 2
        var parameters: [IAP2Parameter] = []
        while offset < payload.count {
            guard let parameter = IAP2Parameter.decode(payload, offset: &offset) else { break }
            parameters.append(parameter)
        }
        return IAP2Message(id: id, parameters: parameters)
    }

    /// 取字符串参数，iAP2 里常见 UTF-8 + 结尾 0。
    func string(_ parameterID: UInt16) -> String? {
        guard let parameter = parameters.first(where: { $0.id == parameterID }) else { return nil }
        var bytes = [UInt8](parameter.value)
        while bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// 常用消息 id（按 iAP2 规范常用的几个，后续可按抓包扩充）。
enum IAP2MessageID {
    static let requestAuthentication: UInt16 = 0xAA00
    static let requestAuthenticationCert: UInt16 = 0xAA01
    static let requestAuthenticationSignature: UInt16 = 0xAA02
    static let authStatus: UInt16 = 0xAA03
    static let startIDPS: UInt16 = 0xEA00
    static let setFIDToken: UInt16 = 0xEA01
    static let startSession: UInt16 = 0xE000
    static let stopSession: UInt16 = 0xE001
    static let accessoryInfo: UInt16 = 0xEA02
}

/// TLV8，用于配对阶段传键值。
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
