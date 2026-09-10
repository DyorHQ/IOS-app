import DyorKit
import Foundation

/// A global (not per-wallet) cache of tokens that trade on Monad's venues — Uniswap and Monday Trade — refreshed in
/// the background at most once a day. It feeds the swap picker's browse list so any real Monad asset is one tap away
/// with its accurate symbol and logo, without reading balances for hundreds of tokens on every home load.
enum VenueTokenStore {
    private static let key = "venueTokens.v1"
    private static let stampKey = "venueTokens.v1.updatedAt"
    private static let ttl: TimeInterval = 86_400

    static func all() -> [Token] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Token].self, from: data)) ?? []
    }

    /// True when the cache is empty or older than a day, so the caller refreshes it.
    static func isStale() -> Bool {
        guard UserDefaults.standard.data(forKey: key) != nil else { return true }
        return Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: stampKey) > ttl
    }

    static func save(_ tokens: [Token]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(tokens), forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)
    }
}
