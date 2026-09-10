import DyorKit
import Foundation

/// A global (not per-wallet) cache of tokens that trade on Monad's venues — Uniswap and Monday Trade — refreshed in
/// the background at most once a day. It feeds the swap picker's browse list so any real Monad asset is one tap away
/// with its accurate symbol and logo, without reading balances for hundreds of tokens on every home load.
enum VenueTokenStore {
    private static let key = "venueTokens.v1"
    private static let stampKey = "venueTokens.v1.updatedAt"
    private static let blockKey = "venueTokens.v1.lastBlock"
    private static let ttl: TimeInterval = 86_400

    static func all() -> [Token] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Token].self, from: data)) ?? []
    }

    /// The last chain block scanned, so the next refresh only reads the new tail (0 = never scanned → full history).
    static func lastBlock() -> UInt64 { UInt64(UserDefaults.standard.string(forKey: blockKey) ?? "") ?? 0 }

    /// True when the cache is older than a day, so the caller scans the new tail.
    static func isStale() -> Bool {
        Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: stampKey) > ttl
    }

    static func save(_ tokens: [Token], lastBlock: UInt64) {
        UserDefaults.standard.set(try? JSONEncoder().encode(tokens), forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)
        UserDefaults.standard.set(String(lastBlock), forKey: blockKey)
    }
}
