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

    /// `launchpadFactory` enables routes through graduated launchpad pools on Uniswap v4 once the factory is deployed;
    /// `moments` enables routes through graduated Moment pools (coin ↔ USDC, hooked, 1.5% all-in).
    public init(rpc: RPCClient, session: URLSession = .shared, launchpadFactory: Address? = nil, moments: MomentsAddresses? = nil) {
        self.rpc = rpc
        let multicall = Multicall(rpc: rpc)
        let v3 = V3Router(multicall: multicall)
        kuru = KuruFlowClient(session: session)
        uniswap = UniswapVenue(multicall: multicall, v3: v3, launchpadFactory: launchpadFactory, moments: moments)
        monday = MondayVenue(v3: v3)
    }

    public nonisolated static func isWrap(_ tokenIn: Token, _ tokenOut: Token) -> Bool {
        (tokenIn.isNative && tokenOut.address == Monad.wmon) || (tokenIn.address == Monad.wmon && tokenOut.isNative)
    }

    /// Every venue's answer, best output first, with a readable reason for each venue that gave none.
    public func quotes(for request: SwapRequest) async -> QuoteResult {
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

    /// One venue's quote, or nil when it has no route. Throws with a readable message on failure or timeout.
    public func quote(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
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
