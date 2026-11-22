import Foundation

/// iAP2 链路层封包 —— 严格照原版 `TDSCarKit.IAP2Packet.encoded()` 反编译结果实现。
///
/// 原版字节布局（`analysis/iap2packet.c`）：
/// ```
///  0     FF 5A                      sync（静态字面量 DAT_1001b5358 = ff 5a）
///  2..3  length  BE16 = payload.count + 10   （含自身与两个 checksum）
///  4     control
///  5     sequence
///  6     acknowledgement
///  7     session
///  8     headerChecksum = checksum(bytes[0..<8])
///  9..   payload
///  end   payloadChecksum = checksum(payload)
/// ```
/// 注意字段顺序是 `control / sequence / acknowledgement / session`（session 在最后），
/// 这与原版 init 签名 `init(control:sequence:acknowledgement:session:payload:)` 完全一致。
struct IAP2Packet: Equatable {
    var control: UInt8
    var sequence: UInt8
    var acknowledgement: UInt8
    var session: UInt8
    var payload: Data

    /// 原版同步字（DAT_1001b5358）。
    static let sync: [UInt8] = [0xFF, 0x5A]
    /// 头部固定 9 字节：sync(2) + length(2) + 4 字段 + 1 校验。
    static let headerSize = 9
    /// 整包相对 payload 的固定开销。
    static let overhead = 10

    init(control: UInt8,
         sequence: UInt8 = 0,
         acknowledgement: UInt8 = 0,
         session: UInt8 = 0,
         payload: Data = Data()) {
        self.control = control
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.session = session
        self.payload = payload
    }

    /// 原版 `IAP2Packet.presence`（DAT_1001b5308，6 字节常量）。
    /// 它是 iAP2 的 Link Sync 探测帧，格式与普通包不同，不可由 encoded() 生成。
    static var presence: Data { Data([0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]) }

    /// `checksum(data) = (0 - sum(bytes)) & 0xFF`，即二进制补码。
    static func checksum(_ bytes: Data) -> UInt8 {
        var sum: UInt32 = 0
        for byte in bytes { sum = sum &+ UInt32(byte) }
        return UInt8(truncatingIfNeeded: (0 &- sum) & 0xFF)
    }

    func encoded() -> Data {
        let length = payload.count + IAP2Packet.overhead
        precondition(length <= 0xFFFF, "iAP2 packet too long: \(length)")

        var data = Data(capacity: payload.count + IAP2Packet.overhead)
        data.append(IAP2Packet.sync[0])
        data.append(IAP2Packet.sync[1])
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(control)
        data.append(sequence)
        data.append(acknowledgement)
        data.append(session)
        data.append(IAP2Packet.checksum(data))
        if !payload.isEmpty {
            data.append(payload)
            data.append(IAP2Packet.checksum(payload))
        }
        return data
    }

    /// 解析一整包（必须正好是完整包，长度与校验都要对）。
    static func decode(_ data: Data) -> IAP2Packet? {
        let bytes = [UInt8](data)
        guard bytes.count >= IAP2Packet.headerSize + 1 else { return nil }
        guard bytes[0] == 0xFF, bytes[1] == 0x5A else { return nil }

        let length = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length == bytes.count, length >= IAP2Packet.overhead else { return nil }

        let header = Data(bytes[0..<8])
        guard bytes[8] == IAP2Packet.checksum(header) else { return nil }

        let payloadEnd = bytes.count - 1
        let payload = Data(bytes[IAP2Packet.headerSize..<payloadEnd])
        guard bytes[payloadEnd] == IAP2Packet.checksum(payload) else { return nil }

        return IAP2Packet(control: bytes[4],
                          sequence: bytes[5],
                          acknowledgement: bytes[6],
                          session: bytes[7],
                          payload: payload)
    }
}

/// 从字节流中切包：先对齐 `FF 5A`，再按 length 取整包。
struct IAP2Parser {
    private var buffer = Data()
    private(set) var droppedBytes = 0
    private(set) var lastDropReason: String?

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> IAP2Packet? {
        while buffer.count >= 2 {
            let start = buffer.startIndex
            if buffer[start] == 0xFF, buffer[start + 1] == 0x5A { break }
            buffer.removeFirst()
            droppedBytes += 1
            lastDropReason = "sync 未对齐"
        }
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = (Int(buffer[start + 2]) << 8) | Int(buffer[start + 3])
        guard length >= IAP2Packet.overhead, length <= 1 << 20 else {
            buffer.removeFirst()
            droppedBytes += 1
            lastDropReason = "length 非法(\(length))"
            return nil
        }
        guard buffer.count >= length else { return nil }
        let slice = Data(buffer.prefix(length))
        buffer.removeFirst(length)
        guard let packet = IAP2Packet.decode(slice) else {
            droppedBytes += slice.count
            lastDropReason = "校验失败"
            return nil
        }
        return packet
    }

    mutating func reset() {
        buffer.removeAll()
        droppedBytes = 0
        lastDropReason = nil
    }
}

/// 常用消息 id（原版 `SameDeviceProbe.handle` 里出现的全部 case）。
enum IAP2MessageID {
    static let requestAuthentication: UInt16 = 0xAA00
    static let authenticationCertificate: UInt16 = 0xAA01
    static let requestAuthenticationSignature: UInt16 = 0xAA02
    static let authenticationSignature: UInt16 = 0xAA03
    static let authenticationSucceeded: UInt16 = 0xAA04
    static let authenticationAccepted: UInt16 = 0xAA05
    static let requestIdentification: UInt16 = 0x1D00
    static let identificationInformation: UInt16 = 0x1D01
    static let identificationAccepted: UInt16 = 0x1D02
    static let identificationRejected: UInt16 = 0x1D03
    static let carPlayAvailable: UInt16 = 0x4300
    static let startCarPlaySession: UInt16 = 0x4301
    static let startIDPS: UInt16 = 0xEA00
    static let setFIDToken: UInt16 = 0xEA01
    static let startSession: UInt16 = 0xE000
    static let stopSession: UInt16 = 0xE001
    static let accessoryInfo: UInt16 = 0xEA02
}
