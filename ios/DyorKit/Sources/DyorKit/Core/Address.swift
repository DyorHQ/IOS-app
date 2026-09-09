import Foundation

/// A 20-byte Ethereum address. Equality is byte-wise, so case differences never matter.
public struct Address: Hashable, Sendable, Codable, CustomStringConvertible {
    public let data: Data

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42, trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X"), let bytes = Data(hex: trimmed), bytes.count == 20 else { return nil }
        data = bytes
    }

    public init?(data: Data) {
        guard data.count == 20 else { return nil }
        self.data = data
    }

    /// For addresses that are known constants in source; traps on a typo so it cannot ship.
    public init(literal: String) {
        guard let address = Address(literal) else { preconditionFailure("Invalid address literal \(literal)") }
        self = address
    }

    public static let zero = Address(data: Data(repeating: 0, count: 20))!

    public var isZero: Bool { data.allSatisfy { $0 == 0 } }

    /// Lowercase `0x…`.
    public var hex: String { data.hexString }

    /// EIP-55 mixed-case checksum form, what users should see and copy.
    public var checksummed: String {
        let lower = data.map { String(format: "%02x", $0) }.joined()
        let hash = Keccak.hash256(lower)
        var out = "0x"
        for (i, ch) in lower.enumerated() {
            let nibble = (hash[i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0xF
            out.append(nibble >= 8 ? ch.uppercased() : String(ch))
        }
        return out
    }

    /// `0x1234…abcd`, for rows and titles.
    public var short: String {
        let s = checksummed
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    public var description: String { checksummed }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let address = Address(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid address \(string)"))
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checksummed)
    }
}
