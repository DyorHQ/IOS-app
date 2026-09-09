import Foundation

/// Keccak-256 as Ethereum uses it (the pre-standard padding 0x01…0x80, not SHA3's 0x06). Needed for
/// function selectors, EIP-55 checksums and Uniswap v4 pool ids; CryptoKit has no Keccak.
public enum Keccak {
    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    /// Rotation offsets indexed by lane `x + 5 * y`.
    private static let rotations: [Int] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    private static let rate = 136 // bytes, for a 256-bit digest

    public static func hash256(_ message: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        // Re-base into a fresh 0-indexed buffer: a `Data` slice (e.g. from `suffix`) keeps its parent's indices,
        // and the integer subscripting below assumes 0-based, so a slice would be padded and read incorrectly.
        var padded = Data(message)
        padded.append(0x01)
        while padded.count % rate != 0 { padded.append(0) }
        padded[padded.count - 1] |= 0x80

        padded.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < bytes.count {
                for lane in 0..<(rate / 8) {
                    var word: UInt64 = 0
                    for b in 0..<8 { word |= UInt64(bytes[offset + lane * 8 + b]) << (8 * UInt64(b)) }
                    state[lane] ^= word
                }
                permute(&state)
                offset += rate
            }
        }

        var out = Data(capacity: 32)
        for lane in 0..<4 {
            var word = state[lane]
            for _ in 0..<8 {
                out.append(UInt8(word & 0xFF))
                word >>= 8
            }
        }
        return out
    }

    public static func hash256(_ string: String) -> Data { hash256(Data(string.utf8)) }

    @inline(__always) private static func rotl(_ v: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? v : (v << UInt64(n)) | (v >> UInt64(64 - n))
    }

    private static func permute(_ a: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)
        for round in 0..<24 {
            // θ
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
            // ρ and π
            for x in 0..<5 {
                for y in 0..<5 {
                    let nx = y
                    let ny = (2 * x + 3 * y) % 5
                    b[nx + 5 * ny] = rotl(a[x + 5 * y], rotations[x + 5 * y])
                }
            }
            // χ
            for y in 0..<5 {
                for x in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            // ι
            a[0] ^= roundConstants[round]
        }
    }
}
