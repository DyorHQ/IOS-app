import BigInt
import XCTest
@testable import DyorKit

/// xStocks (tokenized stocks) with the registry this build ships EMPTY: everything is wired, and tested here against a
/// TEST-ONLY fixture registry (`XStockFixtures`) handed to the engine and the price finder, never shipped.
///
/// - Venue exclusivity: a known xStock on either side of any pair but a curated stock against USDC is refused by every
///   venue at every engine entry point (`quotes(for:)`, `quoteUpdates`, `quote(_:for:)`), and so is any venue but 1inch
///   for a stock pair, with no request of any kind sent (`NoNetworkStub` sees every one) and no reference read.
/// - A buy needs the wallet's full availability (`XStocksAvailability.canBuy`), a sell only the build and the mode.
/// - Ordinary pairs keep the venues and checks they had.
/// - The reference price (`XStockReference`) fails closed: stale by the feed's heartbeat, other decimals, a bad answer,
///   an unreadable read, a stock not listed.
/// - The price finder prices a curated xStock only from its reference and never looks a known one up in a pool.
/// - A known xStock the app doesn't trade shows "Tokenized stock: not supported".
final class XStocksVenueTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    private let oneUSDC = BigUInt(1_000_000)

    override func setUp() {
        super.setUp()
        NoNetworkStub.reset()
        XStockFixtures.reads.reset()
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token, _ amount: BigUInt = BigUInt(10).power(18), account: Address? = nil) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: 50, account: account ?? self.account)
    }

    /// An engine over the fixture registry whose every request is recorded and refused, and whose reference reads are
    /// counted; `open` makes `account` able to buy and sell, so only the pair decides.
    private func makeEngine(compiledIn: Bool = true, open: Bool = true) async -> SwapEngine {
        let engine = SwapEngine(rpc: NoNetworkStub.rpc(), session: NoNetworkStub.session(), xStocks: XStockFixtures.registry,
                                xStocksCompiledIn: compiledIn, referenceRead: XStockFixtures.reads.reader())
        if open {
            await engine.setXStocksFlag(true)
            await engine.setXStocksServerStatus(mode: .on, beta: false, for: account)
            await engine.setXStocksDisclosure(acknowledged: true, for: account)
        }
        return engine
    }

    /// Every update of a round, in order.
    private func updates(_ engine: SwapEngine, _ request: SwapRequest) async -> [QuoteResult] {
        var all: [QuoteResult] = []
        for await update in engine.quoteUpdates(for: request) { all.append(update) }
        return all
    }

    // MARK: Venue exclusivity

    /// A known xStock in any pair but a curated stock against USDC: every engine entry point refuses it for every venue,
    /// with its reason under each venue of the round, before any venue, chain read or reference read. The wallet may buy
    /// and sell stocks here, so only the pair is refused.
    func testAKnownXStockOutsideAStockPairIsRefusedEverywhereWithNoRequest() async throws {
        let engine = await makeEngine()
        let stock = XStockFixtures.stock, other = XStockFixtures.other, bridged = XStockFixtures.bridgedToken
        let usdt0 = try XCTUnwrap(Token.core(Monad.usdt0))
        let cases: [(SwapRequest, XStockRefusal)] = [
            (request(stock, .wmon), .pairNotOffered), (request(.mon, stock), .pairNotOffered), (request(stock, .mon), .pairNotOffered),
            (request(stock, other), .pairNotOffered), (request(usdt0, stock), .pairNotOffered), (request(stock, .ausd), .pairNotOffered),
            (request(bridged, .usdc), .notSupported), (request(.usdc, bridged), .notSupported), (request(bridged, .mon), .notSupported),
            (request(stock, bridged), .notSupported), (request(bridged, stock, oneUSDC), .notSupported),
        ]
        for (request, reason) in cases {
            let label = "\(request.tokenIn.symbol) → \(request.tokenOut.symbol)"
            let refusal = SwapError.xStocksUnavailable(reason)
            let refused = await engine.xStockRefusal(request)
            XCTAssertEqual(refused, refusal, label)
            XCTAssertEqual(engine.venues(for: request), SwapEngine.quoteVenues, "not a stock pair: \(label)")

            let result = await engine.quotes(for: request)
            XCTAssertTrue(result.quotes.isEmpty, label)
            XCTAssertTrue(result.isFinal, label)
            XCTAssertEqual(result.errors, Dictionary(uniqueKeysWithValues: SwapEngine.quoteVenues.map { ($0, reason.message) }), label)

            let streamed = await updates(engine, request)
            XCTAssertEqual(streamed.count, 1, "one final update: \(label)")
            XCTAssertEqual(streamed.last?.errors, result.errors, label)
            XCTAssertEqual(streamed.last?.quotes.isEmpty, true, label)

            for venue in Venue.allCases {
                do {
                    let quote = try await engine.quote(venue, for: request)
                    XCTFail("\(venue) quoted \(label): \(String(describing: quote))")
                } catch let error as SwapError {
                    XCTAssertEqual(error, refusal, "\(venue): \(label)")
                }
            }
        }
        XCTAssertEqual(NoNetworkStub.recorded(), [], "no request of any kind")
        XCTAssertEqual(XStockFixtures.reads.count, 0, "no reference read")
    }

    /// The same holds whatever the wallet may do: with nothing open, a pair that isn't offered is refused for being one,
    /// still before anything is asked.
    func testAPairNotOfferedIsRefusedForThatWhateverTheAvailability() async {
        let engine = await makeEngine(compiledIn: false, open: false)
        let refused = await engine.xStockRefusal(request(XStockFixtures.stock, .mon))
        XCTAssertEqual(refused, .xStocksUnavailable(.pairNotOffered))
        let bridged = await engine.xStockRefusal(request(.usdc, XStockFixtures.bridgedToken, oneUSDC))
        XCTAssertEqual(bridged, .xStocksUnavailable(.notSupported))
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// A curated stock against USDC has one venue, 1inch: every other venue is refused at once for it, in either
    /// direction, while 1inch (given no proxy here: inert) gives no quote; the round asks 1inch alone and says so under it,
    /// with no request sent and no launchpad check read.
    func testOnlyOneInchIsAskedForAStockPair() async throws {
        let engine = await makeEngine()
        for request in [request(.usdc, XStockFixtures.stock, oneUSDC), request(XStockFixtures.stock, .usdc)] {
            let label = "\(request.tokenIn.symbol) → \(request.tokenOut.symbol)"
            XCTAssertEqual(engine.venues(for: request), [.oneInch], label)
            let refused = await engine.xStockRefusal(request)
            XCTAssertNil(refused, label)
            for venue in Venue.allCases where venue != .oneInch {
                do {
                    _ = try await engine.quote(venue, for: request)
                    XCTFail("\(venue) answered for \(label)")
                } catch let error as SwapError {
                    XCTAssertEqual(error, .xStocksUnavailable(.venueNotOffered(venue)), label)
                }
            }
            let oneInch = try await engine.quote(.oneInch, for: request)
            XCTAssertNil(oneInch, "1inch has no proxy here: \(label)")

            let result = await engine.quotes(for: request)
            XCTAssertTrue(result.quotes.isEmpty, label)
            XCTAssertTrue(result.isFinal, label)
            XCTAssertEqual(Array(result.errors.keys), [.oneInch], "1inch alone is asked: \(label)")
            let streamed = await updates(engine, request)
            XCTAssertEqual(streamed.last?.errors.keys.sorted { $0.rawValue < $1.rawValue }, [.oneInch], label)
        }
        XCTAssertEqual(NoNetworkStub.recorded(), [], "no venue, chain or Kuru Flow request")
        XCTAssertEqual(XStockFixtures.reads.count, 0)
    }

    /// The venue refusal's message names the venue.
    func testAVenueRefusalNamesTheVenue() {
        XCTAssertTrue(XStockRefusal.venueNotOffered(.kuru).message.contains("Kuru Flow"))
        XCTAssertTrue(XStockRefusal.venueNotOffered(.uniswap).message.contains("Uniswap"))
        for reason in [XStockRefusal.notSupported, .pairNotOffered, .buyingClosed, .sellingClosed, .venueNotOffered(.monday)] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertEqual(SwapError.xStocksUnavailable(reason).errorDescription, reason.message)
        }
    }

    // MARK: Buying and selling

    /// A buy needs the build, the switch or the wallet's beta bit, the mode `on` and this wallet's disclosure; a sell
    /// only the build and a mode of `on` or `sell-only`. Every refusal is made before anything is asked.
    func testABuyIsRefusedUnlessTheWalletMayBuy() async {
        let buy = request(.usdc, XStockFixtures.stock, oneUSDC)
        let sell = request(XStockFixtures.stock, .usdc)
        let engine = await makeEngine(open: false)
        func refusals() async -> (buy: SwapError?, sell: SwapError?) {
            (await engine.xStockRefusal(buy), await engine.xStockRefusal(sell))
        }

        var now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed), "everything starts closed")
        XCTAssertEqual(now.sell, .xStocksUnavailable(.sellingClosed), "the mode is off until read")
        let closed = await engine.quotes(for: buy)
        XCTAssertEqual(closed.errors, [.oneInch: XStockRefusal.buyingClosed.message])

        await engine.setXStocksServerStatus(mode: .sellOnly, beta: false, for: account)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed))
        XCTAssertNil(now.sell, "sell-only serves sells, without the switch or the disclosure")

        await engine.setXStocksServerStatus(mode: .on, beta: false, for: account)
        await engine.setXStocksFlag(true)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed), "the disclosure isn't acknowledged")
        XCTAssertNil(now.sell)

        await engine.setXStocksDisclosure(acknowledged: true, for: stranger)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed), "another wallet's acknowledgement counts for nothing")

        await engine.setXStocksDisclosure(acknowledged: true, for: account)
        now = await refusals()
        XCTAssertNil(now.buy)
        let otherWallet = await engine.xStockRefusal(request(.usdc, XStockFixtures.stock, oneUSDC, account: stranger))
        XCTAssertNil(otherWallet, "the stranger acknowledged too")

        await engine.setXStocksFlag(false)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed), "the switch off")
        await engine.setXStocksServerStatus(mode: .on, beta: true, for: account)
        now = await refusals()
        XCTAssertNil(now.buy, "the beta bit stands in for the switch")
        let strangerNoBeta = await engine.xStockRefusal(request(.usdc, XStockFixtures.stock, oneUSDC, account: stranger))
        XCTAssertEqual(strangerNoBeta, .xStocksUnavailable(.buyingClosed), "the beta bit is the wallet's own")

        await engine.setXStocksDisclosure(acknowledged: false, for: account)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed), "beta wallets acknowledge too")

        await engine.setXStocksServerStatus(mode: .off, beta: true, for: account)
        await engine.setXStocksDisclosure(acknowledged: true, for: account)
        now = await refusals()
        XCTAssertEqual(now.buy, .xStocksUnavailable(.buyingClosed))
        XCTAssertEqual(now.sell, .xStocksUnavailable(.sellingClosed), "off blocks sells too")

        // A build without the venue refuses both, whatever else is open.
        let compiledOut = await makeEngine(compiledIn: false)
        let compiledOutBuy = await compiledOut.xStockRefusal(buy)
        let compiledOutSell = await compiledOut.xStockRefusal(sell)
        XCTAssertEqual(compiledOutBuy, .xStocksUnavailable(.buyingClosed))
        XCTAssertEqual(compiledOutSell, .xStocksUnavailable(.sellingClosed))
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    func testAvailability() {
        XCTAssertFalse(XStocksAvailability().canBuy)
        XCTAssertFalse(XStocksAvailability().canSell)
        XCTAssertEqual(XStocksAvailability().compiledIn, OneInch.compiledIn)
        let open = XStocksAvailability(compiledIn: true, flag: true, beta: false, mode: .on, disclosureAcknowledged: true)
        XCTAssertTrue(open.canBuy)
        XCTAssertTrue(open.canSell)
        var beta = open
        beta.flag = false
        beta.beta = true
        XCTAssertTrue(beta.canBuy)
        var sellOnly = open
        sellOnly.mode = .sellOnly
        XCTAssertFalse(sellOnly.canBuy)
        XCTAssertTrue(sellOnly.canSell)
        var undisclosed = open
        undisclosed.disclosureAcknowledged = false
        XCTAssertFalse(undisclosed.canBuy)
        XCTAssertTrue(undisclosed.canSell, "a sell never needs the disclosure")
        var off = open
        off.mode = .off
        XCTAssertFalse(off.canBuy)
        XCTAssertFalse(off.canSell)
        var compiledOut = open
        compiledOut.compiledIn = false
        XCTAssertFalse(compiledOut.canBuy)
        XCTAssertFalse(compiledOut.canSell)

        XCTAssertEqual(XStocksAvailability.Mode(serverValue: "on"), .on)
        XCTAssertEqual(XStocksAvailability.Mode(serverValue: "sell-only"), .sellOnly)
        for value in ["off", "ON", "sell_only", "", nil] as [String?] {
            XCTAssertEqual(XStocksAvailability.Mode(serverValue: value), .off, String(describing: value))
        }
    }

    /// The disclosure is acknowledged per wallet and per version: an earlier version's counts as none.
    func testTheDisclosureIsPerWalletAndVersioned() throws {
        let suite = "XStocksDisclosureStoreTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(XStocksDisclosureStore.isAcknowledged(account, defaults: defaults))
        XStocksDisclosureStore.acknowledge(account, defaults: defaults)
        XCTAssertTrue(XStocksDisclosureStore.isAcknowledged(account, defaults: defaults))
        XCTAssertFalse(XStocksDisclosureStore.isAcknowledged(stranger, defaults: defaults))
        defaults.set([account.hex.lowercased(): XStocksDisclosureStore.currentVersion - 1], forKey: XStocksDisclosureStore.defaultsKey)
        XCTAssertFalse(XStocksDisclosureStore.isAcknowledged(account, defaults: defaults), "an earlier version")
        XStocksDisclosureStore.acknowledge(account, defaults: defaults)
        XStocksDisclosureStore.acknowledge(stranger, defaults: defaults)
        XStocksDisclosureStore.forget(account, defaults: defaults)
        XCTAssertFalse(XStocksDisclosureStore.isAcknowledged(account, defaults: defaults))
        XCTAssertTrue(XStocksDisclosureStore.isAcknowledged(stranger, defaults: defaults))
    }

    // MARK: Ordinary pairs

    /// A pair with no known xStock is asked exactly as before: the same venues, no refusal, the launchpad check where it
    /// was; with the shipped (empty) registry nothing is an xStock at all.
    func testOrdinaryPairsAreUntouched() async throws {
        let fixture = await makeEngine()
        let shipped = SwapEngine(rpc: NoNetworkStub.rpc(), session: NoNetworkStub.session())
        let usdt0 = try XCTUnwrap(Token.core(Monad.usdt0))
        let coin = Token(address: Address(literal: "0x00000000000000000000000000000000000c0b01"), symbol: "COIN", name: "Coin", decimals: 18)
        for request in [request(.mon, .usdc), request(.usdc, .mon, oneUSDC), request(.mon, .wmon), request(usdt0, .usdc), request(.mon, coin)] {
            for engine in [fixture, shipped] {
                XCTAssertEqual(engine.venues(for: request), SwapEngine.quoteVenues)
                let refused = await engine.xStockRefusal(request)
                XCTAssertNil(refused)
            }
        }
        XCTAssertEqual(SwapEngine.quoteVenues, [.kuru, .uniswap, .monday])
        XCTAssertTrue(SwapEngine.mayBeLaunchCoin(coin))
        XCTAssertFalse(SwapEngine.mayBeLaunchCoin(.usdc))
        XCTAssertFalse(SwapEngine.mayBeLaunchCoin(.mon))
        // A wrap is still answered at once, with no venue asked.
        let wrap = await fixture.quotes(for: request(.mon, .wmon))
        XCTAssertEqual(wrap.quotes.map(\.venue), [.wrap])
        // 1inch is asked nothing for an ordinary pair, not even the launchpad check of a coin that may be one.
        for engine in [fixture, shipped] {
            let oneInch = try await engine.quote(.oneInch, for: request(.mon, coin))
            XCTAssertNil(oneInch)
        }
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// The registry this build ships is empty, so the app's tokens and behaviour are what they were.
    func testTheShippedRegistryIsEmpty() {
        XCTAssertTrue(XStocks.shipped.curated.isEmpty)
        XCTAssertTrue(XStocks.shipped.knownUncurated.isEmpty)
        XCTAssertTrue(XStocks.shipped.feeds.isEmpty)
        XCTAssertTrue(XStocks.curated.isEmpty)
        XCTAssertTrue(XStocks.feeds.isEmpty)
        XCTAssertEqual(XStocks.quoteAssets, [Monad.usdc])
        XCTAssertEqual(Token.curatedReference, Token.core)
        XCTAssertFalse(XStocks.isKnown(XStockFixtures.stock.address))
        XCTAssertEqual(TokenBadge.of(XStockFixtures.bridgedToken, coin: nil, receivedUnasked: false), .none, "no fixture ships")
    }

    // MARK: The registry

    /// A curated entry without a feed is never listed: it stays a known xStock, refused everywhere. A feed for a token
    /// that isn't curated is dropped. Only a curated stock against USDC is a stock pair.
    func testTheRegistry() {
        let unfed = Token(address: Address(literal: "0x7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"), symbol: "NOFx", name: "No Feed xStock", decimals: 18)
        let stray = Address(literal: "0x8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b")
        let registry = XStocks.Registry(curated: [XStockFixtures.stock, unfed], knownUncurated: [],
                                        feeds: [XStockFixtures.stock.address: XStockFixtures.feed, stray: XStockFixtures.feed])
        XCTAssertEqual(registry.curated, [XStockFixtures.stock])
        XCTAssertEqual(registry.knownUncurated, [unfed.address])
        XCTAssertEqual(Set(registry.feeds.keys), [XStockFixtures.stock.address])
        XCTAssertTrue(registry.isKnown(unfed.address))
        XCTAssertNil(registry.stockPair(.usdc, unfed))
        XCTAssertEqual(registry.quoteAssets, [Monad.usdc])

        let fixtures = XStockFixtures.registry
        XCTAssertEqual(fixtures.stockPair(.usdc, XStockFixtures.stock)?.isBuy, true)
        XCTAssertEqual(fixtures.stockPair(XStockFixtures.stock, .usdc)?.isBuy, false)
        XCTAssertEqual(fixtures.stockPair(XStockFixtures.stock, .usdc)?.stock, XStockFixtures.stock)
        XCTAssertNil(fixtures.stockPair(.ausd, XStockFixtures.stock))
        XCTAssertNil(fixtures.stockPair(XStockFixtures.stock, XStockFixtures.other))
        XCTAssertNil(fixtures.stockPair(.usdc, XStockFixtures.bridgedToken))
        XCTAssertTrue(fixtures.touches(.mon, XStockFixtures.bridgedToken))
        XCTAssertFalse(fixtures.touches(.mon, .usdc))
    }

    // MARK: Badge

    /// A known xStock the app doesn't trade shows "Tokenized stock: not supported" — a warning, never the imitation
    /// badge, whatever its name; a curated one shows nothing, even received unasked.
    func testAKnownUncuratedStockIsBadgedNotSupported() {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")
        let registry = XStockFixtures.registry
        let bridged = TokenBadge.of(XStockFixtures.bridgedToken, coin: nil, receivedUnasked: true, stocks: registry)
        XCTAssertEqual(bridged, .unsupportedStock)
        XCTAssertTrue(bridged.isWarning)
        XCTAssertFalse(bridged.isImitation)
        XCTAssertFalse(bridged.isDyorHQ)
        XCTAssertEqual(bridged.title, "Tokenized stock: not supported")
        let namedUSDC = Token(address: XStockFixtures.bridged, symbol: "USDC", name: "USDC", decimals: 6)
        XCTAssertEqual(TokenBadge.of(namedUSDC, coin: nil, receivedUnasked: false, stocks: registry), .unsupportedStock)
        XCTAssertEqual(TokenBadge.of(XStockFixtures.stock, coin: nil, receivedUnasked: true, stocks: registry), .none)
        XCTAssertEqual(TokenBadge.of(.usdc, coin: nil, receivedUnasked: true, stocks: registry), .none)
    }

    // MARK: The reference price

    /// A fresh answer is the stock's reference price, read in one aggregate with the block's timestamp: the feed's
    /// `latestRoundData()` and `decimals()`, and the token's `decimals()`.
    func testAFreshAnswerIsTheReferencePrice() async throws {
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        let snapshot = try await reference.snapshot(for: XStockFixtures.stock.address)
        XCTAssertEqual(snapshot.answer, XStockFixtures.answer)
        XCTAssertEqual(snapshot.decimals, 8)
        XCTAssertEqual(snapshot.usd, 250.12345678, accuracy: 1e-9)
        XCTAssertEqual(snapshot.age, 60)
        let calls = try XCTUnwrap(XStockFixtures.reads.batches.first)
        XCTAssertEqual(calls.map(\.to), [Multicall.address, XStockFixtures.feed.address, XStockFixtures.feed.address, XStockFixtures.stock.address])
        XCTAssertEqual(calls.map { $0.data.hexString }, ["0x0f28c97d", "0xfeaf968c", "0x313ce567", "0x313ce567"])
    }

    /// The answer as old as the heartbeat is fresh; a second older is stale, by the block's own clock.
    func testAnAnswerOlderThanTheHeartbeatIsStale() async throws {
        let heartbeat = UInt64(XStockFixtures.feed.heartbeat)
        XStockFixtures.reads.set(updatedAt: XStockFixtures.now - heartbeat)
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        let edge = try await reference.snapshot(for: XStockFixtures.stock.address)
        XCTAssertEqual(edge.age, heartbeat)
        XStockFixtures.reads.set(updatedAt: XStockFixtures.now - heartbeat - 1)
        await assertFails(reference, .stale(age: heartbeat + 1, heartbeat: XStockFixtures.feed.heartbeat))
        XCTAssertNotEqual(XStockReference.Failure.stale(age: 1, heartbeat: 0).errorDescription, XStockReference.Failure.unreadable.errorDescription)
    }

    /// Other decimals, from the feed or the token, refuse.
    func testOtherDecimalsRefuse() async {
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        XStockFixtures.reads.set(feedDecimals: 18)
        await assertFails(reference, .feedDecimals(expected: 8, found: 18))
        XStockFixtures.reads.reset()
        XStockFixtures.reads.set(tokenDecimals: 6)
        await assertFails(reference, .tokenDecimals(expected: 18, found: 6))
    }

    /// An answer of zero or less, a round answered by an earlier one, and an update stamped never or in the future refuse.
    func testABadAnswerRefuses() async {
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        for answer in [BigInt(0), BigInt(-1)] {
            XStockFixtures.reads.reset()
            XStockFixtures.reads.set(answer: answer)
            await assertFails(reference, .badAnswer)
        }
        XStockFixtures.reads.reset()
        XStockFixtures.reads.set(answeredInRound: XStockFixtures.roundId - 1)
        await assertFails(reference, .badAnswer)
        XStockFixtures.reads.reset()
        XStockFixtures.reads.set(updatedAt: 0)
        await assertFails(reference, .badAnswer)
        XStockFixtures.reads.reset()
        XStockFixtures.reads.set(updatedAt: XStockFixtures.now + 1)
        await assertFails(reference, .badAnswer)
    }

    /// A sub-call that failed, the timestamp that failed, and an aggregate that failed refuse; a token that isn't a
    /// curated xStock with a feed refuses with nothing read.
    func testWhatCantBeReadRefuses() async throws {
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        for failing in 0 ..< 4 {
            XStockFixtures.reads.reset()
            XStockFixtures.reads.set(failing: failing)
            await assertFails(reference, .unreadable)
        }
        XStockFixtures.reads.reset()
        XStockFixtures.reads.set(throwing: true)
        do {
            _ = try await reference.snapshot(for: XStockFixtures.stock.address)
            XCTFail("an aggregate that failed gives no price")
        } catch {}

        XStockFixtures.reads.reset()
        for address in [Monad.usdc, XStockFixtures.bridged] {
            await assertFails(reference, .notListed(address), stock: address)
        }
        let none = try await reference.snapshots(for: [Monad.usdc, XStockFixtures.bridged])
        XCTAssertEqual(none.count, 2)
        XCTAssertEqual(XStockFixtures.reads.count, 0, "nothing listed, nothing read")

        // The shipped engine and its empty registry know no stock.
        let shipped = SwapEngine(rpc: NoNetworkStub.rpc(), session: NoNetworkStub.session())
        do {
            _ = try await shipped.referencePrice(for: XStockFixtures.stock.address)
            XCTFail("no stock ships")
        } catch let failure as XStockReference.Failure {
            XCTAssertEqual(failure, .notListed(XStockFixtures.stock.address))
        }
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// Two stocks in one aggregate, each checked on its own.
    func testEachStockIsCheckedOnItsOwn() async throws {
        XStockFixtures.reads.set(feedDecimals: 18)
        let reference = XStockReference(stocks: XStockFixtures.registry, read: XStockFixtures.reads.reader())
        let read = try await reference.snapshots(for: [XStockFixtures.stock.address, XStockFixtures.other.address, XStockFixtures.stock.address])
        XCTAssertEqual(XStockFixtures.reads.batches.count, 1)
        XCTAssertEqual(XStockFixtures.reads.batches.first?.count, 7, "the timestamp and three reads per stock, each stock once")
        XCTAssertEqual(read[XStockFixtures.stock.address].flatMap { try? $0.get() }, nil, "its feed's decimals are wrong")
        XCTAssertEqual(try read[XStockFixtures.other.address]?.get().usd ?? 0, 250.12345678, accuracy: 1e-9)
    }

    private func assertFails(_ reference: XStockReference, _ failure: XStockReference.Failure, stock: Address = XStockFixtures.stock.address,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let snapshot = try await reference.snapshot(for: stock)
            XCTFail("priced at \(snapshot.usd)", file: file, line: line)
        } catch let error as XStockReference.Failure {
            XCTAssertEqual(error, failure, file: file, line: line)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    // MARK: Prices

    /// A curated xStock is priced only from its reference, with no 24h change; a known one the app doesn't trade has no
    /// price; neither is ever looked up in a pool (no request at all here), and neither has a chart.
    func testTheEngineAndThePriceFinderUseOnlyTheReference() async throws {
        let engine = await makeEngine()
        let fromEngine = try await engine.referencePrice(for: XStockFixtures.stock.address)
        XCTAssertEqual(fromEngine.usd, 250.12345678, accuracy: 1e-9)

        XStockFixtures.reads.reset()
        let prices = PriceService(rpc: NoNetworkStub.rpc())
        await prices.useXStocks(XStockFixtures.registry, read: XStockFixtures.reads.reader())
        let read = try await prices.prices(for: [XStockFixtures.stock, XStockFixtures.bridgedToken])
        let info = try XCTUnwrap(read[XStockFixtures.stock.address])
        XCTAssertEqual(info.usd, 250.12345678, accuracy: 1e-9)
        XCTAssertNil(info.change24h)
        XCTAssertEqual(info.source, XStockReference.sourceLabel)
        XCTAssertFalse(info.isDyorVenue)
        XCTAssertNil(read[XStockFixtures.bridged], "an untraded xStock has no price")
        XCTAssertEqual(XStockFixtures.reads.count, 1)
        let chart = try await prices.history(for: XStockFixtures.stock)
        XCTAssertEqual(chart, [])

        XStockFixtures.reads.set(updatedAt: XStockFixtures.now - UInt64(XStockFixtures.feed.heartbeat) - 1)
        let stale = try await prices.prices(for: [XStockFixtures.stock])
        XCTAssertNil(stale[XStockFixtures.stock.address], "a stale reference gives no price, never a pool's")
        XCTAssertEqual(NoNetworkStub.recorded(), [], "no pool lookup, no price read")
    }
}

// MARK: Fixtures

/// TEST-ONLY xStocks: addresses no token or feed has, used only here. None of them is in the shipped registry.
enum XStockFixtures {
    static let stock = Token(address: Address(literal: "0x7777777777777777777777777777777777777777"), symbol: "TSTx", name: "Test Stock xStock", decimals: 18)
    static let other = Token(address: Address(literal: "0x7878787878787878787878787878787878787878"), symbol: "OTHx", name: "Other Test xStock", decimals: 18)
    static let bridged = Address(literal: "0x7979797979797979797979797979797979797979")
    static let bridgedToken = Token(address: bridged, symbol: "BRGx", name: "Bridged Test xStock", decimals: 18)
    static let feed = XStocks.Feed(address: Address(literal: "0x8888888888888888888888888888888888888888"), heartbeat: 86_400, decimals: 8)
    static let otherFeed = XStocks.Feed(address: Address(literal: "0x8989898989898989898989898989898989898989"), heartbeat: 86_400, decimals: 8)
    static let registry = XStocks.Registry(curated: [stock, other], knownUncurated: [bridged],
                                           feeds: [stock.address: feed, other.address: otherFeed])

    /// The block's timestamp the reads answer at, the round and its answer ($250.12345678 with 8 decimals).
    static let now: UInt64 = 1_790_000_000
    static let roundId = BigUInt(42)
    static let answer = BigUInt(25_012_345_678)

    static let reads = Reads()

    /// The reference reads, answered from memory and counted: a fresh answer a minute old by default, with the feed's
    /// and the token's decimals as reviewed, unless a test sets otherwise. `failing` makes the call at that index of a
    /// stock's four (0 the timestamp, 1 the round, 2 the feed's decimals, 3 the token's) fail.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[ContractCall]] = []
        private var updatedAt = XStockFixtures.now - 60
        private var answer = BigInt(XStockFixtures.answer)
        private var answeredInRound = XStockFixtures.roundId
        private var feedDecimals = 8
        private var tokenDecimals = 18
        private var failing: Int?
        private var throwing = false

        func reset() {
            lock.lock(); defer { lock.unlock() }
            recorded = []
            updatedAt = XStockFixtures.now - 60
            answer = BigInt(XStockFixtures.answer)
            answeredInRound = XStockFixtures.roundId
            feedDecimals = 8
            tokenDecimals = 18
            failing = nil
            throwing = false
        }

        func set(updatedAt: UInt64? = nil, answer: BigInt? = nil, answeredInRound: BigUInt? = nil, feedDecimals: Int? = nil, tokenDecimals: Int? = nil,
                 failing: Int? = nil, throwing: Bool? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let updatedAt { self.updatedAt = updatedAt }
            if let answer { self.answer = answer }
            if let answeredInRound { self.answeredInRound = answeredInRound }
            if let feedDecimals { self.feedDecimals = feedDecimals }
            if let tokenDecimals { self.tokenDecimals = tokenDecimals }
            if let failing { self.failing = failing }
            if let throwing { self.throwing = throwing }
        }

        var batches: [[ContractCall]] { lock.lock(); defer { lock.unlock() }; return recorded }
        var count: Int { batches.count }

        func reader() -> XStockReference.Reader {
            { calls in try self.respond(calls) }
        }

        private struct Failed: Error {}

        private func respond(_ calls: [ContractCall]) throws -> [Result<[ABIValue], Error>] {
            lock.lock(); defer { lock.unlock() }
            recorded.append(calls)
            if throwing { throw Failed() }
            return calls.enumerated().map { index, call -> Result<[ABIValue], Error> in
                let slot = index == 0 ? 0 : (index - 1) % 3 + 1
                if slot == failing { return .failure(Failed()) }
                switch slot {
                case 0: return .success([.uint(BigUInt(XStockFixtures.now))])
                case 1: return .success([.uint(XStockFixtures.roundId), .int(answer), .uint(BigUInt(updatedAt)), .uint(BigUInt(updatedAt)), .uint(answeredInRound)])
                case 2: return .success([.uint(BigUInt(call.to == XStockFixtures.feed.address ? feedDecimals : 8))])
                default: return .success([.uint(BigUInt(tokenDecimals))])
                }
            }
        }
    }
}

/// Every request any client sends, recorded and refused (HTTP 400): a test that expects none checks `recorded()` is
/// empty, for the chain and every venue's API alike.
final class NoNetworkStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
    }

    static func recorded() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkStub.self]
        return URLSession(configuration: configuration)
    }

    static func rpc() -> RPCClient {
        RPCClient(url: URL(string: "https://rpc.no-network.invalid")!, session: session(), retries: 0)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.requests.append("\(url.host ?? "")\(url.path)"); Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
