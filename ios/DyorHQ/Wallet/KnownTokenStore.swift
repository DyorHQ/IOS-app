import DyorKit
import Foundation

/// Remembers tokens the user has acquired but that aren't in the curated list — anything swapped into or launched —
/// so they still appear in holdings and the swap picker with a price. Persisted per wallet address in UserDefaults;
/// only public token metadata (address/symbol/name/decimals/logo) is stored, never balances or keys.
enum KnownTokenStore {
    private static func key(_ owner: Address) -> String { "knownTokens.\(owner.hex)" }

    static func all(owner: Address?) -> [Token] {
        guard let owner, let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([Token].self, from: data)) ?? []
    }

    /// Records a token the wallet now holds. No-ops for native MON and anything already curated or stored.
    static func add(_ token: Token, owner: Address?) {
        guard let owner, !token.isNative, Token.core(token.address) == nil else { return }
        var list = all(owner: owner)
        guard !list.contains(where: { $0.address == token.address }) else { return }
        list.append(token)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    /// The full token universe for a wallet: the curated list plus everything it has acquired, de-duplicated.
    static func universe(owner: Address?) -> [Token] {
        var seen = Set(Token.core.map(\.address))
        var out = Token.core
        for token in all(owner: owner) where seen.insert(token.address).inserted { out.append(token) }
        return out
    }
}
