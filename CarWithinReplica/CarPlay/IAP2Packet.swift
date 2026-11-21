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
    static let headerSize = 9

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

    func encoded() -> Data {
        let total = IAP2Packet.headerSize + payload.count
        var data = Data(capacity: total)
        data.append(contentsOf: IAP2Packet.sync)
        data.append(UInt8((total >> 8) & 0xFF))
        data.append(UInt8(total & 0xFF))
        data.append(control)
        data.append(session)
        data.append(sequence)
        data.append(acknowledgement)

        var sum: UInt32 = 0
        for byte in data { sum &+= UInt32(byte) }
        data.append(UInt8(truncatingIfNeeded: 0x100 &- (sum & 0xFF)))

        data.append(payload)
        return data
    }

    static func decode(_ data: Data) -> IAP2Packet? {
        guard data.count >= headerSize else { return nil }
        let start = data.startIndex
        guard data[start] == sync[0], data[start + 1] == sync[1] else { return nil }
        let length = (Int(data[start + 2]) << 8) | Int(data[start + 3])
        guard length >= headerSize, data.count >= length else { return nil }

        var sum: UInt32 = 0
        for index in 0..<8 { sum &+= UInt32(data[start + index]) }
        let expected = UInt8(truncatingIfNeeded: 0x100 &- (sum & 0xFF))
        guard data[start + 8] == expected else { return nil }

        let payloadStart = start + headerSize
        let payloadEnd = start + length
        return IAP2Packet(
            control: data[start + 4],
            session: data[start + 5],
            sequence: data[start + 6],
            acknowledgement: data[start + 7],
            payload: data[payloadStart..<payloadEnd])
    }
}

/// 从 TCP 字节流里切出完整封包：先对齐 sync，再按长度取整包。
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
        guard length >= IAP2Packet.headerSize, length <= 1 << 20 else {
            buffer.removeFirst()
            droppedBytes += 1
            return nil
        }
        guard buffer.count >= length else { return nil }
        let slice = buffer.prefix(length)
        buffer.removeFirst(length)
        return IAP2Packet.decode(Data(slice))
    }

    mutating func reset() {
        buffer.removeAll()
        droppedBytes = 0
    }
}
