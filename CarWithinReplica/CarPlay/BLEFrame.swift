import Foundation

/// BLE 自定义帧 —— 照原版 `TDSCarKit.BLEFrame` 反编译实现。
///
/// 原版 `BLEFrame.encoded()`：
/// ```
/// putBE16(type)            // 2 字节大端
/// putBE32(payload.count)   // 4 字节大端
/// append(payload)
/// ```
/// 因此线上布局为 `[type BE16][length BE32][payload]`，length 只算 payload。
struct BLEFrame: Equatable {
    var type: UInt16
    var payload: Data

    static let headerSize = 6

    init(type: UInt16, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data(capacity: payload.count + BLEFrame.headerSize)
        data.append(UInt8((type >> 8) & 0xFF))
        data.append(UInt8(type & 0xFF))
        let count = UInt32(payload.count)
        data.append(UInt8((count >> 24) & 0xFF))
        data.append(UInt8((count >> 16) & 0xFF))
        data.append(UInt8((count >> 8) & 0xFF))
        data.append(UInt8(count & 0xFF))
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> BLEFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= BLEFrame.headerSize else { return nil }
        let type = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let length = (Int(bytes[2]) << 24) | (Int(bytes[3]) << 16) | (Int(bytes[4]) << 8) | Int(bytes[5])
        guard length >= 0, bytes.count == BLEFrame.headerSize + length else { return nil }
        return BLEFrame(type: type, payload: Data(bytes[BLEFrame.headerSize...]))
    }
}

/// L2CAP 字节流切帧器。
struct BLEFrameParser {
    private var buffer = Data()
    private(set) var droppedBytes = 0
    private(set) var lastDropReason: String?

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> BLEFrame? {
        guard buffer.count >= BLEFrame.headerSize else { return nil }
        let start = buffer.startIndex
        let length = (Int(buffer[start + 2]) << 24) | (Int(buffer[start + 3]) << 16)
                   | (Int(buffer[start + 4]) << 8) | Int(buffer[start + 5])
        guard length >= 0, length <= 0x20000 else {
            buffer.removeFirst()
            droppedBytes += 1
            lastDropReason = "BLEFrame length 非法(\(length))"
            return nil
        }
        let total = BLEFrame.headerSize + length
        guard buffer.count >= total else { return nil }
        let slice = Data(buffer.prefix(total))
        buffer.removeFirst(total)
        return BLEFrame.decode(slice)
    }

    mutating func reset() {
        buffer.removeAll()
        droppedBytes = 0
        lastDropReason = nil
    }
}
