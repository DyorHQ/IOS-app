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

    private static let rate = 136 // bytes, for a 256-bit digest

    public static func hash256(_ message: Data) -> Data {
        var state = zero
        // `withUnsafeBytes` reads a `Data` slice (e.g. from `suffix`) from its own first byte, whatever its parent's
        // indices, so a slice hashes the same as a copy of it.
        message.withUnsafeBytes { raw in
            let whole = raw.count - raw.count % rate
            absorb(UnsafeRawBufferPointer(rebasing: raw[..<whole]), into: &state)
            absorbPadded(UnsafeRawBufferPointer(rebasing: raw[whole...]), into: &state)
        }
        return squeeze(state)
    }

    /// The keccak-256 of a file's bytes, read a megabyte at a time so a large file (a picked video) is never held in
    /// memory whole. Equal to `hash256(Data(contentsOf: file))`.
    public static func hash256(file: URL) throws -> Data { try hash256(file: file, chunkSize: 1 << 20) }

    static func hash256(file: URL, chunkSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var state = zero
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            let whole = pending.count - pending.count % rate
            guard whole > 0 else { continue }
            pending.withUnsafeBytes { absorb(UnsafeRawBufferPointer(rebasing: $0[..<whole]), into: &state) }
            pending = Data(pending.dropFirst(whole))
        }
        pending.withUnsafeBytes { absorbPadded($0, into: &state) }
        return squeeze(state)
    }

    /// The 25 lanes of the Keccak-f[1600] state, `x + 5 * y`, held inline so a permutation allocates nothing.
    private typealias State = (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                               UInt64, UInt64, UInt64, UInt64, UInt64)

    private static let zero: State = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// Absorbs the message's last bytes (fewer than `rate`) with Ethereum's keccak padding (0x01 … 0x80): one block,
    /// built on the stack.
    private static func absorbPadded(_ tail: UnsafeRawBufferPointer, into state: inout State) {
        withUnsafeTemporaryAllocation(byteCount: rate, alignment: 8) { block in
            block.initializeMemory(as: UInt8.self, repeating: 0)
            block.copyMemory(from: tail)
            block[tail.count] = 0x01
            block[rate - 1] |= 0x80
            absorb(UnsafeRawBufferPointer(block), into: &state)
        }
    }

    /// XORs the whole `rate`-byte blocks of `bytes` into the state, permuting after each.
    private static func absorb(_ bytes: UnsafeRawBufferPointer, into state: inout State) {
        withUnsafeMutableBytes(of: &state) { raw in
            let lanes = raw.baseAddress!.assumingMemoryBound(to: UInt64.self)
            var offset = 0
            while offset + rate <= bytes.count {
                for lane in 0..<(rate / 8) {
                    lanes[lane] ^= UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + lane * 8, as: UInt64.self))
                }
                permute(lanes)
                offset += rate
            }
        }
    }

    /// The digest: the first four lanes, each least significant byte first.
    private static func squeeze(_ state: State) -> Data {
        var digest = (state.0.littleEndian, state.1.littleEndian, state.2.littleEndian, state.3.littleEndian)
        return withUnsafeBytes(of: &digest) { Data($0) }
    }

    public static func hash256(_ string: String) -> Data { hash256(Data(string.utf8)) }

    @inline(__always) private static func rotl(_ v: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? v : (v << UInt64(n)) | (v >> UInt64(64 - n))
    }

    /// Keccak-f[1600] on the 25 lanes at `a`, in place: θ, ρ and π, χ and ι for each of the 24 rounds.
    private static func permute(_ a: UnsafeMutablePointer<UInt64>) {
        var a00 = a[0], a10 = a[1], a20 = a[2], a30 = a[3], a40 = a[4]
        var a01 = a[5], a11 = a[6], a21 = a[7], a31 = a[8], a41 = a[9]
        var a02 = a[10], a12 = a[11], a22 = a[12], a32 = a[13], a42 = a[14]
        var a03 = a[15], a13 = a[16], a23 = a[17], a33 = a[18], a43 = a[19]
        var a04 = a[20], a14 = a[21], a24 = a[22], a34 = a[23], a44 = a[24]
        for round in 0..<24 {
            // θ
            let c0 = a00 ^ a01 ^ a02 ^ a03 ^ a04
            let c1 = a10 ^ a11 ^ a12 ^ a13 ^ a14
            let c2 = a20 ^ a21 ^ a22 ^ a23 ^ a24
            let c3 = a30 ^ a31 ^ a32 ^ a33 ^ a34
            let c4 = a40 ^ a41 ^ a42 ^ a43 ^ a44
            let d0 = c4 ^ rotl(c1, 1), d1 = c0 ^ rotl(c2, 1), d2 = c1 ^ rotl(c3, 1), d3 = c2 ^ rotl(c4, 1), d4 = c3 ^ rotl(c0, 1)
            a00 ^= d0; a01 ^= d0; a02 ^= d0; a03 ^= d0; a04 ^= d0
            a10 ^= d1; a11 ^= d1; a12 ^= d1; a13 ^= d1; a14 ^= d1
            a20 ^= d2; a21 ^= d2; a22 ^= d2; a23 ^= d2; a24 ^= d2
            a30 ^= d3; a31 ^= d3; a32 ^= d3; a33 ^= d3; a34 ^= d3
            a40 ^= d4; a41 ^= d4; a42 ^= d4; a43 ^= d4; a44 ^= d4
            // ρ and π: lane (x, y) rotated by its offset moves to (y, 2x + 3y); `bxy` is the lane that lands at (x, y).
            let b00 = a00
            let b02 = rotl(a10, 1), b04 = rotl(a20, 62), b01 = rotl(a30, 28), b03 = rotl(a40, 27)
            let b13 = rotl(a01, 36), b10 = rotl(a11, 44), b12 = rotl(a21, 6), b14 = rotl(a31, 55), b11 = rotl(a41, 20)
            let b21 = rotl(a02, 3), b23 = rotl(a12, 10), b20 = rotl(a22, 43), b22 = rotl(a32, 25), b24 = rotl(a42, 39)
            let b34 = rotl(a03, 41), b31 = rotl(a13, 45), b33 = rotl(a23, 15), b30 = rotl(a33, 21), b32 = rotl(a43, 8)
            let b42 = rotl(a04, 18), b44 = rotl(a14, 2), b41 = rotl(a24, 61), b43 = rotl(a34, 56), b40 = rotl(a44, 14)
            // χ
            a00 = b00 ^ (~b10 & b20); a10 = b10 ^ (~b20 & b30); a20 = b20 ^ (~b30 & b40); a30 = b30 ^ (~b40 & b00); a40 = b40 ^ (~b00 & b10)
            a01 = b01 ^ (~b11 & b21); a11 = b11 ^ (~b21 & b31); a21 = b21 ^ (~b31 & b41); a31 = b31 ^ (~b41 & b01); a41 = b41 ^ (~b01 & b11)
            a02 = b02 ^ (~b12 & b22); a12 = b12 ^ (~b22 & b32); a22 = b22 ^ (~b32 & b42); a32 = b32 ^ (~b42 & b02); a42 = b42 ^ (~b02 & b12)
            a03 = b03 ^ (~b13 & b23); a13 = b13 ^ (~b23 & b33); a23 = b23 ^ (~b33 & b43); a33 = b33 ^ (~b43 & b03); a43 = b43 ^ (~b03 & b13)
            a04 = b04 ^ (~b14 & b24); a14 = b14 ^ (~b24 & b34); a24 = b24 ^ (~b34 & b44); a34 = b34 ^ (~b44 & b04); a44 = b44 ^ (~b04 & b14)
            // ι
            a00 ^= roundConstants[round]
        }
        a[0] = a00; a[1] = a10; a[2] = a20; a[3] = a30; a[4] = a40
        a[5] = a01; a[6] = a11; a[7] = a21; a[8] = a31; a[9] = a41
        a[10] = a02; a[11] = a12; a[12] = a22; a[13] = a32; a[14] = a42
        a[15] = a03; a[16] = a13; a[17] = a23; a[18] = a33; a[19] = a43
        a[20] = a04; a[21] = a14; a[22] = a24; a[23] = a34; a[24] = a44
    }
}
