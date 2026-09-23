import BigInt
import Foundation

/// Asks every venue at once and ranks by output. MON ↔ WMON is a 1:1 wrap and never needs a venue.
public actor SwapEngine {
    public static let quoteVenues: [Venue] = [.kuru, .uniswap, .monday]
    /// Every venue is quoted independently with this budget, so a slow venue never hides the others.
    public static let quoteTimeout: TimeInterval = 20

    public let rpc: RPCClient
    private let kuru: KuruFlowClient
    private let uniswap: UniswapVenue
    private let monday: MondayVenue

    /// `launchpadFactories` enables routes through graduated launchpad pools on Uniswap v4 — the live factory plus any
    /// retired one with the current 17-field record; each token's pool key is read from its own factory. `moments`
    /// enables routes through graduated Moment pools (coin ↔ USDC, hooked, 1.5% all-in).
    public init(rpc: RPCClient, session: URLSession = .shared, launchpadFactories: [Address] = [], moments: MomentsAddresses? = nil) {
        self.rpc = rpc
        let multicall = Multicall(rpc: rpc)
        let v3 = V3Router(multicall: multicall)
        kuru = KuruFlowClient(session: session)
        uniswap = UniswapVenue(multicall: multicall, v3: v3, launchpadFactories: launchpadFactories, moments: moments)
        monday = MondayVenue(v3: v3)
    }

    public nonisolated static func isWrap(_ tokenIn: Token, _ tokenOut: Token) -> Bool {
        (tokenIn.isNative && tokenOut.address == Monad.wmon) || (tokenIn.address == Monad.wmon && tokenOut.isNative)
    }

    /// Every venue's answer, best output first, with a readable reason for each venue that gave none. A pair with a
    /// retired cohort's Moment coin on either side gets no quote from any venue, and no venue is even asked.
    public func quotes(for request: SwapRequest) async -> QuoteResult {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) {
            let reason = SwapMath.describe(closed)
            return QuoteResult(errors: Dictionary(uniqueKeysWithValues: Self.quoteVenues.map { ($0, reason) }))
        }
        guard Self.isQuotable(request) else { return QuoteResult() }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return QuoteResult(quotes: [Self.wrapQuote(request)]) }
        var outcomes: [Venue: Result<VenueQuote?, Error>] = [:]
        await withTaskGroup(of: (Venue, Result<VenueQuote?, Error>).self) { group in
            for venue in Self.quoteVenues {
                group.addTask {
                    do { return (venue, .success(try await self.quote(venue, for: request))) } catch { return (venue, .failure(error)) }
                }
            }
            for await (venue, outcome) in group { outcomes[venue] = outcome }
        }
        var quotes: [VenueQuote] = []
        var errors: [Venue: String] = [:]
        for venue in Self.quoteVenues {
            switch outcomes[venue] {
            case .success(let quote?)?: quotes.append(quote)
            case .failure(let error)?: errors[venue] = SwapMath.describe(error)
            default: errors[venue] = "No route for this pair."
            }
        }
        return QuoteResult(quotes: Self.rank(quotes), errors: errors)
    }

    /// One venue's quote, or nil when it has no route. Throws with a readable message on failure or timeout, and
    /// `SwapError.tradingClosed` — before any venue is asked — when a retired cohort's Moment coin is on either side.
    public func quote(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) { throw closed }
        guard Self.isQuotable(request) else { return nil }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return venue == .wrap ? Self.wrapQuote(request) : nil }
        if venue == .wrap { return nil }
        return try await Self.withTimeout(Self.quoteTimeout, venue: venue) {
            switch venue {
            case .kuru: return try await self.kuru.quote(request)
            case .uniswap: return try await self.uniswap.quote(request)
            case .monday: return try await self.monday.quote(request)
            case .wrap: return nil
            }
        }
    }

    // MARK: Past-cohort Moment coins

    /// The retired Moments cohorts' pool hooks: a route through one pays the retired platform wallet.
    static let retiredHooks = Set(MomentsAddresses.retiredMainnet.map(\.hook))

    /// Whether `token` may be traded in the app at all: false for a retired cohort's Moment coin, on every venue.
    public nonisolated static func isTradable(_ token: Token) -> Bool {
        !MomentsAddresses.isRetiredCoin(token.address)
    }

    /// `SwapError.tradingClosed` for a pair with a retired cohort's Moment coin on either side, or nil when it may trade.
    public nonisolated static func tradingClosed(_ tokenIn: Token, _ tokenOut: Token) -> SwapError? {
        [tokenIn, tokenOut].first { !isTradable($0) }.map { .tradingClosed($0.address) }
    }

    /// Whether Swap may open on this pair: every side that is set is tradable (an unset side keeps what Swap shows).
    /// `Router.openSwap` and Swap's hand-off both ask this, so a retired coin never becomes a side.
    public nonisolated static func isTradablePair(_ tokenIn: Token?, _ tokenOut: Token?) -> Bool {
        [tokenIn, tokenOut].allSatisfy { $0.map(isTradable) ?? true }
    }

    /// The last line under every venue: throws `tradingClosed` when any of `addresses` (a trade's sides, a route's path,
    /// a v4 pool's currencies or hook) is a retired cohort's coin or pool hook. The venues check before quoting and the
    /// router calldata builders check again before encoding.
    static func ensureTradable(_ addresses: [Address]) throws {
        if let closed = addresses.first(where: { MomentsAddresses.isRetiredCoin($0) || retiredHooks.contains($0) }) {
            throw SwapError.tradingClosed(closed)
        }
    }

    /// Every retired cohort's coin and pool hook, in a fixed order, for `ensureNoRetired(in:)`.
    static let retiredAddresses: [Address] = MomentsAddresses.retiredMainnetCoins.keys.sorted { $0.hex < $1.hex }
        + MomentsAddresses.retiredMainnet.map(\.hook)

    /// For calldata the app did not encode (Kuru Flow's is ready-made, so its route cannot be read): throws
    /// `tradingClosed` when a retired cohort's coin or hook appears anywhere in it. An address the calldata touches sits
    /// in it as 20 contiguous bytes (an ABI word's low 20 bytes, or a raw address in a packed path), so a route that
    /// hops through a retired pool is caught even for an ordinary pair. Best effort: a route that names a pool only by
    /// its id (a v4 PoolId hash) would not show the hook, which is why the sides are also checked before asking.
    static func ensureNoRetired(in calldata: Data) throws {
        if let hit = retiredAddresses.first(where: { calldata.range(of: $0.data) != nil }) {
            throw SwapError.tradingClosed(hit)
        }
    }

    // MARK: Helpers

    private static func isQuotable(_ request: SwapRequest) -> Bool {
        request.tokenIn.address != request.tokenOut.address && request.amountIn > 0
    }

    /// Best output first; ties keep venue order.
    static func rank(_ quotes: [VenueQuote]) -> [VenueQuote] {
        quotes.enumerated()
            .sorted { a, b in a.element.amountOut != b.element.amountOut ? a.element.amountOut > b.element.amountOut : a.offset < b.offset }
            .map(\.element)
    }

    static func wrapQuote(_ request: SwapRequest) -> VenueQuote {
        let wrapping = request.tokenIn.isNative
        let amount = request.amountIn
        return VenueQuote(venue: .wrap, amountOut: amount, minOut: amount, route: wrapping ? "Wrap MON → WMON, 1:1" : "Unwrap WMON → MON, 1:1", gasEstimate: 50_000, priceImpactBps: 0) { _ in
            let request = wrapping
                ? TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonDeposit(), value: amount)
                : TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonWithdraw(amount: amount))
            return [.call(request, label: wrapping ? "Wrap MON" : "Unwrap WMON")]
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, venue: Venue, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SwapError.timedOut(venue, seconds: Int(seconds.rounded()))
            }
            guard let first = try await group.next() else { throw SwapError.timedOut(venue, seconds: Int(seconds.rounded())) }
            group.cancelAll()
            return first
        }
    }
}
