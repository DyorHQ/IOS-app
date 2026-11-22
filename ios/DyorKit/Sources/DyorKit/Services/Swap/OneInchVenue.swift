import BigInt
import Foundation

/* 1inch, the one venue for xStocks (tokenized stocks): a curated xStock against USDC, either way, and nothing else
   (`SwapEngine.venues(for:)`). The app never talks to 1inch itself. It asks DyorHQ's proxy (the oneinch-proxy Edge
   Function), which holds DyorHQ's 1inch key, serves only the signed-in wallet, and forces every parameter but the pair,
   the amount and the slippage. The proxy is not trusted either: what it answers is checked here as if 1inch had
   answered it directly.

   Two kinds of quote:
     - indicative (the proxy's `quote` route): what the Swap screen shows while the amount is edited. It names a price
       only, and its `build` throws `SwapError.reviewForFirmQuote`, so nothing can ever be signed from it.
     - firm (`swap`, fetched once at Review, `SwapEngine.firmQuote(for:)`): an issuer-signed RFQ that is only fillable
       for a short window. Its deadline is counted on the device from a moment taken BEFORE the request is sent: no time
       the proxy or 1inch reports is ever used. The transaction it carries is read in full (`OneInchSwap`) and must be
       exactly the reviewed trade, for this account, before a quote is made of it.

   Both are checked against the stock's own on-chain reference price (`XStockReference`, `XStockPriceBand`), better and
   worse alike, so a hostile API can't win the screen with a high quote and switch at the firm step; and against the
   per-trade cap (`OneInch.tradeCapUSDC`). Every failure is a code from the proxy, said in the app's own words
   (`OneInchError`): no upstream text is ever shown. */

/// Where a stock trade's price stands against the stock's reference price (`XStockReference.Snapshot`). USDC is counted
/// as one dollar. Integer arithmetic throughout: both sides are brought to one unit, 10^-(6 + the stock's decimals + the
/// feed's decimals) dollars, and compared by cross-multiplication, so nothing is rounded before it is judged.
public enum XStockPriceBand {
    /// The stock amount at the reference price and the USDC amount, in one unit. Zero for a zero amount or answer.
    static func values(stock: BigUInt, usdc: BigUInt, reference: XStockReference.Snapshot) -> (stock: BigUInt, usdc: BigUInt) {
        let stockValue = stock * reference.answer * BigUInt(10).power(Token.usdc.decimals)
        let usdcValue = usdc * BigUInt(10).power(reference.stockDecimals + reference.decimals)
        return (stockValue, usdcValue)
    }

    /// The trade's price against the reference, in basis points: positive when it values the stock above the reference
    /// (a buy pays more than the reference, a sell receives more), negative below. Rounded toward zero; nil when either
    /// side is worth nothing. For showing ("Price changed"); the checks below never round.
    public static func deviationBps(stock: BigUInt, usdc: BigUInt, reference: XStockReference.Snapshot) -> Int? {
        let value = values(stock: stock, usdc: usdc, reference: reference)
        guard value.stock > 0, value.usdc > 0 else { return nil }
        let bps = (BigInt(value.usdc) - BigInt(value.stock)) * 10_000 / BigInt(value.stock)
        return Int(exactly: bps) ?? (bps.sign == .minus ? Int.min : Int.max)
    }

    /// Whether the trade's price is within `bandBps` of the reference, either way (inclusive).
    public static func admits(stock: BigUInt, usdc: BigUInt, reference: XStockReference.Snapshot, bandBps: Int = OneInch.priceBandBps) -> Bool {
        let value = values(stock: stock, usdc: usdc, reference: reference)
        guard value.stock > 0, value.usdc > 0, bandBps >= 0, bandBps < 10_000 else { return false }
        let scaled = value.usdc * 10_000
        return scaled >= value.stock * BigUInt(10_000 - bandBps) && scaled <= value.stock * BigUInt(10_000 + bandBps)
    }

    /// Whether the worst a trade may fill at, its minimum, is no further than `bandBps` from the reference on the side
    /// that costs the account: for a buy, the least stock for the USDC paid; for a sell, the least USDC for the stock sold.
    /// A minimum better than the reference is not this check's concern (the quoted amount is checked both ways).
    public static func admitsWorstCase(isBuy: Bool, stock: BigUInt, usdc: BigUInt, reference: XStockReference.Snapshot,
                                       bandBps: Int = OneInch.priceBandBps) -> Bool {
        let value = values(stock: stock, usdc: usdc, reference: reference)
        guard value.stock > 0, value.usdc > 0, bandBps >= 0, bandBps < 10_000 else { return false }
        if isBuy { return value.usdc * 10_000 <= value.stock * BigUInt(10_000 + bandBps) }
        return value.usdc * 10_000 >= value.stock * BigUInt(10_000 - bandBps)
    }
}

/// Why 1inch gave no quote: the proxy's codes and the app's own checks, each one sentence in the app's language. No text
/// from the proxy or 1inch is ever shown.
public enum OneInchError: Error, LocalizedError, Equatable {
    /// No DyorHQ session, or the proxy refused the one sent (`session`).
    case signedOut
    /// The wallet asked too often (`rate_limited`), with the proxy's wait in seconds when it sent one.
    case rateLimited(retryAfter: Int?)
    /// 1inch or the proxy is overloaded or didn't answer (`busy`, `upstream`).
    case busy
    /// The stock's market is closed (`market_closed`). UNVERIFIED (research R5): how xChange reports market hours.
    case marketClosed
    /// The proxy serves no stock trade like this now (`disabled`): its mode, the beta list or the owner's switch.
    case disabled
    /// The proxy doesn't offer this pair (`pair_not_offered`): not curated there, or held back by a deny list.
    case pairNotOffered
    /// The session is another wallet's than the one trading (`wallet_mismatch`).
    case walletMismatch
    /// An answer that doesn't check out, from the proxy (`unexpected_answer`) or found here: blocked.
    case unexpectedAnswer
    /// Over the per-trade cap (`over_cap`, or `OneInch.tradeCapUSDC` checked here).
    case overCap
    /// 1inch has no quote for this trade (`no_route`).
    case noRoute
    /// The price is further from the stock's reference price than `OneInch.priceBandBps`, either way.
    case priceOutOfBand
    /// Anything else the proxy refused.
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .signedOut:
            return L10n.tr("Sign in to DyorHQ to trade xStocks (tokenized stocks).")
        case .rateLimited(let retryAfter):
            guard let seconds = retryAfter, seconds > 0 else {
                return L10n.tr("Too many xStocks (tokenized stocks) quotes from this wallet. Try again later.")
            }
            return L10n.tr("Too many xStocks (tokenized stocks) quotes from this wallet. Try again in \(String(max(1, (seconds + 59) / 60))) min.")
        case .busy:
            return L10n.tr("1inch is busy right now. Try again in a moment.")
        case .marketClosed:
            return L10n.tr("This stock's market is closed right now. Try again when it opens.")
        case .disabled:
            return L10n.tr("Trading xStocks (tokenized stocks) isn't available right now.")
        case .pairNotOffered:
            return L10n.tr("DyorHQ doesn't offer this xStock (tokenized stock) right now.")
        case .walletMismatch:
            return L10n.tr("The wallet signed in to DyorHQ isn't this one. Sign in again with this wallet.")
        case .unexpectedAnswer:
            return L10n.tr("1inch returned an unexpected answer, so it was blocked for your safety.")
        case .overCap:
            // The cap in the app's one style for dollars, whatever the language ("$250").
            let cap = PriceFormat.usdValue(Amount.units(OneInch.tradeCapUSDC, decimals: Token.usdc.decimals), fractionDigits: 0...0)
            return L10n.tr("Each xStocks (tokenized stocks) trade is limited to \(cap) in DyorHQ.")
        case .noRoute:
            return L10n.tr("1inch has no quote for this trade right now.")
        case .priceOutOfBand:
            return L10n.tr("1inch's price is too far from this stock's reference price, so it was blocked for your safety.")
        case .unavailable:
            return L10n.tr("1inch couldn't quote this trade right now. Try again later.")
        }
    }
}

/// DyorHQ's 1inch proxy as a venue (see the comment at the top of this file). The engine decides whether 1inch may be
/// asked at all and reads the reference price first (`SwapEngine`); this type sends the one request and checks the
/// answer. Every check of an answer is a pure function of the answer, the trade and the reference, so it is tested
/// without a network.
struct OneInchVenue: Sendable {
    /// The headers that authenticate a request as `account`'s DyorHQ session (`SupabaseClient.sessionHeaders(for:)`).
    typealias Credentials = @Sendable (Address) async throws -> [String: String]
    /// Sends one request and answers its body and status.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// How long one request may take in all, its answer included (the proxy gives 1inch 15 s).
    static let requestLimit: TimeInterval = 20

    /// The proxy's two quote routes.
    enum Route: String, Sendable {
        case quote, swap
    }

    /// A stock trade 1inch may be asked for: the request, the curated stock on one side (USDC on the other), and whether
    /// the stock is what is received.
    struct Trade: Sendable {
        let request: SwapRequest
        let stock: Token
        let isBuy: Bool

        /// The USDC side's amount: what a buy pays, or what a sell receives (`out`).
        func usdc(out: BigUInt) -> BigUInt { isBuy ? request.amountIn : out }
        /// The stock side's amount: what a buy receives (`out`), or what a sell pays.
        func stockAmount(out: BigUInt) -> BigUInt { isBuy ? out : request.amountIn }
    }

    /// The proxy's status for a wallet: its serving mode (`ONEINCH_MODE`, the same for every wallet unless a beta list
    /// leaves this one out) and whether the wallet holds the beta bit, which stands in for the owner's switch.
    struct ServerStatus: Sendable, Equatable {
        let mode: XStocksAvailability.Mode
        let beta: Bool
    }

    /// A firm answer as the proxy sent it, read strictly; not yet checked against the trade (`firmQuote`).
    struct FirmAnswer: Sendable, Equatable {
        let dstAmount: BigUInt
        let to: Address
        let from: Address
        let data: Data
        let value: BigUInt
    }

    /// The proxy function's URL (`.../functions/v1/oneinch-proxy`); a route is appended to it.
    let proxy: URL
    let credentials: Credentials
    let transport: Transport
    /// The device's clock, for a firm quote's deadline.
    let now: @Sendable () -> ContinuousClock.Instant

    init(proxy: URL, credentials: @escaping Credentials, transport: @escaping Transport,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.proxy = proxy
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// Sends over `session`, within `requestLimit` in all.
    static func transport(_ session: URLSession) -> Transport {
        { request in
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await RPCClient.data(for: request, session: session, limit: requestLimit)
            } catch {
                throw NetworkError.transport(error)
            }
            guard let http = response as? HTTPURLResponse else { throw NetworkError.malformedResponse }
            return (data, http.statusCode)
        }
    }

    // MARK: Asking

    /// `account`'s session headers. With no session, `signedOut`: the proxy is never asked anything without one.
    func headers(for account: Address) async throws -> [String: String] {
        do {
            return try await credentials(account)
        } catch SupabaseError.notSignedIn {
            throw OneInchError.signedOut
        }
    }

    /// The indicative quote for `trade`, checked against `reference`.
    func indicative(_ trade: Trade, headers: [String: String], reference: XStockReference.Snapshot) async throws -> VenueQuote {
        let (data, status) = try await transport(try Self.urlRequest(proxy, .quote, trade.request, headers: headers))
        return try Self.indicativeQuote(trade, dstAmount: try Self.quoteAnswer(data, status: status), reference: reference)
    }

    /// The proxy's status for the session's wallet (`status` route): the serving mode and the wallet's beta bit. The
    /// proxy answers it without asking 1inch, and it names no pair, amount or token.
    func status(headers: [String: String]) async throws -> ServerStatus {
        let (data, status) = try await transport(Self.statusRequest(proxy, headers: headers))
        return try Self.statusAnswer(data, status: status)
    }

    /// The firm quote for `trade`, checked against `reference`. The deadline's start is taken before the request is sent.
    func firm(_ trade: Trade, headers: [String: String], reference: XStockReference.Snapshot) async throws -> VenueQuote {
        let request = try Self.urlRequest(proxy, .swap, trade.request, headers: headers)
        let sentAt = now()
        let (data, status) = try await transport(request)
        return try Self.firmQuote(trade, answer: try Self.firmAnswer(data, status: status), reference: reference, sentAt: sentAt)
    }

    // MARK: The request

    /// The slippage sent and enforced, in basis points: the request's, within 0 and the stock cap.
    static func slippageBps(_ requested: Int) -> Int {
        min(OneInch.stockSlippageCapBps, max(0, requested))
    }

    private struct QuoteBody: Encodable {
        let src: String
        let dst: String
        let amount: String
    }

    private struct SwapBody: Encodable {
        let src: String
        let dst: String
        let amount: String
        let from: String
        let slippageBps: Int
    }

    /// The body the proxy is sent: the pair as lowercase addresses, the amount as a decimal integer, and for a firm
    /// quote the wallet and the slippage in whole basis points. Built from integers and hex only, with sorted keys, so it
    /// is byte-for-byte the same in every language and region.
    static func body(_ route: Route, _ request: SwapRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let src = request.tokenIn.address.hex.lowercased(), dst = request.tokenOut.address.hex.lowercased()
        let amount = String(request.amountIn)
        switch route {
        case .quote:
            return try encoder.encode(QuoteBody(src: src, dst: dst, amount: amount))
        case .swap:
            return try encoder.encode(SwapBody(src: src, dst: dst, amount: amount, from: request.account.hex.lowercased(),
                                               slippageBps: slippageBps(request.slippageBps)))
        }
    }

    /// The POST of `route` for `request`, with the session's `headers`.
    static func urlRequest(_ proxy: URL, _ route: Route, _ request: SwapRequest, headers: [String: String]) throws -> URLRequest {
        var urlRequest = URLRequest(url: proxy.appending(path: route.rawValue))
        urlRequest.httpMethod = "POST"
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = requestLimit
        urlRequest.httpBody = try body(route, request)
        return urlRequest
    }

    /// The POST of the status route, with the session's `headers` and an empty JSON object as its body: nothing about a
    /// trade is sent.
    static func statusRequest(_ proxy: URL, headers: [String: String]) -> URLRequest {
        var urlRequest = URLRequest(url: proxy.appending(path: "status")) // not localized: the proxy's route
        urlRequest.httpMethod = "POST"
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = requestLimit
        urlRequest.httpBody = Data("{}".utf8)
        return urlRequest
    }

    // MARK: The answer

    /// A status answer, `{mode, beta, ...}`, read strictly: `beta` must be a JSON boolean, and a mode the app doesn't
    /// know is off (`XStocksAvailability.Mode(serverValue:)`). Throws the refusal for any status but 2xx, and
    /// `unexpectedAnswer` for anything else. Any other field (the terms version) is ignored.
    static func statusAnswer(_ data: Data, status: Int) throws -> ServerStatus {
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        guard let json = try? JSONDecoder().decode(JSON.self, from: data), json.object != nil,
              case .bool(let beta) = json["beta"] else { throw OneInchError.unexpectedAnswer }
        return ServerStatus(mode: XStocksAvailability.Mode(serverValue: json["mode"].string), beta: beta)
    }

    /// A refusal as the app says it, from the proxy's `code` (and `retryAfter`); a body without a known code is judged by
    /// its status alone.
    static func failure(status: Int, data: Data) -> OneInchError {
        let body = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        // not localized: the proxy's codes, matched as it sends them
        switch body["code"].string ?? "" {
        case "rate_limited": return .rateLimited(retryAfter: retryAfter(body["retryAfter"]))
        case "busy", "upstream": return .busy
        case "market_closed": return .marketClosed
        case "disabled": return .disabled
        case "pair_not_offered": return .pairNotOffered
        case "wallet_mismatch": return .walletMismatch
        case "unexpected_answer": return .unexpectedAnswer
        case "session": return .signedOut
        case "over_cap": return .overCap
        case "no_route": return .noRoute
        default:
            if status == 401 { return .signedOut }
            if status == 429 { return .rateLimited(retryAfter: nil) }
            if (500...599).contains(status) { return .busy }
            return .unavailable
        }
    }

    /// The seconds a `retryAfter` field holds, rounded up and clamped to a day; nil for anything else.
    static func retryAfter(_ json: JSON) -> Int? {
        guard let seconds = json.number, seconds.isFinite, seconds >= 0 else { return nil }
        return Int(min(seconds.rounded(.up), 86_400))
    }

    /// A positive decimal integer of at most 2^256 − 1, written as the proxy writes amounts; nil for anything else (a
    /// number, hex, a sign, a space, zero).
    static func amount(_ json: JSON) -> BigUInt? {
        guard let text = json.string, (1...78).contains(text.utf8.count), text.utf8.first != UInt8(ascii: "0"),
              text.utf8.allSatisfy({ (48...57).contains($0) }), let value = BigUInt(text, radix: 10),
              value < BigUInt(1) << 256 else { return nil }
        return value
    }

    /// An indicative answer's `dstAmount`. Throws the refusal for any status but 2xx, and `unexpectedAnswer` for a body
    /// that isn't a JSON object with a valid amount.
    static func quoteAnswer(_ data: Data, status: Int) throws -> BigUInt {
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        guard let json = try? JSONDecoder().decode(JSON.self, from: data), json.object != nil,
              let dstAmount = amount(json["dstAmount"]) else { throw OneInchError.unexpectedAnswer }
        return dstAmount
    }

    /// A firm answer, `{dstAmount, tx: {to, from, data, value}}`, read strictly: valid addresses, calldata as "0x" and
    /// whole bytes, and a value of exactly "0". Throws the refusal for any status but 2xx, and `unexpectedAnswer` for
    /// anything else. Any other field (a time, gas, protocols) is ignored, never used.
    static func firmAnswer(_ data: Data, status: Int) throws -> FirmAnswer {
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        guard let json = try? JSONDecoder().decode(JSON.self, from: data), json.object != nil,
              let dstAmount = amount(json["dstAmount"]), json["tx"].object != nil else { throw OneInchError.unexpectedAnswer }
        let tx = json["tx"]
        guard let to = tx["to"].string.flatMap({ Address($0) }), let from = tx["from"].string.flatMap({ Address($0) }),
              tx["value"].string == "0", let hex = tx["data"].string, isCalldataHex(hex),
              let calldata = Data(hex: hex) else { throw OneInchError.unexpectedAnswer }
        return FirmAnswer(dstAmount: dstAmount, to: to, from: from, data: calldata, value: 0)
    }

    /// "0x" and at least one whole byte of hex digits, nothing else.
    private static func isCalldataHex(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count >= 4, bytes.count % 2 == 0, bytes[0] == UInt8(ascii: "0"), bytes[1] == UInt8(ascii: "x") else { return false }
        return bytes.dropFirst(2).allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    // MARK: Checking

    /// Refuses a buy over the per-trade cap before anything is asked: what it pays is known already.
    static func precheck(_ trade: Trade) throws {
        if trade.isBuy, trade.request.amountIn > OneInch.tradeCapUSDC { throw OneInchError.overCap }
    }

    /// Refuses a trade whose quoted amount `out` is over the cap or outside the band either way, or whose minimum
    /// `minOut` is further than the band below the reference on the side that costs the account. `reference` must be the
    /// traded stock's.
    static func checkPrice(_ trade: Trade, out: BigUInt, minOut: BigUInt, reference: XStockReference.Snapshot) throws {
        guard reference.stock == trade.stock.address, reference.stockDecimals == trade.stock.decimals else { throw OneInchError.priceOutOfBand }
        if trade.usdc(out: out) > OneInch.tradeCapUSDC { throw OneInchError.overCap }
        guard XStockPriceBand.admits(stock: trade.stockAmount(out: out), usdc: trade.usdc(out: out), reference: reference),
              XStockPriceBand.admitsWorstCase(isBuy: trade.isBuy, stock: trade.stockAmount(out: minOut), usdc: trade.usdc(out: minOut),
                                              reference: reference) else { throw OneInchError.priceOutOfBand }
    }

    /// The constant route line: never the API's or the proxy's own text.
    static var route: String { L10n.tr("Issuer RFQ via 1inch") }

    /// The quote the Swap screen shows for an indicative `dstAmount`: checked against the cap and the band (its minimum
    /// at the trade's slippage too), and never buildable.
    static func indicativeQuote(_ trade: Trade, dstAmount: BigUInt, reference: XStockReference.Snapshot) throws -> VenueQuote {
        let minOut = SwapMath.minAfterSlippage(dstAmount, bps: slippageBps(trade.request.slippageBps))
        try checkPrice(trade, out: dstAmount, minOut: minOut, reference: reference)
        return VenueQuote(venue: .oneInch, amountOut: dstAmount, minOut: minOut, route: route, gasEstimate: nil, priceImpactBps: nil,
                          firmness: .indicative) { _ in throw SwapError.reviewForFirmQuote }
    }

    /// The firm quote for `answer`, sent at `sentAt` on the device's clock, once every check passes:
    /// - the transaction goes to the pinned router, from this account, with no MON, and names no retired Moment coin;
    /// - its calldata is a generic swap read in full (`OneInchSwap`), paying this account, with no flags, of exactly the
    ///   requested tokens and amount, with a minimum no higher than the quoted amount and no lower than the slippage
    ///   allows on it;
    /// - the quoted amount is within the cap and the band either way, and the minimum within the band on the costly side.
    /// Its deadline is `sentAt` plus the RFQ window, less the start margin; no time from the answer is read. Its `build`
    /// is pure: it asks nothing, and always gives the exact approval of the router and the swap, bound to the deadline and
    /// to these terms (`TransactionStep.notAfter`, `expectedSwap`). An approval the allowance already matches exactly is
    /// skipped when the plan runs (`TransactionSender.request(for:)`).
    static func firmQuote(_ trade: Trade, answer: FirmAnswer, reference: XStockReference.Snapshot,
                          sentAt: ContinuousClock.Instant) throws -> VenueQuote {
        let request = trade.request
        guard answer.to == OneInch.router, answer.value == 0, answer.from == request.account else { throw OneInchError.unexpectedAnswer }
        try SwapEngine.ensureNoRetired(in: answer.data)
        let bps = slippageBps(request.slippageBps)
        let floor = SwapMath.minAfterSlippage(answer.dstAmount, bps: bps)
        guard let swap = OneInchSwap(calldata: answer.data), swap.problem(account: request.account, value: answer.value) == nil,
              swap.srcToken == request.tokenIn.address, swap.dstToken == request.tokenOut.address, swap.amount == request.amountIn,
              swap.minReturn <= answer.dstAmount, swap.minReturn >= floor else { throw OneInchError.unexpectedAnswer }
        try checkPrice(trade, out: answer.dstAmount, minOut: swap.minReturn, reference: reference)

        let deadline = sentAt + OneInch.firmWindow - OneInch.startMargin
        let terms = TransactionStep.ExpectedSwap(tokenIn: request.tokenIn.address, tokenOut: request.tokenOut.address,
                                                 amountIn: request.amountIn, minReturnFloor: floor)
        let tx = TransactionRequest(to: OneInch.router, data: answer.data, value: 0)
        let user = request.account, tokenIn = request.tokenIn, amountIn = request.amountIn
        return VenueQuote(venue: .oneInch, amountOut: answer.dstAmount, minOut: swap.minReturn, route: route, gasEstimate: nil, priceImpactBps: nil,
                          firmness: .firm, deadline: deadline) { account in
            guard account == user else { throw SwapError.differentWallet }
            return [
                .approve(token: tokenIn.address, spender: OneInch.router, amount: amountIn, label: L10n.tr("Approve \(tokenIn.symbol) for 1inch")),
                .call(tx, label: L10n.string(LocalizedStringResource("Swap on 1inch", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The venue's name is never translated.")),
                      notAfter: deadline, expectedSwap: terms),
            ]
        }
    }
}
