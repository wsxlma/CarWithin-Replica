import Foundation

/// 九号私有 RTP 分片（20 字节头 + ≤1380 字节负载）。
/// 布局与作者 MIT 实现一致：五寸直发，七寸把它整体塞进 KCP。
enum NinebotRTP {
    static let chunk = 1380

    static func packets(for data: Data, timestampMs: UInt32,
                        key: Bool, repeatKey: Bool) -> [Data] {
        var result: [Data] = []
        let times = (key && repeatKey) ? 2 : 1
        var sequence: UInt16 = 0

        for _ in 0..<times {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                let piece = data[offset..<end]
                let first = offset == 0
                let last = end == data.count

                var header = Data(count: 20)
                header[0] = 0x90
                header[1] = 0x20 | (last ? 0x80 : 0)
                header[2] = UInt8(sequence >> 8)
                header[3] = UInt8(sequence & 0xff)
                header[4] = UInt8((timestampMs >> 24) & 0xff)
                header[5] = UInt8((timestampMs >> 16) & 0xff)
                header[6] = UInt8((timestampMs >> 8) & 0xff)
                header[7] = UInt8(timestampMs & 0xff)
                header[15] = 1
                header[17] = (key ? 1 : 2)
                    | (first ? 0x10 : 0)
                    | (last ? 0x08 : 0)
                let tail = UInt16((timestampMs & 0x3ff) | 0x400)
                header[18] = UInt8(tail & 0xff)
                header[19] = UInt8(tail >> 8)

                sequence = sequence &+ 1
                var packet = Data(capacity: 20 + piece.count)
                packet.append(header)
                packet.append(piece)
                result.append(packet)
                offset = end
            }
        }
        return result
    }

    static func heartbeat(_ counter: UInt32) -> Data {
        var data = Data([0x85, 0xcc, 0x00, 0x04, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: withUnsafeBytes(of: counter.littleEndian) { Array($0) })
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        return data
    }

    static func heartbeatReply(_ data: Data) -> UInt32? {
        guard data.count == 20 else { return nil }
        let prefix = Data([0x85, 0xcc, 0x00, 0x04, 0, 0, 0, 1, 0, 0, 0, 0])
        guard data.prefix(12) == prefix, data.suffix(4) == Data([0x02, 0, 0, 0]) else { return nil }
        let i = data.startIndex + 12
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }

    static let bye = Data([0x80, 0xcb, 0x00, 0x00])
}
