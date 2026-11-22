import Foundation

/// iAP2 链路层封包。
///
/// 依据原版字符串证据：`iAP2 sync`、`iAP2 length`、`iAP2 header checksum`、`iAP2 parameter`。
/// 线上格式：
/// `sync(2)=FF 5A | length(2, 含头含载荷) | control(1) | session(1) |
///  sequence(1) | acknowledgement(1) | checksum(1) | payload`
/// checksum = 头部前 8 字节之和的二进制补码。
struct IAP2Packet: Equatable {
    var control: UInt8
    var session: UInt8
    var sequence: UInt8
    var acknowledgement: UInt8
    var payload: Data

    static let sync: [UInt8] = [0xFF, 0x5A]
    static let headerSize = 8

    init(control: UInt8, session: UInt8, sequence: UInt8,
         acknowledgement: UInt8, payload: Data = Data()) {
        self.control = control
        self.session = session
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payload = payload
    }

    static var presence: IAP2Packet {
        IAP2Packet(control: 0xFF, session: 0, sequence: 0, acknowledgement: 0)
    }

    /// 标准 iAP2 包：[0xFF 0x5A][Length:2B][Control][Session][Seq][Ack][Payload][Checksum]
    /// Length = 从 Control 到 Checksum 的字节数（含 checksum，不含 sync/length 自身）。
    /// Checksum = 256 - (前面所有字节之和 & 0xFF)，放在包的最后。
    func encoded() -> Data {
        var body = Data()
        body.append(control)
        body.append(session)
        body.append(sequence)
        body.append(acknowledgement)
        body.append(payload)

        let length = body.count + 1     // +1 = checksum 自己
        var data = Data()
        data.append(contentsOf: IAP2Packet.sync)
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(body)

        var sum: UInt32 = 0
        for byte in data { sum &+= UInt32(byte) }
        data.append(UInt8(truncatingIfNeeded: 0x100 &- (sum & 0xFF)))
        return data
    }

    static func decode(_ data: Data) -> IAP2Packet? {
        guard data.count >= 9 else { return nil }
        let start = data.startIndex
        guard data[start] == sync[0], data[start + 1] == sync[1] else { return nil }
        let length = (Int(data[start + 2]) << 8) | Int(data[start + 3])
        guard length >= 5, data.count >= 4 + length else { return nil }

        // checksum 是全包最后一个字节
        let checksumIndex = start + 4 + length - 1
        var sum: UInt32 = 0
        for index in start..<checksumIndex { sum &+= UInt32(data[index]) }
        let expected = UInt8(truncatingIfNeeded: 0x100 &- (sum & 0xFF))
        guard data[checksumIndex] == expected else { return nil }

        let payloadStart = start + 8        // sync(2) + len(2) + control/session/seq/ack(4)
        let payloadEnd = checksumIndex
        let payload = payloadStart < payloadEnd ? Data(data[payloadStart..<payloadEnd]) : Data()
        return IAP2Packet(
            control: data[start + 4],
            session: data[start + 5],
            sequence: data[start + 6],
            acknowledgement: data[start + 7],
            payload: payload)
    }
}

/// 从字节流里切出完整 iAP2 封包：先对齐 sync，再按 length 取整包（含 checksum）。
struct IAP2Parser {
    private var buffer = Data()
    private(set) var droppedBytes = 0

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> IAP2Packet? {
        while buffer.count >= 2 {
            let start = buffer.startIndex
            if buffer[start] == 0xFF, buffer[start + 1] == 0x5A { break }
            buffer.removeFirst()
            droppedBytes += 1
        }
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = (Int(buffer[start + 2]) << 8) | Int(buffer[start + 3])
        // 新格式：length = control..checksum 的字节数；整包 = 4 + length
        guard length >= 5, length <= 1 << 20 else {
            buffer.removeFirst()
            droppedBytes += 1
            return nil
        }
        let total = 4 + length
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
