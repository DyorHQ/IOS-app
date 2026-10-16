import BigInt
import Foundation

public extension Data {
    /// Parses `0x`-prefixed or bare hex. Odd-length input is left-padded with a zero nibble, as JSON-RPC quantities are.
    init?(hex: String) {
        // Every hex string from a node is ASCII hex digits: those are read straight from their UTF-8 bytes. Anything else
        // (a sign, a space, a non-ASCII character) takes the general path below, which reads each pair as
        // `UInt8(_:radix:)` does, so what parses and what doesn't is the same either way.
        if let bytes = Data.asciiHex(hex) {
            self = bytes
            return
        }
        var s = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        if s.isEmpty {
            self.init()
            return
        }
        if s.count % 2 == 1 { s = "0" + s }
        var out = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    /// `hex` (with or without `0x`/`0X`) when every character after the prefix is an ASCII hex digit, read from its
    /// UTF-8 bytes; nil for anything else, which `init(hex:)` reads the general way.
    static func asciiHex(_ hex: String) -> Data? {
        var hex = hex
        return hex.withUTF8 { utf8 -> Data? in
            var start = 0
            if utf8.count >= 2, utf8[0] == UInt8(ascii: "0"), utf8[1] == UInt8(ascii: "x") || utf8[1] == UInt8(ascii: "X") { start = 2 }
            let digits = utf8.count - start
            guard digits > 0 else { return Data() }
            var out = Data(count: (digits + 1) / 2)
            let parsed = out.withUnsafeMutableBytes { raw -> Bool in
                let bytes = raw.bindMemory(to: UInt8.self)
                var input = start
                var output = 0
                // An odd count is read as if a "0" led it.
                if digits % 2 == 1 {
                    guard let low = nibble(utf8[input]) else { return false }
                    bytes[0] = low
                    input += 1
                    output = 1
                }
                while input < utf8.count {
                    guard let high = nibble(utf8[input]), let low = nibble(utf8[input + 1]) else { return false }
                    bytes[output] = high << 4 | low
                    input += 2
                    output += 1
                }
                return true
            }
            return parsed ? out : nil
        }
    }

    /// The value of one ASCII hex digit, or nil.
    @inline(__always) private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c &- UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c &- UInt8(ascii: "a") &+ 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c &- UInt8(ascii: "A") &+ 10
        default: return nil
        }
    }

    /// Lowercase `0x…` hex.
    var hexString: String { "0x" + lowercaseHexDigits }

    /// The bytes as lowercase hex digits, two per byte, with no prefix: what `String(format: "%02x")` gives for each
    /// byte, joined, written straight into the string's storage (identifiers, cache keys and every RPC parameter are
    /// built from it, many times a second while a list is on screen).
    var lowercaseHexDigits: String {
        guard !isEmpty else { return "" }
        return withUnsafeBytes { raw in
            String(unsafeUninitializedCapacity: raw.count * 2) { out in
                let digits: StaticString = "0123456789abcdef"
                let table = digits.utf8Start
                var i = 0
                for byte in raw {
                    out[i] = table[Int(byte >> 4)]
                    out[i + 1] = table[Int(byte & 0x0F)]
                    i += 2
                }
                return i
            }
        }
    }

    /// Left-pads with zeros to `count` bytes (no-op when already longer).
    func leftPadded(to count: Int) -> Data {
        self.count >= count ? self : Data(repeating: 0, count: count - self.count) + self
    }

    /// Right-pads with zeros up to the next multiple of `multiple`.
    func rightPadded(toMultipleOf multiple: Int) -> Data {
        let remainder = count % multiple
        return remainder == 0 ? self : self + Data(repeating: 0, count: multiple - remainder)
    }
}

public extension BigUInt {
    /// Parses a JSON-RPC quantity (`0x…`).
    init?(hexQuantity: String) {
        let s = hexQuantity.hasPrefix("0x") || hexQuantity.hasPrefix("0X") ? String(hexQuantity.dropFirst(2)) : hexQuantity
        if s.isEmpty {
            self = 0
            return
        }
        guard let value = BigUInt(s, radix: 16) else { return nil }
        self = value
    }

    /// Minimal `0x…` quantity encoding (no leading zeros), as JSON-RPC requires.
    var hexQuantity: String { "0x" + String(self, radix: 16) }

    /// Big-endian bytes, left-padded to 32.
    var word: Data { serialize().leftPadded(to: 32) }
}
