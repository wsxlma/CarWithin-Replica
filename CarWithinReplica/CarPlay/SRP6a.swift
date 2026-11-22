import Foundation
import CryptoKit

/// SRP-6a（RFC 5054，3072 位组）：AirPlay / HomeKit 配对用的密钥协商。
/// 用户名固定 "Pair-Setup"，口令由 MFi 身份派生。
enum SRP6a {
    /// RFC 5054 附录 A 的 3072 位素数。
    static let modulusHex = """
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
    """
    static let generator = BigUInt(5)
    static let username = Data("Pair-Setup".utf8)

    static let N: BigUInt = {
        guard let value = BigUInt(hex: modulusHex) else {
            preconditionFailure("SRP 模数解析失败")
        }
        return value
    }()

    static var padWidth: Int { N.bytes.count }

    static func pad(_ value: BigUInt) -> Data {
        value.bytes(width: padWidth)
    }

    static func hash(_ parts: Data...) -> Data {
        var combined = Data()
        for part in parts { combined.append(part) }
        return Data(SHA512.hash(data: combined))
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// k = H(N | PAD(g))
    static var multiplier: BigUInt {
        let digest = hash(pad(N), pad(generator))
        return BigUInt(bytes: [UInt8](digest))
    }

    /// x = H(s | H(I | ":" | P))
    static func privateKey(salt: Data, password: Data) -> BigUInt {
        var inner = Data()
        inner.append(username)
        inner.append(Data(":".utf8))
        inner.append(password)
        let innerHash = Data(SHA512.hash(data: inner))
        let digest = hash(salt, innerHash)
        return BigUInt(bytes: [UInt8](digest))
    }

    /// v = g^x mod N
    static func verifier(x: BigUInt) -> BigUInt {
        generator.modExp(x, modulus: N)
    }

    /// B = (k*v + g^b) mod N
    static func publicValue(v: BigUInt, b: BigUInt) -> BigUInt {
        let gv = generator.modExp(b, modulus: N)
        let kv = (multiplier * v).mod(N)
        return (kv + gv).mod(N)
    }

    /// u = H(PAD(A) | PAD(B))
    static func scrambling(a: BigUInt, b: BigUInt) -> BigUInt {
        let digest = hash(pad(a), pad(b))
        return BigUInt(bytes: [UInt8](digest))
    }

    /// S = (A * v^u)^b mod N
    static func sharedSecret(a: BigUInt, v: BigUInt, b: BigUInt, u: BigUInt) -> BigUInt {
        let vu = v.modExp(u, modulus: N)
        let base = (a * vu).mod(N)
        return base.modExp(b, modulus: N)
    }

    /// K = H(S)，这里按字节宽度补齐后取 SHA-512。
    static func sessionKey(_ s: BigUInt) -> Data {
        Data(SHA512.hash(data: pad(s)))
    }

    /// M1 = H( H(N) xor H(g) | H(I) | s | A | B | K )
    static func clientProof(salt: Data, a: BigUInt, b: BigUInt, k: Data) -> Data {
        let nHash = Data(SHA512.hash(data: pad(N)))
        let gHash = Data(SHA512.hash(data: pad(generator)))
        var xor = Data(repeating: 0, count: nHash.count)
        for index in 0..<nHash.count {
            xor[xor.startIndex + index] = nHash[nHash.startIndex + index] ^ gHash[gHash.startIndex + index]
        }
        let iHash = Data(SHA512.hash(data: username))
        return hash(xor, iHash, salt, pad(a), pad(b), k)
    }

    /// M2 = H( A | M1 | K )
    static func serverProof(a: BigUInt, m1: Data, k: Data) -> Data {
        hash(pad(a), m1, k)
    }
}
