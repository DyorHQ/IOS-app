import BigInt
import Foundation

/// One token the wallet holds: its balance and, when a pool prices it, its dollar value. The Portfolio's Assets and
/// the Send sheet's list are both made of these, from the same read (`WalletHoldings.ranked`), so the two hold the same
/// tokens and can't drift; each keeps its own order.
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
    /// The curated token this one could pass for, by its symbol or name (`WalletHoldings.imitated(by:)`); nil for the
    /// curated tokens and anything named otherwise.
    public var imitates: Token? { WalletHoldings.imitated(by: token) }
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

    /// `tokens` with their balances and prices (USD per whole token), ranked by `order`: the Send list's (`precedes`)
    /// unless another is given (the Portfolio's, `portfolioPrecedes`). Tokens with no balance are left out here too.
    public static func ranked(_ tokens: [Token], balances: [Address: BigUInt], prices: [Address: Double], unverified: Set<Address>,
                              by order: (HeldToken, HeldToken) -> Bool = precedes) -> [HeldToken] {
        held(tokens, balances: balances)
            .map { HeldToken(token: $0, balance: balances[$0.address] ?? 0, usd: prices[$0.address], unverified: unverified.contains($0.address)) }
            .sorted(by: order)
    }

    /// The order the Portfolio's Assets has always used, unchanged: dollar value, highest first, a token with no price
    /// counted as $0, then the larger amount held.
    public static func portfolioPrecedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        (a.value ?? 0, a.units) > (b.value ?? 0, b.units)
    }

    /// The Send list's order:
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
    /// with a seeded pool can outrank everything — nor one carrying a curated token's name (`imitates`), even one the
    /// user tapped in Swap: it may be a look-alike, and a send must never start on it unasked. So when every held token
    /// is one of those, or nothing is held, there is none and the user picks. None either when the prices couldn't be read (`pricesRead` false): the ranking is then
    /// by amount, not value, and the token with the most units is not the one worth the most.
    public static func defaultChoice(_ ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard pricesRead else { return nil }
        return ranked.first { !$0.unverified && $0.imitates == nil }
    }

    /// After the list is read: with nothing chosen yet, the default choice; with a choice, that token while the wallet
    /// still holds it, and none once it doesn't — the user picks again, rather than a send switching to another asset
    /// under an amount already typed.
    public static func selection(keeping current: Address?, in ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard let current else { return defaultChoice(ranked, pricesRead: pricesRead) }
        return ranked.first { $0.id == current }
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

    /// `prices` (USD per whole token, from the pool finder) with DyorHQ's own coins valued as the app values them, which
    /// the pool finder can't: a launch coin (`launches`, found by its factory's record) at its live price in its pair
    /// asset (`HeldLaunches.pairPerCoin`: its curve's, or its pool's once graduated) times that asset's dollar price in
    /// `prices`; a Moment coin (`moments`) at its pool's live USDC price (`momentPrice`). Such a coin is never valued at a
    /// price another pool quotes for it: without the app's own value (a launch or price that couldn't be read, a pair
    /// asset with no price, a Moment whose pool wasn't read) it is unpriced.
    public static func pricing(_ prices: [Address: Double], launches: HeldLaunches, moments: [Address: Double?]) -> [Address: Double] {
        var out = prices
        for (coin, pair) in launches.pairAssets {
            // MON's price is under its address, 0 — the pair asset a native launch records.
            let usd = launches.pairPerCoin[coin].flatMap { perCoin in prices[pair].map { perCoin * $0 } }
            out[coin] = usd.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        for (coin, usdcPerCoin) in moments { out[coin] = usdcPerCoin }
        return out
    }

    /// A Moment coin's dollar price for `pricing`: its pool's USDC price as read live. Nil when that read failed — never
    /// the pool's opening price in its place — or the Moment has no pool.
    public static func momentPrice(_ info: MomentInfo) -> Double? {
        guard let pool = info.pool, pool.livePriceRead, pool.usdcPerCoin.isFinite, pool.usdcPerCoin > 0 else { return nil }
        return pool.usdcPerCoin
    }

    /// The DyorHQ coins that are `owner`'s own: a launch coin it launched (its factory records the wallet as deployer —
    /// the factory's caller, or the launch router's, never an argument) and a Moment coin whose Moment it collected or
    /// created (`staked`: a stake in the Moment's vesting). The factories name each coin by its address, so no look-alike
    /// passes for one; a coin that was only sent to the wallet is not its own.
    public static func ownCoins(owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        Set(launches.deployers.filter { $0.value == owner }.keys).union(staked)
    }

    /// `unverified` without the DyorHQ coins that are `owner`'s own (`ownCoins`): a coin that was only sent to the wallet
    /// stays Unverified.
    public static func unverified(_ unverified: Set<Address>, owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        unverified.subtracting(ownCoins(owner: owner, launches: launches, staked: staked))
    }

    /// The curated token `token` could pass for: `token` is not curated, yet its symbol or name is a curated token's
    /// symbol or name, ignoring case, accents, width and spaces — a second "USDC", a "Monad" that isn't MON. Being
    /// chosen proves nothing here: tapping a search result in Swap stores a token as chosen. Nil for MON, the curated
    /// tokens and every other name.
    public static func imitated(by token: Token) -> Token? {
        guard !token.isNative, Token.core(token.address) == nil else { return nil }
        let names = [folded(token.symbol), folded(token.name)].filter { !$0.isEmpty }
        return Token.core.first { curated in names.contains(folded(curated.symbol)) || names.contains(folded(curated.name)) }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).filter { !$0.isWhitespace }
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
