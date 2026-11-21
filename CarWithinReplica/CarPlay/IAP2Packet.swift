import Foundation

/// iAP2 链路层封包。
///
/// 字段宽度依据符号表：`controls` / `sessions` / `sequences` / `acknowledgement`
/// 都是 `UInt8`，`payload` 是 `Data`。线上格式按 iAP2 规范为：
/// `length(2, big endian) | control(1) | session(1) | sequence(1) | ack(1) | payload`
struct IAP2Packet: Equatable {
    var control: UInt8
    var session: UInt8
    var sequence: UInt8
    var acknowledgement: UInt8
    var payload: Data

    static let headerSize = 6          // 2 字节长度 + 4 字节字段

    init(control: UInt8, session: UInt8, sequence: UInt8,
         acknowledgement: UInt8, payload: Data = Data()) {
        self.control = control
        self.session = session
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payload = payload
    }

    /// 设备探测包：control 全 1、其余为 0，用于让对端回 presence。
    static var presence: IAP2Packet {
        IAP2Packet(control: 0xFF, session: 0, sequence: 0, acknowledgement: 0)
    }

    func encoded() -> Data {
        let bodyLength = 4 + payload.count
        var data = Data(capacity: 2 + bodyLength)
        data.append(UInt8((bodyLength >> 8) & 0xFF))
        data.append(UInt8(bodyLength & 0xFF))
        data.append(control)
        data.append(session)
        data.append(sequence)
        data.append(acknowledgement)
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> IAP2Packet? {
        guard data.count >= headerSize else { return nil }
        let start = data.startIndex
        let length = (Int(data[start]) << 8) | Int(data[start + 1])
        guard length >= 4, data.count >= 2 + length else { return nil }
        let payloadStart = start + headerSize
        let payloadEnd = start + 2 + length
        return IAP2Packet(
            control: data[start + 2],
            session: data[start + 3],
            sequence: data[start + 4],
            acknowledgement: data[start + 5],
            payload: data[payloadStart..<payloadEnd])
    }
}

/// 从 TCP 字节流里切出完整封包。iAP2 是长度前缀协议，必须缓冲半包。
struct IAP2Parser {
    private var buffer = Data()
    private(set) var droppedBytes = 0

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> IAP2Packet? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let length = (Int(buffer[start]) << 8) | Int(buffer[start + 1])
        guard length >= 4, length <= 1 << 20 else {
            // 长度异常，丢一字节重新同步
            buffer.removeFirst()
            droppedBytes += 1
            return nil
        }
        let total = 2 + length
        guard buffer.count >= total else { return nil }
        let slice = buffer.prefix(total)
        buffer.removeFirst(total)
        return IAP2Packet.decode(Data(slice))
    }

    mutating func reset() {
        buffer.removeAll()
        droppedBytes = 0
    }
}
