import Foundation

/// KCP 可靠传输（skywind3000/kcp 的 ARQ 逻辑，MIT）。
/// 七寸仪表按 `conv=3, nodelay, interval=10ms` 使用；五寸走裸 RTP，不需要它。
final class KCP {
    private struct Segment {
        var conv: UInt32 = 0
        var cmd: UInt8 = 0
        var frg: UInt8 = 0
        var wnd: UInt16 = 0
        var ts: UInt32 = 0
        var sn: UInt32 = 0
        var una: UInt32 = 0
        var resendts: UInt32 = 0
        var rto: UInt32 = 0
        var fastack: Int = 0
        var xmit: Int = 0
        var data = Data()
    }

    private enum Cmd {
        static let push: UInt8 = 81
        static let ack: UInt8 = 82
        static let wask: UInt8 = 83
        static let wins: UInt8 = 84
    }

    private let conv: UInt32
    private let output: (Data) -> Void

    private var mtu: Int = 1400
    private var mss: Int { mtu - 24 }
    private var state: Int = -1
    private var sndUna: UInt32 = 0
    private var sndNxt: UInt32 = 0
    private var rcvNxt: UInt32 = 0
    private var sndWnd: UInt32 = 32
    private var rcvWnd: UInt32 = 128
    private var rmtWnd: UInt32 = 128
    private var cwnd: UInt32 = 0
    private var probe: UInt32 = 0
    private var current: UInt32 = 0
    private var interval: UInt32 = 10
    private var tsFlush: UInt32 = 0
    private var tsProbe: UInt32 = 0
    private var probeWait: UInt32 = 0
    private var updated = false
    private var nodelay = true
    private var fastresend = 2
    private var nocwnd = 1
    private var rxRttval: UInt32 = 0
    private var rxSrtt: UInt32 = 0
    private var rxRto: UInt32 = 200
    private var rxMinrto: UInt32 = 30
    private var ssthresh: UInt32 = 2
    private var incr: UInt32 = 0
    private var deadLink = 20

    private var sndQueue: [Segment] = []
    private var sndBuf: [Segment] = []
    private var rcvQueue: [Segment] = []
    private var rcvBuf: [Segment] = []
    private var ackList: [(UInt32, UInt32)] = []

    private(set) var retransmits = 0
    private(set) var sentSegments = 0
    private(set) var recvSegments = 0
    private(set) var recvBytes = 0

    init(conv: UInt32, output: @escaping (Data) -> Void) {
        self.conv = conv
        self.output = output
    }

    // MARK: 配置

    func setNoDelay(interval: UInt32 = 10, resend: Int = 2, noCongestion: Int = 1) {
        nodelay = true
        self.interval = max(10, interval)
        fastresend = resend
        nocwnd = noCongestion
        rxMinrto = 30
    }

    func setWindow(send: UInt32 = 128, receive: UInt32 = 128) {
        sndWnd = max(1, send)
        rcvWnd = max(128, receive)
    }

    func setMTU(_ value: Int) {
        mtu = max(64, value)
    }

    /// 有符号 32 位差，等价于 ikcp_itimediff。
    private func diff(_ later: UInt32, _ earlier: UInt32) -> Int32 {
        Int32(bitPattern: later &- earlier)
    }

    private func writable() -> Bool {
        UInt32(sndBuf.count) < min(sndWnd, rmtWnd)
    }

    // MARK: 发送

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        if data.count <= mss {
            var seg = Segment()
            seg.data = data
            seg.frg = 0
            sndQueue.append(seg)
            return
        }
        let count = (data.count + mss - 1) / mss
        if count >= Int(rcvWnd) { return }
        for i in 0..<count {
            var seg = Segment()
            let start = data.startIndex + i * mss
            let end = min(start + mss, data.endIndex)
            seg.data = data[start..<end]
            seg.frg = UInt8(count - i - 1)
            sndQueue.append(seg)
        }
    }

    // MARK: 时钟

    func update(_ ms: UInt32) {
        current = ms
        if !updated {
            updated = true
            tsFlush = ms
        }
        var slap = diff(ms, tsFlush)
        if slap >= 10000 || slap < -10000 {
            tsFlush = ms
            slap = 0
        }
        if slap >= 0 {
            tsFlush = tsFlush &+ interval
            if diff(ms, tsFlush) >= 0 {
                tsFlush = ms &+ interval
            }
            flush()
        }
    }

    func check(_ ms: UInt32) -> UInt32 {
        var minimal = diff(tsFlush, ms)
        if minimal < 0 { minimal = 0 }
        for seg in sndBuf {
            let d = diff(seg.resendts, ms)
            if d <= 0 { return ms }
            if Int(d) < minimal { minimal = Int(d) }
        }
        return ms &+ UInt32(max(0, minimal))
    }

    // MARK: flush

    private func encode(_ seg: Segment) -> Data {
        var data = Data(capacity: 24 + seg.data.count)
        data.append(contentsOf: withUnsafeBytes(of: seg.conv.littleEndian) { Array($0) })
        data.append(seg.cmd)
        data.append(seg.frg)
        data.append(contentsOf: withUnsafeBytes(of: seg.wnd.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: seg.ts.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: seg.sn.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: seg.una.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(seg.data.count).littleEndian) { Array($0) })
        data.append(seg.data)
        return data
    }

    private func flush() {
        guard updated else { return }
        var change = false
        var lost = false
        var pending = Data()

        func push(_ packet: Data) {
            if !pending.isEmpty && pending.count + packet.count > mtu {
                output(pending)
                pending = Data()
            }
            pending.append(packet)
        }

        // 远端窗口为 0 时探测
        if rmtWnd == 0 {
            if probeWait == 0 {
                probeWait = 7000
                tsProbe = current &+ probeWait
            } else if diff(current, tsProbe) >= 0 {
                probeWait = min(probeWait &+ probeWait / 2, 120000)
                tsProbe = current &+ probeWait
                probe |= 1
            }
        } else {
            probeWait = 0
        }

        if probe & 1 != 0 {
            var seg = Segment()
            seg.conv = conv; seg.cmd = Cmd.wask; seg.una = rcvNxt
            seg.wnd = UInt16(max(0, Int(rcvWnd) - rcvQueue.count))
            output(encode(seg))
        }
        probe = 0

        for (sn, ts) in ackList {
            var seg = Segment()
            seg.conv = conv; seg.cmd = Cmd.ack; seg.una = rcvNxt
            seg.wnd = UInt16(max(0, Int(rcvWnd) - rcvQueue.count))
            seg.sn = sn; seg.ts = ts
            output(encode(seg))
        }
        ackList.removeAll()

        while !sndQueue.isEmpty && writable()
            && diff(sndNxt, sndUna &+ sndWnd) < 0 {
            var seg = sndQueue.removeFirst()
            seg.conv = conv
            seg.cmd = Cmd.push
            seg.wnd = UInt16(max(0, Int(rcvWnd) - rcvQueue.count))
            seg.ts = current
            seg.sn = sndNxt
            seg.una = rcvNxt
            seg.resendts = current
            seg.rto = rxRto
            seg.fastack = 0
            seg.xmit = 0
            sndNxt = sndNxt &+ 1
            sndBuf.append(seg)
        }

        for i in sndBuf.indices {
            var needsend = false
            if sndBuf[i].xmit == 0 {
                needsend = true
                sndBuf[i].xmit += 1
                sndBuf[i].rto = rxRto
                sndBuf[i].resendts = current &+ rxRto &+ 1
            } else if diff(current, sndBuf[i].resendts) >= 0 {
                needsend = true
                sndBuf[i].xmit += 1
                sndBuf[i].rto = sndBuf[i].rto &+ max(sndBuf[i].rto, rxRto)
                sndBuf[i].resendts = current &+ sndBuf[i].rto
                lost = true
                retransmits += 1
            } else if sndBuf[i].fastack >= fastresend && diff(current, sndBuf[i].resendts) > 0 {
                needsend = true
                sndBuf[i].xmit += 1
                sndBuf[i].fastack = 0
                sndBuf[i].resendts = current &+ sndBuf[i].rto
                lost = true
                retransmits += 1
            }
            sndBuf[i].fastack = 0
            if needsend {
                push(encode(sndBuf[i]))
                sentSegments += 1
                change = true
                if sndBuf[i].xmit >= deadLink { state = -1 }
            }
        }

        if change && nocwnd == 0 {
            if lost {
                ssthresh = max(cwnd / 2, 2)
                cwnd = ssthresh
                incr = ssthresh
            } else {
                cwnd = min(cwnd &+ 1, rmtWnd)
            }
        }
        if cwnd < 1 { cwnd = 1 }

        if !pending.isEmpty {
            output(pending)
        }
    }

    // MARK: 接收

    func input(_ data: Data) {
        guard data.count >= 24 else { return }
        var offset = 0
        var maxackSn: UInt32 = 0
        var maxack: UInt32 = 0
        var flag = false
        var prevUna = sndUna

        while offset + 24 <= data.count {
            let convIn = readU32(data, offset)
            let cmd = data[data.startIndex + offset + 4]
            let frg = data[data.startIndex + offset + 5]
            let wnd = UInt16(readU16(data, offset + 6))
            let ts = readU32(data, offset + 8)
            let sn = readU32(data, offset + 12)
            let una = readU32(data, offset + 16)
            let len = Int(readU32(data, offset + 20))
            offset += 24
            guard convIn == conv, offset + len <= data.count else { return }
            recvSegments += 1

            if cmd == Cmd.ack {
                if diff(current, ts) >= 0 {
                    updateAck(Int(diff(current, ts)))
                }
                if !flag {
                    flag = true; maxack = ts; maxackSn = sn
                } else if diff(sn, maxackSn) > 0 {
                    maxackSn = sn; maxack = ts
                }
            } else if cmd == Cmd.push {
                if diff(sn, rcvNxt &+ rcvWnd) < 0 {
                    ackList.append((sn, ts))
                    if diff(sn, rcvNxt) >= 0 {
                        var seg = Segment()
                        seg.conv = convIn; seg.cmd = cmd; seg.frg = frg
                        seg.wnd = wnd; seg.ts = ts; seg.sn = sn; seg.una = una
                        let start = data.startIndex + offset
                        seg.data = data[start..<start + len]
                        recvBytes += len
                        parseData(seg)
                    }
                }
            } else if cmd == Cmd.wask {
                probe |= 1
            } else if cmd == Cmd.wins {
                // 无需处理
            } else {
                return
            }
            offset += len

            if diff(una, sndUna) > 0 {
                rmtWnd = UInt32(wnd)
                moveUna(una)
            }
        }

        if flag {
            parseFastack(maxackSn, maxack)
        }
        if diff(sndUna, prevUna) > 0, rmtWnd > 0 {
            _ = prevUna
        }
    }

    private func updateAck(_ rtt: Int) {
        let r = UInt32(max(0, rtt))
        if rxSrtt == 0 {
            rxSrtt = r
            rxRttval = r / 2
        } else {
            let delta = r > rxSrtt ? r - rxSrtt : rxSrtt - r
            rxRttval = (3 * rxRttval + delta) / 4
            rxSrtt = (7 * rxSrtt + r) / 8
            if rxSrtt < 1 { rxSrtt = 1 }
        }
        let rto = rxSrtt &+ max(interval, 4 * rxRttval)
        rxRto = min(max(rxMinrto, rto), 60000)
    }

    private func moveUna(_ una: UInt32) {
        while let first = sndBuf.first, diff(una, first.sn) > 0 {
            sndBuf.removeFirst()
        }
        sndUna = sndBuf.first?.sn ?? sndNxt
    }

    private func parseFastack(_ sn: UInt32, _ ts: UInt32) {
        if diff(sn, sndUna) < 0 || diff(sn, sndNxt) >= 0 { return }
        for i in sndBuf.indices {
            if diff(sn, sndBuf[i].sn) < 0 { break }
            if sn != sndBuf[i].sn && diff(sndBuf[i].ts, ts) <= 0 {
                sndBuf[i].fastack += 1
            }
        }
    }

    private func parseData(_ newseg: Segment) {
        let sn = newseg.sn
        if diff(sn, rcvNxt &+ rcvWnd) >= 0 || diff(sn, rcvNxt) < 0 { return }

        var insertAt = rcvBuf.count
        var repeatSeg = false
        for (i, seg) in rcvBuf.enumerated() {
            if seg.sn == sn { repeatSeg = true; break }
            if diff(sn, seg.sn) < 0 { insertAt = i; break }
            insertAt = i + 1
        }
        if !repeatSeg {
            rcvBuf.insert(newseg, at: insertAt)
        }
        while let first = rcvBuf.first, first.sn == rcvNxt,
              UInt32(rcvQueue.count) < rcvWnd {
            rcvQueue.append(first)
            rcvBuf.removeFirst()
            rcvNxt = rcvNxt &+ 1
        }
    }

    func recv() -> Data? {
        guard !rcvQueue.isEmpty else { return nil }
        let frg = rcvQueue[0].frg
        let need = Int(frg) + 1
        guard rcvQueue.count >= need else { return nil }
        var data = Data()
        for _ in 0..<need {
            data.append(rcvQueue.removeFirst().data)
        }
        return data
    }

    // MARK: 字节读取

    private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }
}
