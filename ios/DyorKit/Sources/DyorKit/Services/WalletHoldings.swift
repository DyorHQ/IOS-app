import BigInt
import Foundation

/// One token the wallet holds: its balance and, when a pool prices it, its dollar value. The Portfolio's Assets and
/// the Send sheet's list are both made of these, from the same read in the same order (`WalletHoldings.ranked`), so
/// the two can't drift.
public struct HeldToken: Hashable, Sendable, Identifiable {
    public let token: Token
    public let balance: BigUInt
    /// USD per whole token; nil when no pool prices it.
    public let usd: Double?
    /// Reached the wallet without being chosen in the app (sent, airdropped): its name and symbol prove nothing, so it
    /// is marked Unverified wherever it is listed (security audit 2026-09-26, IOST-12).
    public let unverified: Bool

    public init(token: Token, balance: BigUInt, usd: Double?, unverified: Bool = false) {
        self.token = token
        self.balance = balance
        self.usd = usd
        self.unverified = unverified
    }

    public var id: Address { token.address }
    /// Whole tokens held.
    public var units: Double { Amount.units(balance, decimals: token.decimals) }
    /// Dollar value: nil when the price is unknown, never $0 in its place.
    public var value: Double? {
        guard let usd else { return nil }
        let value = units * usd
        return value.isFinite ? value : nil
    }
}

/// Which tokens the wallet holds, in what order, and which one a send starts on. Pure, so it is tested here; the app
/// reads the balances and prices it works on (`WalletTokens`).
public enum WalletHoldings {
    /// The tokens of `universe` the wallet holds — a balance above zero — each once, in `universe` order. A token whose
    /// balance is missing (its read failed) is left out, as it always was on the Portfolio.
    public static func held(_ universe: [Token], balances: [Address: BigUInt]) -> [Token] {
        var seen = Set<Address>()
        return universe.filter { (balances[$0.address] ?? 0) > 0 && seen.insert($0.address).inserted }
    }

    /// `tokens` with their balances and prices (USD per whole token), ranked by `precedes`. Tokens with no balance are
    /// left out here too.
    public static func ranked(_ tokens: [Token], balances: [Address: BigUInt], prices: [Address: Double], unverified: Set<Address>) -> [HeldToken] {
        held(tokens, balances: balances)
            .map { HeldToken(token: $0, balance: balances[$0.address] ?? 0, usd: prices[$0.address], unverified: unverified.contains($0.address)) }
            .sorted(by: precedes)
    }

    /// The order every list of held tokens uses:
    /// 1. dollar value, highest first; every token with no price comes after every priced one, never ranked as $0;
    /// 2. then tokens the user chose before Unverified ones;
    /// 3. then the larger amount held (whole tokens);
    /// 4. then symbol A–Z, ignoring case, then contract address — so the order never depends on the order of the reads.
    public static func precedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        switch (a.value, b.value) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.unverified != b.unverified { return !a.unverified }
        if a.units != b.units { return a.units > b.units }
        switch a.token.symbol.compare(b.token.symbol, options: .caseInsensitive) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.token.address.hex < b.token.address.hex
        }
    }

    /// The asset a send starts on: the highest-ranked one the user chose. Never an Unverified token — a fake "USDC"
    /// with a seeded pool can outrank everything — so when every held token is Unverified, or nothing is held, there is
    /// none and the user picks.
    public static func defaultChoice(_ ranked: [HeldToken]) -> HeldToken? {
        ranked.first { !$0.unverified }
    }

    /// After the list is read again: `current` while the wallet still holds it, otherwise the default choice.
    public static func selection(keeping current: Address?, in ranked: [HeldToken]) -> HeldToken? {
        if let current, let kept = ranked.first(where: { $0.id == current }) { return kept }
        return defaultChoice(ranked)
    }

    /// The held tokens a search matches, in `held` order: a pasted address matches that contract only; other text
    /// matches the symbol or name, or — starting with 0x — the start of the contract address.
    public static func matching(_ held: [HeldToken], query: String) -> [HeldToken] {
        let text = Address.cleanedInput(query).text
        guard !text.isEmpty else { return held }
        if let address = Address(text) { return held.filter { $0.token.address == address } }
        let hex = text.lowercased()
        return held.filter { item in
            item.token.symbol.localizedCaseInsensitiveContains(text) || item.token.name.localizedCaseInsensitiveContains(text)
                || (hex.hasPrefix("0x") && hex.count >= 4 && item.token.address.hex.hasPrefix(hex))
        }
    }

    /// The curated dollar stables, by contract address. A token is one of them only by its address: anyone can deploy a
    /// token called "USDC".
    public static let dollarStables: Set<Address> = Set(Token.core.filter { ["USDC", "USDT0", "AUSD", "USDe", "USD1", "mUSD"].contains($0.symbol) }.map(\.address))

    /// `amount` in dollars when `token` is one of the curated dollar stables; nil for any other token, whatever its
    /// symbol.
    public static func stableUSD(_ token: Token, amount: BigUInt) -> Double? {
        dollarStables.contains(token.address) ? Amount.units(amount, decimals: token.decimals) : nil
    }
}
