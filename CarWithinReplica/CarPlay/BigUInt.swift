import Foundation

/// 大无符号整数，用于 SRP-6a 的 3072 位模运算。
/// 小端 limb 数组，实现加减乘、模、模幂。
struct BigUInt: Comparable, Equatable {
    var limbs: [UInt64]

    init() { limbs = [] }
    init(_ value: UInt64) { limbs = value == 0 ? [] : [value] }

    init?(hex: String) {
        var text = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if text.hasPrefix("0x") { text.removeFirst(2) }
        var bytes = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            let piece = text[index..<next]
            guard let byte = UInt8(piece, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes: bytes)
    }

    init(bytes: [UInt8]) {
        limbs = []
        var value: UInt64 = 0
        for (offset, byte) in bytes.reversed().enumerated() {
            value |= UInt64(byte) << (8 * (offset % 8))
            if offset % 8 == 7 {
                limbs.append(value)
                value = 0
            }
        }
        if value != 0 { limbs.append(value) }
        trim()
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    mutating func trim() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var index = count - 1
        while index >= 0 {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            if a != b { return a < b }
            index -= 1
        }
        return false
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        for index in 0..<count {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            if a != b { return false }
        }
        return true
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt64](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            result[index] = sum2
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        if carry != 0 { result[count] = carry }
        var value = BigUInt()
        value.limbs = result
        value.trim()
        return value
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for index in 0..<lhs.limbs.count {
            let a = lhs.limbs[index]
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            result[index] = diff2
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        var value = BigUInt()
        value.limbs = result
        value.trim()
        return value
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let product = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                var sumLow: UInt64 = 0
                var overflow = false
                (sumLow, overflow) = product.low.addingReportingOverflow(result[i + j])
                var overflow2 = false
                (sumLow, overflow2) = sumLow.addingReportingOverflow(carry)
                result[i + j] = sumLow
                carry = product.high &+ (overflow ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            var k = i + rhs.limbs.count
            while carry != 0 {
                let (next, overflow) = result[k].addingReportingOverflow(carry)
                result[k] = next
                carry = overflow ? 1 : 0
                k += 1
            }
        }
        var value = BigUInt()
        value.limbs = result
        value.trim()
        return value
    }

    /// 取模：二进制长除，慢但简单可靠。
    func mod(_ divisor: BigUInt) -> BigUInt {
        precondition(!divisor.isZero, "模数不能为 0")
        if self < divisor { return self }
        var remainder = BigUInt()
        var index = bitWidth - 1
        while index >= 0 {
            remainder = remainder.shiftLeft(1)
            if bit(index) {
                if remainder.limbs.isEmpty {
                    remainder.limbs = [1]
                } else {
                    remainder.limbs[0] |= 1
                }
            }
            if !(remainder < divisor) {
                remainder = remainder - divisor
            }
            index -= 1
        }
        return remainder
    }

    func modExp(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        if modulus == BigUInt(1) { return BigUInt() }
        var result = BigUInt(1)
        var base = self.mod(modulus)
        var exp = exponent
        while !exp.isZero {
            if exp.bit(0) {
                result = (result * base).mod(modulus)
            }
            base = (base * base).mod(modulus)
            exp = exp.shiftRight(1)
        }
        return result
    }

    func bit(_ index: Int) -> Bool {
        let limbIndex = index / 64
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> (index % 64)) & 1 == 1
    }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    func shiftLeft(_ count: Int) -> BigUInt {
        guard count > 0, !isZero else { return self }
        let limbShift = count / 64
        let bitShift = count % 64
        var result = [UInt64](repeating: 0, count: limbs.count + limbShift + 1)
        for index in 0..<limbs.count {
            let value = limbs[index]
            result[index + limbShift] |= value << bitShift
            if bitShift != 0 {
                result[index + limbShift + 1] |= value >> (64 - bitShift)
            }
        }
        var big = BigUInt()
        big.limbs = result
        big.trim()
        return big
    }

    func shiftRight(_ count: Int) -> BigUInt {
        guard count > 0 else { return self }
        let limbShift = count / 64
        let bitShift = count % 64
        guard limbShift < limbs.count else { return BigUInt() }
        var result = [UInt64](repeating: 0, count: limbs.count - limbShift)
        for index in 0..<result.count {
            var value = limbs[index + limbShift] >> bitShift
            if bitShift != 0, index + limbShift + 1 < limbs.count {
                value |= limbs[index + limbShift + 1] << (64 - bitShift)
            }
            result[index] = value
        }
        var big = BigUInt()
        big.limbs = result
        big.trim()
        return big
    }

    /// 固定字节宽度的网络序输出。
    func bytes(width: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: width)
        for limbIndex in 0..<limbs.count {
            let value = limbs[limbIndex]
            for byteIndex in 0..<8 {
                let position = limbIndex * 8 + byteIndex
                guard position < width else { break }
                bytes[width - 1 - position] = UInt8((value >> (8 * byteIndex)) & 0xFF)
            }
        }
        return Data(bytes)
    }

    var bytes: Data {
        guard let last = limbs.last else { return Data([0]) }
        let count = (limbs.count - 1) * 8 + (8 - last.leadingZeroBitCount + 7) / 8
        return bytes(width: max(count, 1))
    }
}
