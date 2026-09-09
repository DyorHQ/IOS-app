import BigInt
import Foundation

/// Where a spot quote comes from. `wrap` is the 1:1 MON ↔ WMON conversion, which never needs a venue.
public enum Venue: String, Sendable, CaseIterable, Codable {
    case kuru, uniswap, monday, wrap

    public var displayName: String {
        switch self {
        case .kuru: return "Kuru Flow"
        case .uniswap: return "Uniswap"
        case .monday: return "Monday Trade"
        case .wrap: return "Wrap"
        }
    }
}

public struct SwapRequest: Sendable {
    public var tokenIn: Token
    public var tokenOut: Token
    public var amountIn: BigUInt
    public var slippageBps: Int
    /// Wallet that receives the output; a placeholder when nothing is connected.
    public var account: Address

    public init(tokenIn: Token, tokenOut: Token, amountIn: BigUInt, slippageBps: Int, account: Address) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.slippageBps = slippageBps
        self.account = account
    }
}

/// One venue's answer for a request, with a builder for the transactions that execute it.
public struct VenueQuote: Sendable, Identifiable {
    public var id: Venue { venue }
    public let venue: Venue
    public let amountOut: BigUInt
    public let minOut: BigUInt
    /// Short human route, e.g. "v4 · MON → USDC · 0.05%".
    public let route: String
    public let gasEstimate: BigUInt?
    /// Price impact in basis points versus the venue's own marginal price (positive = worse); nil when unknown.
    public let priceImpactBps: Int?
    /// When the quote was produced.
    public let at: Date
    /// Builds the transaction plan for the connected account (approvals first, then the swap).
    public let build: @Sendable (Address) async throws -> [TransactionStep]

    public init(venue: Venue, amountOut: BigUInt, minOut: BigUInt, route: String, gasEstimate: BigUInt?, priceImpactBps: Int?, at: Date = Date(), build: @escaping @Sendable (Address) async throws -> [TransactionStep]) {
        self.venue = venue
        self.amountOut = amountOut
        self.minOut = minOut
        self.route = route
        self.gasEstimate = gasEstimate
        self.priceImpactBps = priceImpactBps
        self.at = at
        self.build = build
    }

    public var age: TimeInterval { Date().timeIntervalSince(at) }
}

public struct QuoteResult: Sendable {
    /// Best output first.
    public var quotes: [VenueQuote]
    /// A readable reason for every venue that produced no quote.
    public var errors: [Venue: String]

    public init(quotes: [VenueQuote] = [], errors: [Venue: String] = [:]) {
        self.quotes = quotes
        self.errors = errors
    }

    public var best: VenueQuote? { quotes.first }
}

public enum SwapError: Error, LocalizedError, Equatable {
    case timedOut(Venue, seconds: Int)
    case differentWallet
    case malformedRoute
    case amountTooLarge
    /// A venue's own message, already readable.
    case venue(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let venue, let seconds): return "\(venue.displayName) did not answer within \(seconds)s."
        case .differentWallet: return "This quote was made for a different wallet. Refresh the quote."
        case .malformedRoute: return "The route is malformed."
        case .amountTooLarge: return "The amount is too large for this venue."
        case .venue(let message): return message
        }
    }
}

public enum SwapMath {
    public static func minAfterSlippage(_ amount: BigUInt, bps: Int) -> BigUInt {
        amount * BigUInt(max(0, 10_000 - bps)) / 10_000
    }

    /// "0.05%" for a fee tier of 500 (hundredths of a basis point), trailing zeros trimmed like the web app.
    public static func feeLabel(_ fee: Int) -> String {
        var text = String(format: "%.2f", Double(fee) / 10_000)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text + "%"
    }

    /// Marginal-price check: `1 - (out/in) / (sliceOut/sliceIn)` in basis points; nil when the slice returned nothing.
    public static func impactBps(amountIn: BigUInt, amountOut: BigUInt, sliceIn: BigUInt, sliceOut: BigUInt) -> Int? {
        guard sliceOut > 0, amountIn > 0 else { return nil }
        let ratio = amountOut * sliceIn * 10_000 / (amountIn * sliceOut)
        return Int(exactly: BigInt(10_000) - BigInt(ratio))
    }

    static var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

    /// Turns any failure into one readable sentence for the quote list.
    static func describe(_ error: Error) -> String {
        if let rpc = error as? RPCError { return RevertReason.describe(rpc) }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if message.range(of: "user rejected|user denied", options: [.regularExpression, .caseInsensitive]) != nil { return "Request cancelled in your wallet." }
        return message.count > 220 ? String(message.prefix(220)) + "…" : message
    }
}
