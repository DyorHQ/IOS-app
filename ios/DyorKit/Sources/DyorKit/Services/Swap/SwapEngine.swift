import BigInt
import Foundation

/// Asks every venue at once and ranks by output, publishing each venue's quote as it arrives (`quoteUpdates`). MON ↔ WMON
/// is a 1:1 wrap and never needs a venue.
///
/// xStocks (tokenized stocks) have one venue, 1inch, and one quote asset, USDC (`XStocks`). A known xStock on either side
/// is checked before any venue is asked and before any chain read (`xStockRefusal`): any other pair, an xStock the app
/// doesn't trade, and a buy or sell the wallet may not make now (`XStocksAvailability`) get no quote, and no AMM, Kuru
/// Flow or Monday Trade route ever touches an xStock. Every pair without one is asked exactly as before.
public actor SwapEngine {
    public static let quoteVenues: [Venue] = [.kuru, .uniswap, .monday]
    /// Every venue is quoted independently with this budget, so a slow venue never hides the others: their quotes show as
    /// they arrive, and the slow one's is waited for this long at most before the round is final.
    public static let quoteTimeout: TimeInterval = 20

    public let rpc: RPCClient
    private let multicall: Multicall
    /// The engine's URL session: Kuru Flow's, and DyorHQ's 1inch proxy's.
    private let session: URLSession
    private let kuru: KuruFlowClient
    private let uniswap: UniswapVenue
    private let monday: MondayVenue
    /// The xStocks known to this engine: the shipped registry, or a test's fixture.
    let xStocks: XStocks.Registry
    /// Each curated xStock's reference price, read through this engine's RPC.
    private let reference: XStockReference
    /// Whether this build has the stock venue (`OneInch.compiledIn`; a test may say otherwise).
    private let xStocksCompiledIn: Bool
    /// The owner's opt-in switch as the app last read it (`setXStocksFlag`); off until then.
    private var xStocksFlag = false
    /// The server's serving mode as the app last read it (`setXStocksServerStatus`); off until then.
    private var xStocksMode: XStocksAvailability.Mode = .off
    /// The wallets the server marks as beta wallets.
    private var xStocksBeta: Set<Address> = []
    /// When each wallet's server status was last read (`refreshXStocksStatus`), on the device's clock.
    private var xStocksStatusRead: [Address: ContinuousClock.Instant] = [:]
    /// The device's clock: a firm quote's deadline, and the age of a status read.
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// The wallets that acknowledged the current disclosure, as the app supplies them (`XStocksDisclosureStore`).
    private var xStocksAcknowledged: Set<Address> = []
    /// DyorHQ's 1inch proxy, when the app gave its URL and the session's credentials; nil leaves 1inch inert: it never
    /// quotes and nothing is sent.
    private let oneInch: OneInchVenue?

    /// `launchpadFactories` enables routes through graduated launchpad pools on Uniswap v4 — the live factory plus any
    /// retired one with the current 17-field record; each token's pool key is read from its own factory. `moments`
    /// enables routes through graduated Moment pools (coin ↔ USDC, hooked, 1.5% all-in). `cache`, the app's shared
    /// reads, keeps what the route search finds for a minute (`SwapRouteCache`), so an amount change or a re-quote costs
    /// each venue its one quote read; nil searches every time. `oneInchProxy` (the oneinch-proxy Edge Function's URL) and
    /// `oneInchCredentials` (the signed-in wallet's session headers, `SupabaseClient.sessionHeaders(for:)`) enable 1inch
    /// for xStocks in a build that has it (`OneInch.compiledIn`); without both, 1inch never quotes.
    public init(rpc: RPCClient, session: URLSession = .shared, launchpadFactories: [Address] = [], moments: MomentsAddresses? = nil, cache: ChainCache? = nil,
                oneInchProxy: URL? = nil, oneInchCredentials: (@Sendable (Address) async throws -> [String: String])? = nil) {
        self.init(rpc: rpc, session: session, launchpadFactories: launchpadFactories, moments: moments, cache: cache,
                  xStocks: XStocks.shipped, xStocksCompiledIn: OneInch.compiledIn, oneInchProxy: oneInchProxy, oneInchCredentials: oneInchCredentials)
    }

    /// `xStocks` as the registry and `xStocksCompiledIn` as the build's switch: a test's fixtures. `referenceRead` answers
    /// the reference feeds' reads in place of the RPC; `oneInchTransport` sends the proxy's requests in place of `session`,
    /// and `clock` is the device's clock for a firm quote's deadline.
    init(rpc: RPCClient, session: URLSession = .shared, launchpadFactories: [Address] = [], moments: MomentsAddresses? = nil, cache: ChainCache? = nil,
         xStocks: XStocks.Registry, xStocksCompiledIn: Bool, referenceRead: XStockReference.Reader? = nil,
         oneInchProxy: URL? = nil, oneInchCredentials: OneInchVenue.Credentials? = nil, oneInchTransport: OneInchVenue.Transport? = nil,
         clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.rpc = rpc
        self.session = session
        let multicall = Multicall(rpc: rpc)
        self.multicall = multicall
        let v3 = V3Router(multicall: multicall, cache: cache)
        kuru = KuruFlowClient(session: session)
        uniswap = UniswapVenue(multicall: multicall, v3: v3, launchpadFactories: launchpadFactories, moments: moments, cache: cache)
        monday = MondayVenue(v3: v3)
        self.xStocks = xStocks
        reference = XStockReference(stocks: xStocks, read: referenceRead ?? { try await multicall.read($0) })
        self.xStocksCompiledIn = xStocksCompiledIn
        self.clock = clock
        if let oneInchProxy, let oneInchCredentials {
            oneInch = OneInchVenue(proxy: oneInchProxy, credentials: oneInchCredentials,
                                   transport: oneInchTransport ?? OneInchVenue.transport(session), now: clock)
        } else {
            oneInch = nil
        }
    }

    public nonisolated static func isWrap(_ tokenIn: Token, _ tokenOut: Token) -> Bool {
        (tokenIn.isNative && tokenOut.address == Monad.wmon) || (tokenIn.address == Monad.wmon && tokenOut.isNative)
    }

    /// Gets ready to quote for `account` when Swap opens: asks for its Kuru Flow access token now, so the first quote
    /// doesn't wait a round trip for it (`KuruFlowClient.prepare(for:)`). Never fails; a quote that still needs the token
    /// asks for it itself.
    public func prepare(for account: Address) async {
        await kuru.prepare(for: account)
    }

    /// Every venue's answer, best output first, with a readable reason for each venue that gave none: the final result
    /// of `quoteUpdates` (`QuoteResult.isFinal`), for a caller that has no use for the answers as they arrive. A pair
    /// with a retired cohort's Moment coin on either side gets no quote from any venue, and no venue is even asked; nor
    /// does a buy of a coin still on a retired launchpad's curve (`buyRefusal`, asked alongside the on-chain venues, and
    /// before Kuru Flow).
    public func quotes(for request: SwapRequest) async -> QuoteResult {
        await round(request) { _ in }
    }

    /// One round of quotes for `request`, as it fills in: an update each time a venue answers, its quote ranked among
    /// those so far, its reason, or its timeout (`quoteTimeout`), with the venues still asked in `pending`; the last
    /// update is the final result (`QuoteResult.isFinal`), and the stream ends after it. An update before the last is
    /// only the best so far, which a slower venue may still beat: a screen may show it, but must review and sign only
    /// the final one. Cancelling the consumer's task ends the round and the stream without a final result.
    ///
    /// The check of the coin bought (`buyRefusal`) runs alongside the on-chain venues instead of before them: no update is
    /// published until it has cleared the coin, and a refusal ends the round at once with its reason under every venue
    /// and no quote, whatever a venue answered. Kuru Flow, a third party's API that is told the wallet and the pair, is
    /// asked a coin that may be a launchpad's only once the check has cleared it, so a refused buy never reaches it
    /// (`RetiredLaunchpads.swift`). A pair with a retired cohort's Moment coin on either side, an amount of zero and a
    /// wrap are answered at once, final, with no venue asked.
    public nonisolated func quoteUpdates(for request: SwapRequest) -> AsyncStream<QuoteResult> {
        // Only the newest update matters to a screen that falls behind; the final one is always the newest.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let final = await self.round(request) { continuation.yield($0) }
                if !Task.isCancelled { continuation.yield(final) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What a round's tasks answer: the coin check's refusal (nil: the coin may be bought), or one venue's outcome.
    private enum RoundAnswer: Sendable {
        case checked(SwapError?)
        case answered(Venue, Result<VenueQuote?, Error>)
    }

    /// One round (`quoteUpdates`): `publish` gets each update before the last, and the final result is returned.
    private func round(_ request: SwapRequest, publish: @escaping @Sendable (QuoteResult) -> Void) async -> QuoteResult {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) {
            return Self.refusedEverywhere(closed)
        }
        // Before any venue and any read: a stock trade not offered now asks no one.
        let venues = self.venues(for: request)
        if let refused = xStockRefusal(request) { return Self.refusedEverywhere(refused, venues: venues) }
        guard Self.isQuotable(request) else { return QuoteResult() }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return QuoteResult(quotes: [Self.wrapQuote(request)]) }
        // The venues asked only once the coin bought is cleared: Kuru Flow, for a coin that may be a launchpad's. The
        // on-chain venues read their pools alongside the check, telling no one the wallet, and show nothing before it.
        let afterCheck: Set<Venue> = needsLaunchCheck(request.tokenOut) ? [.kuru] : []
        return await withTaskGroup(of: RoundAnswer.self) { group in
            func askVenue(_ venue: Venue) {
                group.addTask {
                    do { return .answered(venue, .success(try await self.ask(venue, for: request))) } catch { return .answered(venue, .failure(error)) }
                }
            }
            group.addTask { .checked(await self.buyRefusal(request.tokenOut)) }
            for venue in venues where !afterCheck.contains(venue) { askVenue(venue) }
            var tally = QuoteTally(venues: venues)
            var cleared = false
            for await answer in group {
                switch answer {
                case .checked(let refused?):
                    // Nothing a venue answered for a coin that may not be bought is shown: the venues still asked are
                    // stopped, and the quotes so far dropped.
                    group.cancelAll()
                    return Self.refusedEverywhere(refused, venues: venues)
                case .checked(nil):
                    cleared = true
                    for venue in venues where afterCheck.contains(venue) { askVenue(venue) }
                case .answered(let venue, let outcome):
                    tally.record(venue, outcome)
                }
                if cleared, !tally.isComplete { publish(tally.result) }
            }
            return tally.result
        }
    }

    /// One venue's quote, or nil when it has no route. Throws with a readable message on failure or timeout, and —
    /// before any venue is asked — `SwapError.tradingClosed` when a retired cohort's Moment coin is on either side,
    /// `xStockRefusal`'s answer for a stock trade not offered now, `SwapError.xStocksUnavailable` when any venue but
    /// 1inch is asked for a stock pair, and `buyRefusal`'s answer when the coin bought is still on a retired launchpad's
    /// curve. One venue alone (no screen shows it as it arrives) checks the coin first, so a refused buy asks no venue.
    public func quote(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) { throw closed }
        if let refused = xStockRefusal(request) { throw refused }
        if venue != .oneInch, xStocks.touches(request.tokenIn, request.tokenOut) { throw SwapError.xStocksUnavailable(.venueNotOffered(venue)) }
        guard Self.isQuotable(request) else { return nil }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return venue == .wrap ? Self.wrapQuote(request) : nil }
        if venue == .wrap { return nil }
        // 1inch quotes nothing but a stock pair: for any other it gives nothing, before any read.
        if venue == .oneInch, xStocks.stockPair(request.tokenIn, request.tokenOut) == nil { return nil }
        if let refused = await buyRefusal(request.tokenOut) { throw refused }
        return try await ask(venue, for: request)
    }

    /// One venue's quote, within `quoteTimeout`: asked once the pair's checks passed, alongside the coin's in a round
    /// (`round`; Kuru Flow after it for a coin that may be a launchpad's), after it for one venue alone (`quote(_:for:)`).
    private func ask(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
        // The last line: no venue but 1inch is ever asked anything about a known xStock.
        if venue != .oneInch, xStocks.touches(request.tokenIn, request.tokenOut) { throw SwapError.xStocksUnavailable(.venueNotOffered(venue)) }
        return try await Self.withTimeout(Self.quoteTimeout, venue: venue) {
            switch venue {
            case .kuru: return try await self.kuru.quote(request)
            case .uniswap: return try await self.uniswap.quote(request)
            case .monday: return try await self.monday.quote(request)
            case .oneInch: return try await self.oneInchQuote(request, firm: false)
            case .wrap: return nil
            }
        }
    }

    // MARK: Past-cohort Moment coins

    /// The retired Moments cohorts' pool hooks. The app trades no past cohort's pool (on cohorts 1 and 2 a route through
    /// one also pays the retired platform wallet).
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

    // MARK: Retired launchpads' coins

    /// Why `token` may not be bought, or nil when it may. A coin still on a retired launchpad's curve (bonding, migrating
    /// or refund mode) is sell-only (owner decision 2026-09-28): its holders sell, nobody buys, so a buy of it gets
    /// `SwapError.retiredLaunchpad` under every venue and no quote. A round of quotes asks this alongside the on-chain
    /// venues, shows nothing they answer until it clears the coin, and asks Kuru Flow only then (`quoteUpdates`); one
    /// venue alone asks it first (`quote(_:for:)`). Read on-chain from every retired factory's record (`RetiredLaunchpad.sellOnlyCoins`); a coin
    /// that graduated into a pool trades both ways, and selling one is never checked. The app's own tokens (`Token.core`)
    /// and MON are no launchpad coin and need no read. A read that fails refuses too (`SwapError.launchpadUnchecked`):
    /// nothing could rule the coin out.
    public func buyRefusal(_ token: Token) async -> SwapError? {
        guard needsLaunchCheck(token) else { return nil }
        do {
            return try await RetiredLaunchpad.sellOnlyCoins([token.address], multicall: multicall).contains(token.address) ? .retiredLaunchpad(token.address) : nil
        } catch {
            return .launchpadUnchecked
        }
    }

    /// Whether `token` could be a launchpad coin at all: not MON, and none of the app's own tokens or curated xStocks
    /// (`Token.curatedReference`).
    nonisolated static func mayBeLaunchCoin(_ token: Token) -> Bool {
        !token.isNative && Token.curatedReference(token.address) == nil
    }

    /// `mayBeLaunchCoin`, with this engine's xStocks registry: a curated xStock needs no launchpad read.
    private func needsLaunchCheck(_ token: Token) -> Bool {
        Self.mayBeLaunchCoin(token) && xStocks.curatedToken(token.address) == nil
    }

    // MARK: xStocks

    /// The venues asked for `request`: 1inch alone for a curated xStock against USDC, `quoteVenues` for every other pair.
    public nonisolated func venues(for request: SwapRequest) -> [Venue] {
        xStocks.stockPair(request.tokenIn, request.tokenOut) == nil ? Self.quoteVenues : [.oneInch]
    }

    /// Why a trade touching a known xStock gets no quote now, or nil when it may be quoted (or touches none). Checked
    /// before any venue is asked and before any chain read, in a round (`quotes(for:)`, `quoteUpdates`) and for one venue
    /// alone (`quote(_:for:)`):
    /// - a known xStock the app doesn't trade, on either side: `notSupported`;
    /// - a curated xStock in any pair but against USDC, two stocks included: `pairNotOffered`;
    /// - a buy (the stock is received) while the wallet may not buy (`XStocksAvailability.canBuy`): `buyingClosed`;
    /// - a sell while selling is closed (`XStocksAvailability.canSell`): `sellingClosed`.
    public func xStockRefusal(_ request: SwapRequest) -> SwapError? {
        guard xStocks.touches(request.tokenIn, request.tokenOut) else { return nil }
        guard let pair = xStocks.stockPair(request.tokenIn, request.tokenOut) else {
            let uncurated = [request.tokenIn, request.tokenOut].contains { xStocks.isKnown($0.address) && xStocks.curatedToken($0.address) == nil }
            return .xStocksUnavailable(uncurated ? .notSupported : .pairNotOffered)
        }
        let availability = xStocksAvailability(for: request.account)
        if pair.isBuy { return availability.canBuy ? nil : .xStocksUnavailable(.buyingClosed) }
        return availability.canSell ? nil : .xStocksUnavailable(.sellingClosed)
    }

    /// What `wallet` may do with xStocks now, from what the app last supplied.
    public func xStocksAvailability(for wallet: Address) -> XStocksAvailability {
        XStocksAvailability(compiledIn: xStocksCompiledIn, flag: xStocksFlag, beta: xStocksBeta.contains(wallet), mode: xStocksMode,
                            disclosureAcknowledged: xStocksAcknowledged.contains(wallet))
    }

    /// The owner's opt-in switch (`RemoteFlags.xStocks`), each time the app reads it.
    public func setXStocksFlag(_ on: Bool) {
        xStocksFlag = on
    }

    /// The server's status for `wallet`: its serving mode, the same for every wallet, and whether `wallet` is a beta wallet.
    public func setXStocksServerStatus(mode: XStocksAvailability.Mode, beta: Bool, for wallet: Address) {
        xStocksMode = mode
        if beta { xStocksBeta.insert(wallet) } else { xStocksBeta.remove(wallet) }
    }

    /// The pair as a stock trade the app may offer (`XStocks.Registry.stockPair`): the curated xStock and whether it is
    /// bought. Nil for every other pair, so the Swap screen keeps its ordinary flow for them.
    public nonisolated func stockPair(_ tokenIn: Token, _ tokenOut: Token) -> (stock: Token, isBuy: Bool)? {
        xStocks.stockPair(tokenIn, tokenOut)
    }

    /// Reads the server's status for `wallet` from DyorHQ's 1inch proxy (its `status` route, which never asks 1inch)
    /// and keeps it (`setXStocksServerStatus`), unless one was read for the wallet within `maxAge`. Nothing is sent,
    /// and nothing changes, without 1inch configured and in this build, or for the placeholder account. Signed out, it
    /// throws `OneInchError.signedOut` and the proxy is told nothing. A failed read changes nothing: the mode stays as
    /// last read (off until a read), and the proxy checks it again on every quote anyway.
    public func refreshXStocksStatus(for wallet: Address, maxAge: Duration = .seconds(60)) async throws {
        guard let venue = oneInch, xStocksCompiledIn,
              wallet != SwapRequest.placeholderAccount, !wallet.isZero else { return }
        if let read = xStocksStatusRead[wallet], clock() - read < maxAge { return }
        let headers = try await venue.headers(for: wallet)
        let status = try await venue.status(headers: headers)
        setXStocksServerStatus(mode: status.mode, beta: status.beta, for: wallet)
        xStocksStatusRead[wallet] = clock()
    }

    /// The constant line a stock trade's review shows for its route: never the API's or the proxy's own text.
    public nonisolated static var oneInchRoute: String { OneInchVenue.route }

    /// Whether `wallet` acknowledged the current disclosure (`XStocksDisclosureStore`), as the app knows it.
    public func setXStocksDisclosure(acknowledged: Bool, for wallet: Address) {
        if acknowledged { xStocksAcknowledged.insert(wallet) } else { xStocksAcknowledged.remove(wallet) }
    }

    // MARK: 1inch

    /// The stock trade 1inch may be asked for `request` now, or nil, decided before anything is read or sent: 1inch must
    /// be configured (`oneInch`) and in this build (`OneInch.compiledIn`), the pair a curated xStock against USDC, the
    /// account a real wallet (never `SwapRequest.placeholderAccount`), the server's mode not off, and the wallet able to
    /// make this trade now (`XStocksAvailability.canBuy` for a buy, `canSell` for a sell).
    private func oneInchTrade(_ request: SwapRequest) -> OneInchVenue.Trade? {
        guard oneInch != nil, xStocksCompiledIn, request.amountIn > 0, let pair = xStocks.stockPair(request.tokenIn, request.tokenOut),
              request.account != SwapRequest.placeholderAccount, !request.account.isZero, xStocksMode != .off else { return nil }
        let availability = xStocksAvailability(for: request.account)
        guard pair.isBuy ? availability.canBuy : availability.canSell else { return nil }
        return OneInchVenue.Trade(request: request, stock: pair.stock, isBuy: pair.isBuy)
    }

    /// 1inch's quote for `request`: indicative, or `firm`. Nil, with nothing read or sent, when 1inch may not be asked
    /// (`oneInchTrade`). Then, in order: a buy over the per-trade cap is refused; the session's headers are read (signed
    /// out: `OneInchError.signedOut`, and the proxy is told nothing); the stock's reference price is read
    /// (`XStockReference`, its failure thrown); and only then is the proxy asked, its answer checked (`OneInchVenue`).
    private func oneInchQuote(_ request: SwapRequest, firm: Bool) async throws -> VenueQuote? {
        guard let venue = oneInch, let trade = oneInchTrade(request) else { return nil }
        try OneInchVenue.precheck(trade)
        let headers = try await venue.headers(for: request.account)
        let snapshot = try await reference.snapshot(for: trade.stock.address)
        if firm { return try await venue.firm(trade, headers: headers, reference: snapshot) }
        return try await venue.indicative(trade, headers: headers, reference: snapshot)
    }

    /// The firm 1inch quote for a stock trade, fetched once when the person taps Review: an issuer-signed RFQ whose
    /// `build` gives the exact router approval and the swap, bound to the device-measured deadline and the reviewed terms
    /// (`OneInchVenue.firmQuote`). The same checks as a round of quotes come first, before anything is read or sent: a
    /// retired Moment coin (`tradingClosed`) and a stock trade not offered now (`xStockRefusal`) throw; a trade 1inch may
    /// not be asked for is nil (`oneInchTrade`).
    public func firmQuote(for request: SwapRequest) async throws -> VenueQuote? {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) { throw closed }
        if let refused = xStockRefusal(request) { throw refused }
        guard Self.isQuotable(request) else { return nil }
        return try await oneInchQuote(request, firm: true)
    }

    /// Whether `owner`'s allowance of `token` to the 1inch router is exactly `amount`, so a stock trade needs no approval
    /// first: the router-exact rule (`TransactionSender.approvalIsCovered`), read in one aggregate. Swap asks it on the
    /// Review tap to choose between the approve-only sheet and the firm quote.
    public func routerAllowanceIsExact(token: Address, amount: BigUInt, owner: Address) async throws -> Bool {
        let allowance = try await multicall.readAll([try ERC20.allowance(token, owner: owner, spender: OneInch.router)])[0][0].uint
        return TransactionSender.approvalIsCovered(allowance: allowance, amount: amount, spender: OneInch.router)
    }

    /// `stock`'s reference price now, from its own feed (`XStockReference`). Throws `XStockReference.Failure` for a token
    /// that isn't a curated xStock with a feed, and for a feed that can't be read, isn't the reviewed one or is stale.
    public func referencePrice(for stock: Address) async throws -> XStockReference.Snapshot {
        try await reference.snapshot(for: stock)
    }

    // MARK: Helpers

    /// No quote, with `error`'s reason under every venue of `venues`.
    private static func refusedEverywhere(_ error: SwapError, venues: [Venue] = quoteVenues) -> QuoteResult {
        let reason = SwapMath.describe(error)
        return QuoteResult(errors: Dictionary(uniqueKeysWithValues: venues.map { ($0, reason) }))
    }

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
        return VenueQuote(venue: .wrap, amountOut: amount, minOut: amount, route: wrapping ? L10n.tr("Wrap MON → WMON, 1:1") : L10n.tr("Unwrap WMON → MON, 1:1"), gasEstimate: 50_000, priceImpactBps: 0) { _ in
            let request = wrapping
                ? TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonDeposit(), value: amount)
                : TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonWithdraw(amount: amount))
            return [.call(request, label: wrapping ? L10n.tr("Wrap MON") : L10n.tr("Unwrap WMON"))]
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

/// One round's answers as they arrive (`SwapEngine.quoteUpdates`): each venue's quote, or the reason it has none, and the
/// venues not heard from yet.
struct QuoteTally: Sendable {
    /// The venues asked, in the order ties are ranked and pending venues listed.
    let venues: [Venue]
    private var quotes: [Venue: VenueQuote] = [:]
    private var errors: [Venue: String] = [:]
    private var answered: Set<Venue> = []

    init(venues: [Venue]) {
        self.venues = venues
    }

    /// `venue`'s answer: its quote, no route (nil), or the failure or timeout that stopped it.
    mutating func record(_ venue: Venue, _ outcome: Result<VenueQuote?, Error>) {
        answered.insert(venue)
        switch outcome {
        case .success(let quote?):
            quotes[venue] = quote
            errors[venue] = nil
        case .success(nil):
            quotes[venue] = nil
            errors[venue] = L10n.tr("No route for this pair.")
        case .failure(let error):
            quotes[venue] = nil
            errors[venue] = SwapMath.describe(error)
        }
    }

    /// Every venue has answered.
    var isComplete: Bool { venues.allSatisfy(answered.contains) }

    /// The quotes so far, best output first (ties in venue order), every answered venue's reason for having none, and the
    /// venues still asked, in venue order: final (`QuoteResult.isFinal`) once every venue has answered.
    var result: QuoteResult {
        QuoteResult(quotes: SwapEngine.rank(venues.compactMap { quotes[$0] }), errors: errors, pending: venues.filter { !answered.contains($0) })
    }
}
