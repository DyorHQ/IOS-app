import BigInt
import Foundation

/// Where a spot quote comes from. `wrap` is the 1:1 MON ↔ WMON conversion, which never needs a venue.
public enum Venue: String, Sendable, CaseIterable, Codable {
    case kuru, uniswap, monday, wrap
    /// 1inch, for xStocks only: the one venue asked for a curated xStock against USDC (`SwapEngine.venues(for:)`), and
    /// never for any other pair. It quotes only in a build that has it (`OneInch.compiledIn`) and through DyorHQ's proxy
    /// (`OneInchVenue`); otherwise asking it gives no quote.
    case oneInch

    public var displayName: String {
        switch self {
        // not localized: the venues' names
        case .kuru: return "Kuru Flow"
        case .uniswap: return "Uniswap"
        case .monday: return "Monday Trade"
        case .oneInch: return "1inch" // not localized: a venue's name
        case .wrap: return L10n.string(LocalizedStringResource("Wrap", bundle: L10n.kit, comment: "The 1:1 conversion between MON and WMON, named where a venue's name goes."))
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
    /// Approve exactly the input, and let a Permit2 allowance live only as long as the swap needs it
    /// (`SwapCalldata.exactPermit2Lifetime`), instead of the standing max approval and 30-day allowance. A passkey
    /// (Mera) account's session signs only approvals like these (MERA-PLAN §3).
    public var exactApprovals: Bool

    /// The account a quote is asked for while no wallet is connected: nothing can be signed for it, and a venue that
    /// would tell a third party the wallet (1inch) is never asked for it.
    public static let placeholderAccount = Address(literal: "0x000000000000000000000000000000000000dEaD")

    public init(tokenIn: Token, tokenOut: Token, amountIn: BigUInt, slippageBps: Int, account: Address, exactApprovals: Bool = false) {
        self.tokenIn = tokenIn
        self.tokenOut = tokenOut
        self.amountIn = amountIn
        self.slippageBps = slippageBps
        self.account = account
        self.exactApprovals = exactApprovals
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
    /// Whether the quote can be traded as it is (`firm`, every venue's but 1inch's on the Swap screen) or only shows a
    /// price (`indicative`): its `build` throws `SwapError.reviewForFirmQuote`, and Review asks for a firm quote first.
    public let firmness: Firmness
    /// The last moment the quote may be signed, on the device's clock (`TransactionStep.notAfter`): a firm 1inch quote's
    /// window, counted from before its request was sent. Nil for a quote with no deadline.
    public let deadline: ContinuousClock.Instant?
    /// Builds the transaction plan for the connected account (approvals first, then the swap).
    public let build: @Sendable (Address) async throws -> [TransactionStep]

    /// Whether a quote can be built into transactions (`VenueQuote.firmness`).
    public enum Firmness: Sendable, Equatable {
        case firm, indicative
    }

    public init(venue: Venue, amountOut: BigUInt, minOut: BigUInt, route: String, gasEstimate: BigUInt?, priceImpactBps: Int?, at: Date = Date(),
                firmness: Firmness = .firm, deadline: ContinuousClock.Instant? = nil, build: @escaping @Sendable (Address) async throws -> [TransactionStep]) {
        self.venue = venue
        self.amountOut = amountOut
        self.minOut = minOut
        self.route = route
        self.gasEstimate = gasEstimate
        self.priceImpactBps = priceImpactBps
        self.at = at
        self.firmness = firmness
        self.deadline = deadline
        self.build = build
    }

    public var age: TimeInterval { Date().timeIntervalSince(at) }
}

/// The venues' answers for one request: every one of them once the round is over (`isFinal`), or, while it is under way
/// (`SwapEngine.quoteUpdates`), those that answered so far and the venues still being asked (`pending`).
public struct QuoteResult: Sendable {
    /// Best output first.
    public var quotes: [VenueQuote]
    /// A readable reason for every venue that produced no quote.
    public var errors: [Venue: String]
    /// The venues still being asked, in `SwapEngine.quoteVenues` order: empty once every venue has answered. While any is
    /// left, the best quote is only the best so far — a slower venue may still beat it — so nothing may be reviewed or
    /// signed from it (`isFinal`).
    public var pending: [Venue]

    public init(quotes: [VenueQuote] = [], errors: [Venue: String] = [:], pending: [Venue] = []) {
        self.quotes = quotes
        self.errors = errors
        self.pending = pending
    }

    public var best: VenueQuote? { quotes.first }

    /// Every venue has answered (or been refused), so `best` is the best of them all, not just the best so far.
    public var isFinal: Bool { pending.isEmpty }
}

/// The venue a swap screen has selected, and whether the person picked it (a venue row tapped) or it follows the best
/// quote. Review takes the selected venue's quote from a final answer (`QuoteResult.isFinal`), so a selection must never
/// move to a venue the person didn't pick while they have picked one (speed work, 2026-10-10): the quotes of a round now
/// show as they arrive, and an answer in which the pick hasn't answered yet says nothing about it.
public struct VenueSelection: Sendable, Equatable {
    /// The venue selected; nil before any quote.
    public var venue: Venue?
    /// The person picked `venue`; false while the selection follows the best quote.
    public var picked: Bool

    public init(venue: Venue? = nil, picked: Bool = false) {
        self.venue = venue
        self.picked = picked
    }

    /// The selection once `answer` is on screen:
    /// - a pick is kept whatever an answer under way holds — its venue may not have answered yet, and the best so far is
    ///   never put in its place (the screen shows the best so far meanwhile, `shown(in:)`);
    /// - a final answer keeps a pick it quotes; one that doesn't quote it (the venue found no route, failed or ran out of
    ///   time) gives the selection back to the best quote, which it follows from then on;
    /// - with no pick, the selection is the best quote, so far or final.
    public func following(_ answer: QuoteResult) -> VenueSelection {
        if picked, let venue {
            if !answer.isFinal || answer.quotes.contains(where: { $0.venue == venue }) { return self }
        }
        return VenueSelection(venue: answer.quotes.first?.venue, picked: false)
    }

    /// The quote a screen shows in `answer`: the selected venue's while `answer` quotes it, else the best (so far).
    public func shown(in answer: QuoteResult) -> VenueQuote? {
        answer.quotes.first { $0.venue == venue } ?? answer.quotes.first
    }
}

public enum SwapError: Error, LocalizedError, Equatable {
    case timedOut(Venue, seconds: Int)
    case differentWallet
    case malformedRoute
    case amountTooLarge
    /// A retired Moments cohort's coin (or its pool's hook) is on the trade: past cohorts are claim-only in the app (and
    /// cohorts 1 and 2's pools pay the retired platform wallet), so no venue quotes, routes or builds it (see
    /// `SwapEngine.tradingClosed`).
    case tradingClosed(Address)
    /// Buying a coin still on a retired launchpad's bonding curve: those coins are sell-only (`SwapEngine.buyRefusal`).
    case retiredLaunchpad(Address)
    /// Whether the coin bought is on a retired launchpad's curve couldn't be read, so no venue was asked.
    case launchpadUnchecked
    /// A known xStock (tokenized stock) is on the trade and it may not be quoted (`SwapEngine.xStockRefusal`): why.
    case xStocksUnavailable(XStockRefusal)
    /// An indicative quote was asked to build: only a firm one, fetched at Review (`SwapEngine.firmQuote(for:)`), can be.
    case reviewForFirmQuote
    /// A venue's own message, already readable.
    case venue(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let venue, let seconds): return L10n.tr("\(venue.displayName) did not answer within \(RelativeTime.seconds(seconds)).")
        case .differentWallet: return L10n.tr("This quote was made for a different wallet. Refresh the quote.")
        case .malformedRoute: return L10n.tr("The route is malformed.")
        case .amountTooLarge: return L10n.tr("The amount is too large for this venue.")
        case .tradingClosed(let address):
            return MomentsAddresses.isRetiredCoin(address)
                ? L10n.tr("Past cohort · trading closed. \(address.short) is a retired Moment coin, so DyorHQ never trades it.")
                : L10n.tr("Past cohort · trading closed. \(address.short) is a retired Moment pool, so DyorHQ never trades it.")
        case .retiredLaunchpad: return RetiredLaunchpad.notice
        case .launchpadUnchecked: return L10n.tr("DyorHQ couldn't check this coin's launchpad just now, so buying it isn't offered. Try again in a moment.")
        case .xStocksUnavailable(let reason): return reason.message
        case .reviewForFirmQuote: return L10n.tr("This price is an estimate. Review the swap to get a firm quote.")
        case .venue(let message): return message
        }
    }
}

/// Why a trade touching a known xStock gets no quote (`SwapEngine.xStockRefusal`, `SwapError.xStocksUnavailable`).
public enum XStockRefusal: Equatable, Sendable {
    /// A known xStock the app never trades (`XStocks.knownUncurated`): a bridged copy and the like.
    case notSupported
    /// A curated xStock in a pair other than against USDC, two stocks included.
    case pairNotOffered
    /// Buying xStocks isn't open to this wallet now: the build, the owner's switch, the server's mode or the disclosure
    /// not yet acknowledged.
    case buyingClosed
    /// Selling xStocks in the app is closed now (the server's mode is off, or the build has no stock venue). Sending
    /// them stays possible.
    case sellingClosed
    /// A venue other than 1inch was asked for a stock pair: 1inch is the only venue that quotes one.
    case venueNotOffered(Venue)

    /// One sentence, in the app's language.
    public var message: String {
        switch self {
        case .notSupported:
            return L10n.tr("This tokenized stock isn't supported in DyorHQ, so it can't be swapped here. You can still send it.")
        case .pairNotOffered:
            return L10n.tr("xStocks (tokenized stocks) can be swapped only against USDC in DyorHQ.")
        case .buyingClosed:
            return L10n.tr("Buying xStocks (tokenized stocks) isn't available right now.")
        case .sellingClosed:
            return L10n.tr("Selling xStocks (tokenized stocks) in DyorHQ isn't available right now. You can still send them.")
        case .venueNotOffered(let venue):
            return L10n.tr("\(venue.displayName) doesn't quote xStocks (tokenized stocks) in DyorHQ.")
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
        // not localized: the wallet's own English, matched as it sends it
        if message.range(of: "user rejected|user denied", options: [.regularExpression, .caseInsensitive]) != nil { return L10n.tr("Request cancelled in your wallet.") }
        return message.count > 220 ? String(message.prefix(220)) + "…" : message
    }
}
