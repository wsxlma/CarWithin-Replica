import Foundation

/// OPACK 值 —— 照原版 `TDSCarKit.OPACKValue` / `OPACK.encode` 反编译的 tag 表实现。
///
/// 已从 `analysis/proto.c` 确认的 tag：
/// - `0x01` true / `0x02` false / `0x03` null
/// - 短字符串 `0x08 + len`（len ≤ 39，原版判据 `0x27 < count` 才升级成长格式）
/// - 长字符串 `0x30|sizeCode`，sizeCode 0/1/2/3 → 1/2/4/8 字节长度
/// - 短 Data `0x40 + len`，长 Data `0x60|sizeCode`（原版 `bytes(shortBase:0x40, longBase:0x60)`）
/// - 短整数 `0x70 + len`，长整数 `0x90|sizeCode`（原版 `bytes(shortBase:0x70, longBase:0x90)`）
/// - 短数组 `0xD0|count`（count ≤ 15）
/// - 短字典 `0xE0|count`（count ≤ 15，键按字典序排序后依次编码）
enum OPACKValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case data(Data)
    case array([OPACKValue])
    case dictionary([String: OPACKValue])
}

enum OPACKError: LocalizedError {
    case nestingTooDeep(Int)
    case collectionTooLarge(kind: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .nestingTooDeep(let depth):
            return "OPACK 嵌套超过 32 层（当前 \(depth)）"
        case .collectionTooLarge(let kind, let count):
            return "OPACK \(kind) 元素数 \(count) 超过 15，原版未定义该扩展格式"
        }
    }
}

enum OPACK {
    static let maxDepth = 32

    static func encode(_ value: OPACKValue) throws -> Data {
        try encode(value, depth: 0)
    }

    private static func encode(_ value: OPACKValue, depth: Int) throws -> Data {
        guard depth <= maxDepth else { throw OPACKError.nestingTooDeep(depth) }

        switch value {
        case .null:
            return Data([0x03])

        case .bool(let flag):
            return Data([flag ? 0x01 : 0x02])

        case .string(let text):
            let bytes = Data(text.utf8)
            if bytes.count <= 39 {
                var out = Data([UInt8(0x08 + bytes.count)])
                out.append(bytes)
                return out
            }
            return try lengthPrefixed(bytes, shortBase: nil, longBase: 0x30, kind: "string")

        case .data(let raw):
            if raw.count <= 31 {
                var out = Data([UInt8(0x40 + raw.count)])
                out.append(raw)
                return out
            }
            return try lengthPrefixed(raw, shortBase: nil, longBase: 0x60, kind: "data")

        case .int(let number):
            var magnitude = Data()
            var remaining = number
            if remaining == 0 {
                magnitude = Data([0])
            } else {
                while remaining != 0 {
                    magnitude.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
                    remaining >>= 8
                }
            }
            if magnitude.count <= 7 {
                var out = Data([UInt8(0x70 + magnitude.count)])
                out.append(magnitude)
                return out
            }
            return try lengthPrefixed(magnitude, shortBase: nil, longBase: 0x90, kind: "int")

        case .array(let items):
            guard items.count <= 15 else {
                throw OPACKError.collectionTooLarge(kind: "array", count: items.count)
            }
            var out = Data([UInt8(0xD0 | items.count)])
            for item in items {
                out.append(try encode(item, depth: depth + 1))
            }
            return out

        case .dictionary(let map):
            guard map.count <= 15 else {
                throw OPACKError.collectionTooLarge(kind: "dictionary", count: map.count)
            }
            var out = Data([UInt8(0xE0 | map.count)])
            // 原版 `keys.sorted()`：字典序稳定排序后依次写 key、value。
            for key in map.keys.sorted() {
                out.append(try encode(.string(key), depth: depth + 1))
                out.append(try encode(map[key]!, depth: depth + 1))
            }
            return out
        }
    }

    /// `[longBase|sizeCode][length][bytes]`，sizeCode 0/1/2/3 → 1/2/4/8 字节长度字段。
    private static func lengthPrefixed(_ bytes: Data,
                                       shortBase: UInt8?,
                                       longBase: UInt8,
                                       kind: String) throws -> Data {
        var out = Data()
        let count = bytes.count
        if count <= 0xFF {
            out.append(longBase | 0)
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(longBase | 1)
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else if UInt64(count) <= 0xFFFF_FFFF {
            out.append(longBase | 2)
            out.append(UInt8((count >> 24) & 0xFF))
            out.append(UInt8((count >> 16) & 0xFF))
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(longBase | 3)
            let value = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(bytes)
        return out
    }

    /// 日志用：把编码结果打成 hex，方便和原版抓包逐字节比对。
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
