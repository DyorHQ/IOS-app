import Foundation

/// The mark a token carries where it is listed: where it came from, or a warning. It changes only what a row shows:
/// which tokens are Unverified (received, not chosen in the app) stays `HeldToken.unverified` and
/// `KnownTokenStore.unverified`, so a send's default (`WalletHoldings.defaultChoice`), the list order (`precedes`), Top
/// Tokens, "funds arriving" and the Swap picker's main list treat a DyorHQ coin sent to the wallet exactly as before
/// (security audit 2026-09-26, IOST-12).
public enum TokenBadge: Hashable, Sendable {
    /// Nothing to say: MON, a curated token, or a token the user chose that is none of the below.
    case none
    /// A DyorHQ launchpad's coin (`DyorCoinRegistry`), live or retired.
    case dyorLaunch
    /// A DyorHQ Moment's coin, of any cohort.
    case dyorMoment
    /// Sent to the wallet unasked, or with a symbol that isn't display-safe: its name proves nothing.
    case unverified
    /// It reads as this curated token without being it.
    case imitates(Token)

    /// The badge `token` shows, `coin` being its DyorHQ registry entry when it has one (an entry for another address is
    /// ignored) and `receivedUnasked` whether it reached the wallet without being chosen in the app. In order:
    /// 1. MON and the curated tokens: none;
    /// 2. a look-alike of a curated token, by its own name or symbol or its coin's: the imitation warning, whatever made
    ///    it — a DyorHQ launch called "USDC" included;
    /// 3. a symbol, its own or its coin's, that isn't display-safe (`SymbolSafety.isDisplaySafe`): Unverified;
    /// 4. a DyorHQ coin: DyorHQ Launch or DyorHQ Moment, received or chosen — a Chinese, Japanese or Korean symbol included;
    /// 5. received unasked: Unverified;
    /// 6. otherwise none.
    /// A coin the registry can't tell yet (a read that failed) has no entry, and shows as it does today.
    public static func of(_ token: Token, coin: DyorCoin?, receivedUnasked: Bool) -> TokenBadge {
        if token.isNative || Token.core(token.address) != nil { return .none }
        let coin = coin.flatMap { $0.address == token.address ? $0 : nil }
        if let curated = imitation(token, coin: coin) { return .imitates(curated) }
        if !SymbolSafety.isDisplaySafe(token.symbol) || !(coin.map { SymbolSafety.isDisplaySafe($0.symbol) } ?? true) { return .unverified }
        if let coin { return coin.isMoment ? .dyorMoment : .dyorLaunch }
        return receivedUnasked ? .unverified : .none
    }

    /// The curated token `token` reads as, by its own symbol and name or, for a DyorHQ coin, by what its contract says
    /// (`WalletHoldings.imitated(by:)`); nil for MON, the curated tokens and every other name.
    static func imitation(_ token: Token, coin: DyorCoin?) -> Token? {
        if let curated = WalletHoldings.imitated(by: token) { return curated }
        guard let coin, coin.address == token.address else { return nil }
        return WalletHoldings.imitated(by: Token(address: token.address, symbol: coin.symbol, name: coin.name, decimals: token.decimals))
    }

    /// What the badge reads; nil for none.
    public var title: String? {
        switch self {
        case .none: return nil
        case .dyorLaunch: return "DyorHQ Launch"
        case .dyorMoment: return "DyorHQ Moment"
        case .unverified: return "Unverified"
        case .imitates(let curated): return "Not the \(curated.symbol) DyorHQ lists"
        }
    }

    /// A warning (Unverified or a look-alike), shown in the attention colour; the DyorHQ labels are facts, not warnings.
    public var isWarning: Bool {
        switch self {
        case .unverified, .imitates: return true
        case .none, .dyorLaunch, .dyorMoment: return false
        }
    }
}

public extension HeldToken {
    /// The badge this held token shows (`TokenBadge.of`), `coin` being its DyorHQ registry entry; `unverified` stays what
    /// the send default and the list order go by.
    func badge(_ coin: DyorCoin?) -> TokenBadge {
        TokenBadge.of(token, coin: coin, receivedUnasked: unverified)
    }
}
