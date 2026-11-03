import BigInt
import XCTest
@testable import DyorKit

/// The 1inch venue for xStocks, with no network: the proxy is answered by a closure (`ProxyStub`), the reference reads
/// from memory (`XStockFixtures`), and the clock is moved by the test (`ClockBox`). Every token here but USDC is a
/// TEST-ONLY fixture; the shipped registry stays empty and `OneInch.compiledIn` stays false.
///
/// - The proxy is never asked, and nothing at all is read, for a pair out of scope, a closed gate (no proxy, the build,
///   the mode, the wallet's availability), the placeholder account, a buy over the cap, a signed-out or mismatched
///   session; and nothing is sent before the reference price is read and found fresh.
/// - An indicative quote shows a price and can't be built; a firm quote's build is pure and gives exactly the router
///   approval and the swap, bound to a deadline counted from the stubbed send time only.
/// - Every answer is checked: the band below AND above the reference, the per-trade cap, the transaction's target,
///   sender, value and calldata (`OneInchSwap`), and the proxy's codes become the app's own sentences.
/// - The request is the same bytes in every language.
final class OneInchVenueTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    private let executor = Address(literal: "0x5555555555555555555555555555555555555555")
    private let proxy = URL(string: "https://project.supabase.invalid/functions/v1/oneinch-proxy")!
    private let headers = ["apikey": "sb_publishable_test", "Authorization": "Bearer session.jwt"]
    private let stock = XStockFixtures.stock
    private let usdc100 = BigUInt(100_000_000)

    override func setUp() {
        super.setUp()
        NoNetworkStub.reset()
        XStockFixtures.reads.reset()
    }

    // MARK: Fixtures

    /// The fixture stock at a round $100 (8-decimal feed), for exact band edges.
    private var hundred: XStockReference.Snapshot {
        XStockReference.Snapshot(stock: stock.address, answer: BigUInt(10_000_000_000), decimals: 8, stockDecimals: 18,
                                 updatedAt: XStockFixtures.now - 60, readAt: XStockFixtures.now)
    }

    private var oneStock: BigUInt { BigUInt(10).power(18) }

    private func request(_ tokenIn: Token, _ tokenOut: Token, _ amount: BigUInt, slippage: Int = 50, account: Address? = nil) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: slippage, account: account ?? self.account)
    }

    private func buy(_ usdc: BigUInt, slippage: Int = 50) -> OneInchVenue.Trade {
        .init(request: request(.usdc, stock, usdc, slippage: slippage), stock: stock, isBuy: true)
    }

    private func sell(_ amount: BigUInt, slippage: Int = 50) -> OneInchVenue.Trade {
        .init(request: request(stock, .usdc, amount, slippage: slippage), stock: stock, isBuy: false)
    }

    /// The fixture stock's reference value of `usdc`, in stock base units, at XStockFixtures' answer ($250.12345678).
    private func fairStock(_ usdc: BigUInt) -> BigUInt {
        usdc * BigUInt(10).power(26) / (XStockFixtures.answer * BigUInt(10).power(6))
    }

    private func swapData(_ trade: OneInchVenue.Trade, minReturn: BigUInt, receiver: Address? = nil, amount: BigUInt? = nil,
                          src: Address? = nil, dst: Address? = nil, flags: BigUInt = 0) -> Data {
        try! OneInchSwap.calldata(executor: executor, srcToken: src ?? trade.request.tokenIn.address, dstToken: dst ?? trade.request.tokenOut.address,
                                  srcReceiver: executor, dstReceiver: receiver ?? account, amount: amount ?? trade.request.amountIn,
                                  minReturn: minReturn, flags: flags, executorData: Data([0xab, 0xcd]))
    }

    private func answer(_ dstAmount: BigUInt, data: Data, to: Address = OneInch.router, from: Address? = nil, value: BigUInt = 0) -> OneInchVenue.FirmAnswer {
        .init(dstAmount: dstAmount, to: to, from: from ?? account, data: data, value: value)
    }

    /// A firm answer body as the proxy writes it, with `extra` top-level fields (time fields the app must ignore).
    private func firmBody(_ dstAmount: BigUInt, data: Data, extra: String = "") -> Data {
        Data(#"{"dstAmount":"\#(dstAmount)","tx":{"to":"\#(OneInch.router.hex)","from":"\#(account.hex)","data":"\#(data.hexString)","value":"0"}\#(extra)}"#.utf8)
    }

    private func assertThrows<T>(_ expected: OneInchError, _ label: String = "", file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), label, file: file, line: line) { XCTAssertEqual($0 as? OneInchError, expected, label, file: file, line: line) }
    }

    // MARK: The price band

    /// Within ±3% of the reference is admitted, edges included; one base unit past either edge is not, better or worse.
    func testTheBandRefusesBelowAndAbove() {
        let ref = hundred
        // A sell of one stock at $100: $97 to $103 for it.
        XCTAssertTrue(XStockPriceBand.admits(stock: oneStock, usdc: 100_000_000, reference: ref))
        XCTAssertTrue(XStockPriceBand.admits(stock: oneStock, usdc: 103_000_000, reference: ref))
        XCTAssertTrue(XStockPriceBand.admits(stock: oneStock, usdc: 97_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admits(stock: oneStock, usdc: 103_000_001, reference: ref), "above")
        XCTAssertFalse(XStockPriceBand.admits(stock: oneStock, usdc: 96_999_999, reference: ref), "below")
        // A buy of $103 for one stock is +3% exactly; a little less stock for it is past the edge.
        XCTAssertTrue(XStockPriceBand.admits(stock: oneStock, usdc: 103_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admits(stock: oneStock - 1, usdc: 103_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admits(stock: oneStock + 1, usdc: 97_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admits(stock: 0, usdc: 1, reference: ref))
        XCTAssertFalse(XStockPriceBand.admits(stock: 1, usdc: 0, reference: ref))

        // The worst case is one-sided: a buy's minimum may be any better, never more than 3% worse; a sell's the same.
        XCTAssertTrue(XStockPriceBand.admitsWorstCase(isBuy: true, stock: oneStock * 2, usdc: 100_000_000, reference: ref))
        XCTAssertTrue(XStockPriceBand.admitsWorstCase(isBuy: true, stock: oneStock, usdc: 103_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admitsWorstCase(isBuy: true, stock: oneStock, usdc: 103_000_001, reference: ref))
        XCTAssertTrue(XStockPriceBand.admitsWorstCase(isBuy: false, stock: oneStock, usdc: 500_000_000, reference: ref))
        XCTAssertTrue(XStockPriceBand.admitsWorstCase(isBuy: false, stock: oneStock, usdc: 97_000_000, reference: ref))
        XCTAssertFalse(XStockPriceBand.admitsWorstCase(isBuy: false, stock: oneStock, usdc: 96_999_999, reference: ref))

        XCTAssertEqual(XStockPriceBand.deviationBps(stock: oneStock, usdc: 101_000_000, reference: ref), 100)
        XCTAssertEqual(XStockPriceBand.deviationBps(stock: oneStock, usdc: 98_500_000, reference: ref), -150)
        XCTAssertNil(XStockPriceBand.deviationBps(stock: 0, usdc: 1, reference: ref))
        XCTAssertEqual(OneInch.priceBandBps, 300)
        XCTAssertEqual(OneInch.priceWarningBps, 100)
        XCTAssertEqual(OneInch.tradeCapUSDC, 250_000_000)
    }

    // MARK: Indicative

    /// An indicative quote shows the price and its minimum at the trade's slippage, and can never be built.
    func testAnIndicativeQuoteCannotBeBuilt() async throws {
        let trade = buy(usdc100, slippage: 50)
        let quote = try OneInchVenue.indicativeQuote(trade, dstAmount: oneStock, reference: hundred)
        XCTAssertEqual(quote.venue, .oneInch)
        XCTAssertEqual(quote.firmness, .indicative)
        XCTAssertNil(quote.deadline)
        XCTAssertEqual(quote.amountOut, oneStock)
        XCTAssertEqual(quote.minOut, SwapMath.minAfterSlippage(oneStock, bps: 50))
        XCTAssertEqual(quote.route, "Issuer RFQ via 1inch")
        do {
            _ = try await quote.build(account)
            XCTFail("an indicative quote built")
        } catch let error as SwapError {
            XCTAssertEqual(error, .reviewForFirmQuote)
            XCTAssertEqual(error.errorDescription, "This price is an estimate. Review the swap to get a firm quote.")
        }
        // A firm quote is what every other venue gives, by default.
        let other = VenueQuote(venue: .kuru, amountOut: 1, minOut: 1, route: "", gasEstimate: nil, priceImpactBps: nil) { _ in [] }
        XCTAssertEqual(other.firmness, .firm)
        XCTAssertNil(other.deadline)
    }

    /// The indicative price is checked against the reference both ways and against the cap, and its minimum on the
    /// costly side: a hostile API can't win the screen with a high quote.
    func testAnIndicativeQuoteOutsideTheBandIsRefused() {
        assertThrows(.priceOutOfBand, "below") { try OneInchVenue.indicativeQuote(buy(usdc100, slippage: 0), dstAmount: oneStock * 9_690 / 10_000, reference: hundred) }
        assertThrows(.priceOutOfBand, "above") { try OneInchVenue.indicativeQuote(buy(usdc100, slippage: 0), dstAmount: oneStock * 10_320 / 10_000, reference: hundred) }
        XCTAssertNoThrow(try OneInchVenue.indicativeQuote(buy(usdc100, slippage: 0), dstAmount: oneStock * 10_300 / 10_000, reference: hundred))
        // At 1% slippage, a price 2.5% worse puts the minimum 3.5% off: refused.
        assertThrows(.priceOutOfBand, "minimum") { try OneInchVenue.indicativeQuote(sell(oneStock, slippage: 100), dstAmount: 97_500_000, reference: hundred) }
        XCTAssertNoThrow(try OneInchVenue.indicativeQuote(sell(oneStock, slippage: 100), dstAmount: 99_000_000, reference: hundred))
        // Another stock's reference proves nothing.
        let other = XStockReference.Snapshot(stock: XStockFixtures.other.address, answer: hundred.answer, decimals: 8, stockDecimals: 18,
                                             updatedAt: hundred.updatedAt, readAt: hundred.readAt)
        assertThrows(.priceOutOfBand) { try OneInchVenue.indicativeQuote(buy(usdc100), dstAmount: oneStock, reference: other) }
    }

    /// $250 a trade: a buy pays at most that (refused before anything is asked), a sell receives at most that.
    func testTheCapHolds() {
        XCTAssertNoThrow(try OneInchVenue.precheck(buy(250_000_000)))
        assertThrows(.overCap) { try OneInchVenue.precheck(buy(250_000_001)) }
        XCTAssertNoThrow(try OneInchVenue.precheck(sell(oneStock * 10)), "a sell's worth is known from the answer")
        XCTAssertNoThrow(try OneInchVenue.indicativeQuote(sell(oneStock * 5 / 2, slippage: 0), dstAmount: 250_000_000, reference: hundred))
        assertThrows(.overCap) { try OneInchVenue.indicativeQuote(sell(oneStock * 3, slippage: 0), dstAmount: 300_000_000, reference: hundred) }
        XCTAssertEqual(OneInchError.overCap.errorDescription, "Each xStocks (tokenized stocks) trade is limited to $250 in DyorHQ.")
    }

    // MARK: Firm

    /// A firm quote's build is pure (it asks nothing) and always gives the exact router approval, then the swap, bound to
    /// the deadline (the send time plus the window, less the start margin) and to the reviewed terms; it refuses another
    /// wallet.
    func testAFirmBuildIsPureAndGivesTheApprovalAndTheSwap() async throws {
        let trade = buy(usdc100, slippage: 50)
        let minReturn = SwapMath.minAfterSlippage(oneStock, bps: 50)
        let data = swapData(trade, minReturn: minReturn)
        let sentAt = ContinuousClock.now
        let quote = try OneInchVenue.firmQuote(trade, answer: answer(oneStock, data: data), reference: hundred, sentAt: sentAt)
        XCTAssertEqual(quote.firmness, .firm)
        XCTAssertEqual(quote.amountOut, oneStock)
        XCTAssertEqual(quote.minOut, minReturn)
        let deadline = sentAt + .seconds(15)
        XCTAssertEqual(quote.deadline, deadline)
        XCTAssertEqual(OneInch.firmWindow - OneInch.startMargin, .seconds(15))

        let steps = try await quote.build(account)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .approve(token: Monad.usdc, spender: OneInch.router, amount: usdc100))
        XCTAssertEqual(steps[0].label, "Approve USDC for 1inch")
        XCTAssertNil(steps[0].notAfter)
        XCTAssertEqual(steps[1].kind, .call)
        XCTAssertEqual(steps[1].request, TransactionRequest(to: OneInch.router, data: data, value: 0))
        XCTAssertEqual(steps[1].label, "Swap on 1inch")
        XCTAssertEqual(steps[1].notAfter, deadline)
        XCTAssertEqual(steps[1].expectedSwap, .init(tokenIn: Monad.usdc, tokenOut: stock.address, amountIn: usdc100, minReturnFloor: minReturn))
        let again = try await quote.build(account)
        XCTAssertEqual(again, steps, "the same plan every time")
        do {
            _ = try await quote.build(stranger)
            XCTFail("built for another wallet")
        } catch let error as SwapError {
            XCTAssertEqual(error, .differentWallet)
        }
        // The swap step passes the run's own check of its terms.
        XCTAssertNoThrow(try TransactionSender.requireSwap(try XCTUnwrap(steps[1].request), matches: try XCTUnwrap(steps[1].expectedSwap), account: account))
        XCTAssertNil(ThirdPartyCalldataGuard.refusal(try XCTUnwrap(steps[1].request), account: account, chainId: Monad.chainId, compiledIn: true))
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// Every field of a firm answer that isn't exactly the trade reviewed is refused: target, sender, value, receiver,
    /// tokens, amount, flags, a minimum above the quote or below the slippage, a suffix, a retired coin in the route.
    func testAFirmAnswerThatIsntTheTradeIsRefused() throws {
        let trade = buy(usdc100, slippage: 50)
        let floor = SwapMath.minAfterSlippage(oneStock, bps: 50)
        let good = swapData(trade, minReturn: floor)
        XCTAssertNoThrow(try OneInchVenue.firmQuote(trade, answer: answer(oneStock, data: good), reference: hundred, sentAt: .now))
        XCTAssertNoThrow(try OneInchVenue.firmQuote(trade, answer: answer(oneStock, data: swapData(trade, minReturn: oneStock)), reference: hundred, sentAt: .now))
        let retired = try XCTUnwrap(MomentsAddresses.retiredMainnetCoins.keys.first)
        let mutations: [(String, OneInchVenue.FirmAnswer)] = [
            ("to Aqua", answer(oneStock, data: good, to: OneInch.aqua)),
            ("to Kuru", answer(oneStock, data: good, to: Kuru.entrypoint)),
            ("from another wallet", answer(oneStock, data: good, from: stranger)),
            ("with MON", answer(oneStock, data: good, value: 1)),
            ("paying another wallet", answer(oneStock, data: swapData(trade, minReturn: floor, receiver: stranger))),
            ("paying zero", answer(oneStock, data: swapData(trade, minReturn: floor, receiver: .zero))),
            ("more in", answer(oneStock, data: swapData(trade, minReturn: floor, amount: usdc100 + 1))),
            ("less in", answer(oneStock, data: swapData(trade, minReturn: floor, amount: usdc100 - 1))),
            ("another token in", answer(oneStock, data: swapData(trade, minReturn: floor, src: Monad.usdt0))),
            ("another token out", answer(oneStock, data: swapData(trade, minReturn: floor, dst: XStockFixtures.other.address))),
            ("flags", answer(oneStock, data: swapData(trade, minReturn: floor, flags: 4))),
            ("a minimum over the quote", answer(oneStock, data: swapData(trade, minReturn: oneStock + 1))),
            ("a minimum under the slippage", answer(oneStock, data: swapData(trade, minReturn: floor - 1))),
            ("a suffix", answer(oneStock, data: good + Data([0]))),
            ("another selector", answer(oneStock, data: Data([0x12, 0x34, 0x56, 0x78]) + good.dropFirst(4))),
            ("a retired coin in the route", answer(oneStock, data: try OneInchSwap.calldata(executor: executor, srcToken: Monad.usdc, dstToken: stock.address,
                                                                                             srcReceiver: executor, dstReceiver: account, amount: usdc100, minReturn: floor,
                                                                                             executorData: Data(count: 12) + retired.data))),
        ]
        for (label, mutated) in mutations {
            XCTAssertThrowsError(try OneInchVenue.firmQuote(trade, answer: mutated, reference: hundred, sentAt: .now), label) { error in
                if case SwapError.tradingClosed = error { return }
                XCTAssertEqual(error as? OneInchError, .unexpectedAnswer, label)
            }
        }
    }

    /// The firm price is checked both ways on the quoted amount, and on the minimum on the costly side; the cap on a
    /// sell's proceeds.
    func testAFirmPriceOutsideTheBandIsRefused() {
        func firm(_ trade: OneInchVenue.Trade, _ out: BigUInt, minReturn: BigUInt? = nil) throws -> VenueQuote {
            try OneInchVenue.firmQuote(trade, answer: answer(out, data: swapData(trade, minReturn: minReturn ?? out)), reference: hundred, sentAt: .now)
        }
        assertThrows(.priceOutOfBand, "buy below") { try firm(buy(usdc100, slippage: 0), oneStock * 9_690 / 10_000) }
        assertThrows(.priceOutOfBand, "buy above") { try firm(buy(usdc100, slippage: 0), oneStock * 10_320 / 10_000) }
        assertThrows(.priceOutOfBand, "sell below") { try firm(sell(oneStock, slippage: 0), 96_999_999) }
        assertThrows(.priceOutOfBand, "sell above") { try firm(sell(oneStock, slippage: 0), 103_000_001) }
        XCTAssertNoThrow(try firm(sell(oneStock, slippage: 0), 103_000_000))
        XCTAssertNoThrow(try firm(sell(oneStock, slippage: 0), 97_000_000))
        // A quote at the reference whose minimum (within the slippage) is more than 3% worse: refused.
        assertThrows(.priceOutOfBand, "minimum") { try firm(sell(oneStock, slippage: 100), 97_500_000, minReturn: 96_525_000) }
        assertThrows(.overCap) { try firm(sell(oneStock * 3, slippage: 0), 300_000_000) }
    }

    // MARK: Reading answers

    /// The proxy's codes become the app's own sentences; nothing the proxy or 1inch writes is ever shown.
    func testCodesMapToTheAppsSentences() {
        func failure(_ status: Int, _ body: String) -> OneInchError { OneInchVenue.failure(status: status, data: Data(body.utf8)) }
        XCTAssertEqual(failure(429, #"{"code":"rate_limited","retryAfter":120,"limit":"wallet"}"#), .rateLimited(retryAfter: 120))
        XCTAssertEqual(failure(429, #"{"code":"rate_limited","retryAfter":0.2}"#), .rateLimited(retryAfter: 1))
        XCTAssertEqual(failure(429, #"{"code":"rate_limited","retryAfter":"soon"}"#), .rateLimited(retryAfter: nil))
        XCTAssertEqual(failure(503, #"{"code":"busy","retryable":true}"#), .busy)
        XCTAssertEqual(failure(502, #"{"code":"upstream","retryable":true}"#), .busy)
        XCTAssertEqual(failure(422, #"{"code":"market_closed"}"#), .marketClosed)
        XCTAssertEqual(failure(503, #"{"code":"disabled"}"#), .disabled)
        XCTAssertEqual(failure(422, #"{"code":"pair_not_offered"}"#), .pairNotOffered)
        XCTAssertEqual(failure(409, #"{"code":"wallet_mismatch"}"#), .walletMismatch)
        XCTAssertEqual(failure(502, #"{"code":"unexpected_answer"}"#), .unexpectedAnswer)
        XCTAssertEqual(failure(403, #"{"code":"session"}"#), .signedOut)
        XCTAssertEqual(failure(422, #"{"code":"over_cap","max":"250000000"}"#), .overCap)
        XCTAssertEqual(failure(422, #"{"code":"no_route"}"#), .noRoute)
        XCTAssertEqual(failure(422, #"{"code":"refused","description":"Insufficient liquidity for 0xabc"}"#), .unavailable)
        XCTAssertEqual(failure(401, "<html>"), .signedOut)
        XCTAssertEqual(failure(429, ""), .rateLimited(retryAfter: nil))
        XCTAssertEqual(failure(500, "Internal error at 1inch"), .busy)
        XCTAssertEqual(failure(400, #"{"code":"bad_request"}"#), .unavailable)

        let all: [OneInchError] = [.signedOut, .rateLimited(retryAfter: nil), .rateLimited(retryAfter: 120), .busy, .marketClosed, .disabled, .pairNotOffered,
                                   .walletMismatch, .unexpectedAnswer, .overCap, .noRoute, .priceOutOfBand, .unavailable]
        let texts = all.compactMap(\.errorDescription)
        XCTAssertEqual(texts.count, all.count)
        XCTAssertEqual(Set(texts).count, all.count, "each its own sentence")
        XCTAssertEqual(OneInchError.rateLimited(retryAfter: 120).errorDescription,
                       "Too many xStocks (tokenized stocks) quotes from this wallet. Try again in 2 min.")
        XCTAssertEqual(OneInchError.signedOut.errorDescription, "Sign in to DyorHQ to trade xStocks (tokenized stocks).")
        XCTAssertEqual(SwapMath.describe(OneInchError.marketClosed), "This stock's market is closed right now. Try again when it opens.")
    }

    /// Answers are read strictly: a 2xx with anything but the documented shape is unexpected, and a refusal is its code.
    func testAnswersAreReadStrictly() throws {
        XCTAssertEqual(try OneInchVenue.quoteAnswer(Data(#"{"dstAmount":"123","protocols":[[]]}"#.utf8), status: 200), 123)
        for body in [#"{"dstAmount":123}"#, #"{"dstAmount":"0"}"#, #"{"dstAmount":"0123"}"#, #"{"dstAmount":"-1"}"#, #"{"dstAmount":"0x10"}"#,
                     #"{"dstAmount":"1 "}"#, #"{"dstAmount":"1e3"}"#, #"{"dstAmount":"\#(BigUInt(1) << 256)"}"#, #"[]"#, "", #"{}"#] {
            XCTAssertThrowsError(try OneInchVenue.quoteAnswer(Data(body.utf8), status: 200), body) { XCTAssertEqual($0 as? OneInchError, .unexpectedAnswer, body) }
        }
        XCTAssertThrowsError(try OneInchVenue.quoteAnswer(Data(#"{"dstAmount":"123"}"#.utf8), status: 503)) { XCTAssertEqual($0 as? OneInchError, .busy) }
        XCTAssertEqual(OneInchVenue.amount(.string(String(BigUInt(1) << 256 - 1))), (BigUInt(1) << 256) - 1)

        let data = swapData(buy(usdc100), minReturn: 1)
        let firm = try OneInchVenue.firmAnswer(firmBody(oneStock, data: data, extra: #","expiresAt":1,"serverTime":2"#), status: 200)
        XCTAssertEqual(firm, answer(oneStock, data: data))
        let tx = #""to":"\#(OneInch.router.hex)","from":"\#(account.hex)""#
        for body in [#"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString)","value":0}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString)","value":"1"}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString)"}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString.dropLast())","value":"0"}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"0x","value":"0"}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString.dropFirst(2))","value":"0"}}"#,
                     #"{"dstAmount":"1","tx":{\#(tx),"data":"\#(data.hexString)zz","value":"0"}}"#,
                     #"{"dstAmount":"1","tx":{"to":"0x1234","from":"\#(account.hex)","data":"\#(data.hexString)","value":"0"}}"#,
                     #"{"dstAmount":"1","tx":"\#(data.hexString)"}"#,
                     #"{"dstAmount":"1"}"#] {
            XCTAssertThrowsError(try OneInchVenue.firmAnswer(Data(body.utf8), status: 200), body) { XCTAssertEqual($0 as? OneInchError, .unexpectedAnswer, body) }
        }
    }

    /// The request is built from integers and hex only: the same bytes in any language, with the slippage clamped to the
    /// stock cap.
    func testTheRequestIsTheSameInEveryLanguage() throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        let big = BigUInt("123456789012345678901234567890", radix: 10)!
        let swap = request(.usdc, stock, big, slippage: 250)
        var bodies: [Data] = []
        var requests: [URLRequest] = []
        for identifier in ["en_US", "fr_FR", "ar_SA", "zh_Hans_CN"] {
            L10n.locale = Locale(identifier: identifier)
            bodies.append(try OneInchVenue.body(.swap, swap))
            requests.append(try OneInchVenue.urlRequest(proxy, .quote, swap, headers: headers))
        }
        XCTAssertEqual(Set(bodies).count, 1)
        XCTAssertEqual(Set(requests.map(\.httpBody)).count, 1)
        let expected = #"{"amount":"123456789012345678901234567890","dst":"\#(stock.address.hex)","from":"\#(account.hex)","slippageBps":100,"src":"\#(Monad.usdc.hex.lowercased())"}"#
        XCTAssertEqual(String(decoding: bodies[0], as: UTF8.self), expected)
        XCTAssertEqual(String(decoding: try OneInchVenue.body(.quote, swap), as: UTF8.self),
                       #"{"amount":"123456789012345678901234567890","dst":"\#(stock.address.hex)","src":"\#(Monad.usdc.hex.lowercased())"}"#)
        XCTAssertEqual(OneInchVenue.slippageBps(-5), 0)
        XCTAssertEqual(OneInchVenue.slippageBps(50), 50)

        let sent = requests[0]
        XCTAssertEqual(sent.url?.absoluteString, "https://project.supabase.invalid/functions/v1/oneinch-proxy/quote")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer session.jwt")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: Through the engine

    private func engine(_ stub: ProxyStub, clock: ClockBox = ClockBox(), proxy: URL?? = .none, compiledIn: Bool = true,
                        credentials: OneInchVenue.Credentials? = nil, open: Bool = true) async -> SwapEngine {
        let headers = self.headers
        let signedIn: OneInchVenue.Credentials = { _ in headers }
        let engine = SwapEngine(rpc: NoNetworkStub.rpc(), session: NoNetworkStub.session(), xStocks: XStockFixtures.registry,
                                xStocksCompiledIn: compiledIn, referenceRead: XStockFixtures.reads.reader(),
                                oneInchProxy: proxy ?? self.proxy, oneInchCredentials: credentials ?? signedIn,
                                oneInchTransport: stub.transport(), clock: { clock.now })
        if open {
            await engine.setXStocksFlag(true)
            await engine.setXStocksServerStatus(mode: .on, beta: false, for: account)
            await engine.setXStocksDisclosure(acknowledged: true, for: account)
        }
        return engine
    }

    /// Nothing is sent and nothing read for every trade 1inch may not be asked: an ordinary pair, a pair outside the stock
    /// pairs, no proxy configured, a build without 1inch, the mode off, a wallet that may not buy, the placeholder account.
    func testNothingIsSentWhenTheGateIsClosed() async throws {
        let stub = ProxyStub()
        let buyRequest = request(.usdc, stock, usdc100)
        let sellRequest = request(stock, .usdc, oneStock)

        // Ordinary and out-of-scope pairs: 1inch gives nothing, or the pair is refused, before anything.
        let open = await engine(stub)
        let ordinary = try await open.quote(.oneInch, for: request(.usdc, .mon, usdc100))
        XCTAssertNil(ordinary)
        let firmOrdinary = try await open.firmQuote(for: request(.usdc, .mon, usdc100))
        XCTAssertNil(firmOrdinary)
        XCTAssertEqual(open.venues(for: request(.usdc, .mon, usdc100)), SwapEngine.quoteVenues, "ordinary pairs keep their venues")
        do {
            _ = try await open.firmQuote(for: request(stock, .mon, oneStock))
            XCTFail("a stock against MON")
        } catch let error as SwapError {
            XCTAssertEqual(error, .xStocksUnavailable(.pairNotOffered))
        }

        // No proxy: inert.
        let inert = await engine(stub, proxy: .some(nil))
        let noProxy = try await inert.quote(.oneInch, for: buyRequest)
        XCTAssertNil(noProxy)
        let noProxyFirm = try await inert.firmQuote(for: buyRequest)
        XCTAssertNil(noProxyFirm)
        let inertRound = await inert.quotes(for: buyRequest)
        XCTAssertEqual(inertRound.errors, [.oneInch: "No route for this pair."])

        // Not compiled in: the refusal names it before anything.
        let off = await engine(stub, compiledIn: false)
        for request in [buyRequest, sellRequest] {
            do {
                _ = try await off.firmQuote(for: request)
                XCTFail("compiled out")
            } catch let error as SwapError {
                XCTAssertTrue([.xStocksUnavailable(.buyingClosed), .xStocksUnavailable(.sellingClosed)].contains(error))
            }
        }

        // The mode off, a wallet that may not buy.
        let closed = await engine(stub, open: false)
        let closedBuy = await closed.quotes(for: buyRequest)
        XCTAssertEqual(closedBuy.errors, [.oneInch: XStockRefusal.buyingClosed.message])
        await closed.setXStocksServerStatus(mode: .sellOnly, beta: false, for: account)
        let sellOnlyBuy = await closed.quotes(for: buyRequest)
        XCTAssertEqual(sellOnlyBuy.errors, [.oneInch: XStockRefusal.buyingClosed.message])

        // The placeholder account: a sell is open to it (no disclosure needed), and still nothing is asked.
        let placeholderSell = request(stock, .usdc, oneStock, account: SwapRequest.placeholderAccount)
        let placeholder = try await open.quote(.oneInch, for: placeholderSell)
        XCTAssertNil(placeholder)
        let placeholderFirm = try await open.firmQuote(for: placeholderSell)
        XCTAssertNil(placeholderFirm)
        await open.setXStocksDisclosure(acknowledged: true, for: SwapRequest.placeholderAccount)
        let placeholderBuy = try await open.quote(.oneInch, for: request(.usdc, stock, usdc100, account: SwapRequest.placeholderAccount))
        XCTAssertNil(placeholderBuy)
        let zeroSell = try await open.quote(.oneInch, for: request(stock, .usdc, oneStock, account: .zero))
        XCTAssertNil(zeroSell)

        XCTAssertEqual(stub.count, 0, "the proxy was never asked")
        XCTAssertEqual(XStockFixtures.reads.count, 0, "no reference read")
        XCTAssertEqual(NoNetworkStub.recorded(), [], "no chain or venue request")
    }

    /// Signed out or under another wallet's session: a readable reason, and the proxy is told nothing; a buy over the cap
    /// and a stale reference likewise send nothing.
    func testSignedOutMismatchCapAndStaleSendNothing() async throws {
        let stub = ProxyStub()
        let buyRequest = request(.usdc, stock, usdc100)
        let signedOut = await engine(stub, credentials: { _ in throw SupabaseError.notSignedIn })
        let round = await signedOut.quotes(for: buyRequest)
        XCTAssertEqual(round.errors, [.oneInch: "Sign in to DyorHQ to trade xStocks (tokenized stocks)."])
        do {
            _ = try await signedOut.firmQuote(for: buyRequest)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? OneInchError, .signedOut)
        }

        let mismatched = await engine(stub, credentials: { _ in throw SupabaseError.walletMismatch })
        do {
            _ = try await mismatched.firmQuote(for: buyRequest)
            XCTFail("another wallet's session")
        } catch SupabaseError.walletMismatch {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(XStockFixtures.reads.count, 0, "the session is checked before the reference is read")

        let open = await engine(stub)
        do {
            _ = try await open.quote(.oneInch, for: request(.usdc, stock, 250_000_001))
            XCTFail("over the cap")
        } catch {
            XCTAssertEqual(error as? OneInchError, .overCap)
        }
        XCTAssertEqual(XStockFixtures.reads.count, 0)

        XStockFixtures.reads.set(updatedAt: XStockFixtures.now - UInt64(XStockFixtures.feed.heartbeat) - 1)
        do {
            _ = try await open.firmQuote(for: buyRequest)
            XCTFail("a stale reference")
        } catch let failure as XStockReference.Failure {
            XCTAssertEqual(failure, .stale(age: UInt64(XStockFixtures.feed.heartbeat) + 1, heartbeat: XStockFixtures.feed.heartbeat))
        }
        XCTAssertEqual(XStockFixtures.reads.count, 1)
        XCTAssertEqual(stub.count, 0, "the proxy was never asked")
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// A round on a stock pair asks 1inch alone and shows its indicative quote, final, with nothing pending; the request
    /// went to the quote route after a fresh reference read.
    func testARoundShowsTheIndicativeQuote() async throws {
        let stub = ProxyStub()
        let fair = fairStock(usdc100)
        stub.answer = (Data(#"{"dstAmount":"\#(fair)"}"#.utf8), 200)
        let engine = await engine(stub)
        let buyRequest = request(.usdc, stock, usdc100)
        let result = await engine.quotes(for: buyRequest)
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.pending, [])
        XCTAssertEqual(result.errors, [:])
        let quote = try XCTUnwrap(result.best)
        XCTAssertEqual(quote.venue, .oneInch)
        XCTAssertEqual(quote.firmness, .indicative)
        XCTAssertEqual(quote.amountOut, fair)
        XCTAssertEqual(stub.paths, ["/functions/v1/oneinch-proxy/quote"])
        XCTAssertEqual(XStockFixtures.reads.count, 1)

        var streamed: [QuoteResult] = []
        for await update in engine.quoteUpdates(for: buyRequest) { streamed.append(update) }
        XCTAssertEqual(streamed.last?.best?.venue, .oneInch)
        XCTAssertEqual(streamed.last?.pending, [])

        // The proxy's refusal is said in the app's words under 1inch.
        stub.answer = (Data(#"{"code":"market_closed"}"#.utf8), 422)
        let closed = await engine.quotes(for: buyRequest)
        XCTAssertEqual(closed.errors, [.oneInch: OneInchError.marketClosed.errorDescription!])
        // A quote far above the reference is refused, not shown.
        stub.answer = (Data(#"{"dstAmount":"\#(fair * 2)"}"#.utf8), 200)
        let high = await engine.quotes(for: buyRequest)
        XCTAssertNil(high.best)
        XCTAssertEqual(high.errors, [.oneInch: OneInchError.priceOutOfBand.errorDescription!])
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// The firm quote's deadline comes from the device's clock read once, before the request is sent: time fields in the
    /// answer change nothing, and the time the answer took doesn't move it.
    func testTheDeadlineIsCountedFromTheSendTimeOnly() async throws {
        let stub = ProxyStub()
        let clock = ClockBox()
        let fair = fairStock(usdc100)
        let trade = OneInchVenue.Trade(request: request(.usdc, stock, usdc100, slippage: 50), stock: stock, isBuy: true)
        let data = swapData(trade, minReturn: SwapMath.minAfterSlippage(fair, bps: 50))
        stub.answer = (firmBody(fair, data: data, extra: #","expiresAt":9999999999,"timestamp":1,"deadline":"2030-01-01T00:00:00Z""#), 200)
        stub.onSend = {
            XCTAssertEqual(clock.reads, 1, "the send time is taken before the request")
            clock.advance(.seconds(4))
        }
        let engine = await engine(stub, clock: clock)
        let firm = try await engine.firmQuote(for: trade.request)
        let quote = try XCTUnwrap(firm)
        XCTAssertEqual(quote.firmness, .firm)
        XCTAssertEqual(quote.deadline, clock.start + .seconds(15))
        XCTAssertEqual(clock.reads, 1)
        XCTAssertEqual(stub.paths, ["/functions/v1/oneinch-proxy/swap"])
        let body = try XCTUnwrap(stub.bodies.first)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"amount":"100000000","dst":"\#(stock.address.hex)","from":"\#(account.hex)","slippageBps":50,"src":"\#(Monad.usdc.hex.lowercased())"}"#)
        let steps = try await quote.build(account)
        XCTAssertEqual(steps.map(\.notAfter), [nil, clock.start + .seconds(15)])
        XCTAssertEqual(stub.count, 1, "building asks nothing")
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    // MARK: The server's status

    /// The status answer is read strictly: a JSON boolean beta bit, and a mode the app doesn't know is off; a refusal is
    /// said in the app's words. The request names nothing about a trade.
    func testTheStatusIsReadStrictly() throws {
        XCTAssertEqual(try OneInchVenue.statusAnswer(Data(#"{"mode":"on","beta":true,"termsVersion":1}"#.utf8), status: 200),
                       .init(mode: .on, beta: true))
        XCTAssertEqual(try OneInchVenue.statusAnswer(Data(#"{"mode":"sell-only","beta":false}"#.utf8), status: 200),
                       .init(mode: .sellOnly, beta: false))
        for unknown in [#"{"mode":"ON","beta":false}"#, #"{"mode":"maybe","beta":false}"#, #"{"mode":1,"beta":false}"#, #"{"beta":false}"#] {
            XCTAssertEqual(try OneInchVenue.statusAnswer(Data(unknown.utf8), status: 200), .init(mode: .off, beta: false), unknown)
        }
        for malformed in [#"{"mode":"on"}"#, #"{"mode":"on","beta":"true"}"#, #"{"mode":"on","beta":1}"#, #"[]"#, "<html>", ""] {
            assertThrows(.unexpectedAnswer, malformed) { try OneInchVenue.statusAnswer(Data(malformed.utf8), status: 200) }
        }
        assertThrows(.signedOut) { try OneInchVenue.statusAnswer(Data(#"{"code":"session"}"#.utf8), status: 401) }
        assertThrows(.rateLimited(retryAfter: 30)) { try OneInchVenue.statusAnswer(Data(#"{"code":"rate_limited","retryAfter":30}"#.utf8), status: 429) }

        let request = OneInchVenue.statusRequest(proxy, headers: headers)
        XCTAssertEqual(request.url?.absoluteString, "https://project.supabase.invalid/functions/v1/oneinch-proxy/status")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session.jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
    }

    /// The engine reads the status only with 1inch configured and in the build, for a real wallet with a session; it
    /// keeps what it read (the mode and the wallet's beta bit open a buy with the disclosure), reads again only after a
    /// minute unless asked to, and a failed read changes nothing.
    func testTheEngineReadsTheStatusOnlyWhenItMay() async throws {
        let stub = ProxyStub()
        stub.answer = (Data(#"{"mode":"on","beta":true,"termsVersion":1}"#.utf8), 200)
        let clock = ClockBox()

        let compiledOut = await engine(stub, compiledIn: false, open: false)
        try await compiledOut.refreshXStocksStatus(for: account)
        let noProxy = await engine(stub, proxy: .some(nil), open: false)
        try await noProxy.refreshXStocksStatus(for: account)
        let engine = await engine(stub, clock: clock, open: false)
        try await engine.refreshXStocksStatus(for: SwapRequest.placeholderAccount)
        try await engine.refreshXStocksStatus(for: .zero)
        XCTAssertEqual(stub.count, 0, "nothing is sent without 1inch, or for no real wallet")
        let closed = await engine.xStocksAvailability(for: account)
        XCTAssertEqual(closed.mode, .off)

        let signedOut = await self.engine(stub, credentials: { _ in throw SupabaseError.notSignedIn }, open: false)
        do {
            try await signedOut.refreshXStocksStatus(for: account)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? OneInchError, .signedOut)
        }
        XCTAssertEqual(stub.count, 0, "the proxy is told nothing without a session")

        try await engine.refreshXStocksStatus(for: account)
        XCTAssertEqual(stub.paths, ["/functions/v1/oneinch-proxy/status"])
        var read = await engine.xStocksAvailability(for: account)
        XCTAssertEqual(read.mode, .on)
        XCTAssertTrue(read.beta)
        XCTAssertFalse(read.canBuy, "the notice is still unread")
        await engine.setXStocksDisclosure(acknowledged: true, for: account)
        read = await engine.xStocksAvailability(for: account)
        XCTAssertTrue(read.canBuy, "the beta bit stands in for the switch")

        try await engine.refreshXStocksStatus(for: account)
        XCTAssertEqual(stub.count, 1, "read again only after a minute")
        try await engine.refreshXStocksStatus(for: account, maxAge: .zero)
        XCTAssertEqual(stub.count, 2, "unless asked to")
        clock.script = [.seconds(61)]
        try await engine.refreshXStocksStatus(for: account)
        XCTAssertEqual(stub.count, 3)

        // A failed read keeps what was read last.
        stub.answer = (Data(#"{"code":"busy"}"#.utf8), 503)
        do {
            try await engine.refreshXStocksStatus(for: account, maxAge: .zero)
            XCTFail("busy")
        } catch {
            XCTAssertEqual(error as? OneInchError, .busy)
        }
        let kept = await engine.xStocksAvailability(for: account)
        XCTAssertEqual(kept.mode, .on)
        // The server turns it off: the engine follows.
        stub.answer = (Data(#"{"mode":"off","beta":false}"#.utf8), 200)
        try await engine.refreshXStocksStatus(for: account, maxAge: .zero)
        let off = await engine.xStocksAvailability(for: account)
        XCTAssertEqual(off.mode, .off)
        XCTAssertFalse(off.canBuy)
        XCTAssertFalse(off.canSell)
        XCTAssertEqual(XStockFixtures.reads.count, 0, "no reference read for a status")
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }

    /// The Swap screen's helpers: the stock pair as the registry reads it, and the constant route line.
    func testTheScreenSeesTheStockPairAndAConstantRoute() async {
        let engine = await engine(ProxyStub())
        XCTAssertEqual(engine.stockPair(.usdc, stock)?.stock, stock)
        XCTAssertEqual(engine.stockPair(.usdc, stock)?.isBuy, true)
        XCTAssertEqual(engine.stockPair(stock, .usdc)?.isBuy, false)
        XCTAssertNil(engine.stockPair(.usdc, .mon))
        XCTAssertNil(engine.stockPair(stock, .mon))
        XCTAssertEqual(SwapEngine.oneInchRoute, "Issuer RFQ via 1inch")
        // The shipped registry is empty: no pair is a stock pair in this build.
        let shipped = SwapEngine(rpc: NoNetworkStub.rpc(), session: NoNetworkStub.session())
        XCTAssertNil(shipped.stockPair(.usdc, stock))
        XCTAssertEqual(OneInch.priceChangedBps, 50)
    }

    // MARK: The session's headers

    /// The proxy's headers are the signed-in wallet's only: none without a session, and none for another wallet.
    func testSessionHeadersAreForTheSignedInWalletOnly() async throws {
        let client = SupabaseClient(url: URL(string: "https://project.supabase.invalid")!, anonKey: "sb_publishable_test", session: NoNetworkStub.session())
        let wallet = Address(literal: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd")
        do {
            _ = try await client.sessionHeaders(for: wallet)
            XCTFail("no session")
        } catch SupabaseError.notSignedIn {}
        await client.restore(SupabaseSession(accessToken: "session.jwt", wallet: wallet.checksummed, expiresAt: Date().addingTimeInterval(3600)))
        let mine = try await client.sessionHeaders(for: wallet)
        XCTAssertEqual(mine, ["apikey": "sb_publishable_test", "Authorization": "Bearer session.jwt"])
        await client.restore(SupabaseSession(accessToken: "session.jwt", wallet: "0x" + wallet.hex.dropFirst(2).uppercased(),
                                             expiresAt: Date().addingTimeInterval(3600)))
        let anyCase = try await client.sessionHeaders(for: wallet)
        XCTAssertEqual(anyCase["Authorization"], "Bearer session.jwt", "compared without regard to case")
        do {
            _ = try await client.sessionHeaders(for: stranger)
            XCTFail("another wallet")
        } catch SupabaseError.walletMismatch {}
        XCTAssertEqual(SupabaseError.walletMismatch.errorDescription, "The wallet signed in to DyorHQ isn't this one. Sign in again with this wallet.")
        XCTAssertEqual(NoNetworkStub.recorded(), [])
    }
}

/// The passkey policy's binding of a 1inch swap to the stock's reference price (`Mera.SigningPolicy.refusal(reference:)`):
/// with 1inch compiled in for the check, a declared swap read in full is still refused at a price outside the band,
/// either way, or against another stock's reference. The fixture stock is at a round $100.
final class MeraOneInchReferenceTests: XCTestCase {
    typealias Policy = Mera.SigningPolicy
    typealias Intent = Mera.Intent

    let account = Address(literal: "0x1111111111111111111111111111111111111111")
    let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    let executor = Address(literal: "0x5555555555555555555555555555555555555555")
    let stock = XStockFixtures.stock.address
    let usdcIn = BigUInt(100_000_000)
    let oneStock = BigUInt(10).power(18)

    var reference: XStockReference.Snapshot {
        .init(stock: stock, answer: BigUInt(10_000_000_000), decimals: 8, stockDecimals: 18, updatedAt: 1, readAt: 2)
    }

    private func call(_ data: Data) -> Policy.Call { Policy.Call(from: account, to: OneInch.router, data: data, value: 0) }

    private func buy(declared: BigUInt, minReturn: BigUInt, receiver: Address? = nil) -> (Policy.Call, Intent) {
        let data = try! OneInchSwap.calldata(executor: executor, srcToken: Monad.usdc, dstToken: stock, srcReceiver: executor,
                                             dstReceiver: receiver ?? account, amount: usdcIn, minReturn: minReturn)
        return (call(data), .swap(venue: .oneInch, pay: .init(token: Monad.usdc, amount: usdcIn), receive: .init(token: stock, amount: declared), usd: 100))
    }

    private func sell(declared: BigUInt, minReturn: BigUInt) -> (Policy.Call, Intent) {
        let data = try! OneInchSwap.calldata(executor: executor, srcToken: stock, dstToken: Monad.usdc, srcReceiver: executor,
                                             dstReceiver: account, amount: oneStock, minReturn: minReturn)
        return (call(data), .swap(venue: .oneInch, pay: .init(token: stock, amount: oneStock), receive: .init(token: Monad.usdc, amount: declared), usd: 100))
    }

    private func refusal(_ pair: (Policy.Call, Intent), reference: XStockReference.Snapshot?) -> Policy.Reason? {
        Policy.oneInchRefusal(pair.0, intent: pair.1, account: account, compiledIn: true, reference: reference)
    }

    func testTheReferenceBandBindsTheSwap() {
        // At the reference, minimum at 1% slippage: admitted.
        XCTAssertNil(refusal(buy(declared: oneStock, minReturn: oneStock * 99 / 100), reference: reference))
        XCTAssertNil(refusal(sell(declared: usdcIn, minReturn: 99_000_000), reference: reference))
        // The declared output outside the band, below and above, is refused; so is any swap with no reference.
        let low = buy(declared: oneStock * 9_690 / 10_000, minReturn: oneStock * 9_690 / 10_000)
        XCTAssertEqual(refusal(low, reference: reference), .stockPrice)
        XCTAssertEqual(refusal(low, reference: nil), .stockPrice, "no reference refuses")
        XCTAssertEqual(refusal(buy(declared: oneStock, minReturn: oneStock * 99 / 100), reference: nil), .stockPrice, "even at the price")
        XCTAssertEqual(refusal(buy(declared: oneStock * 10_320 / 10_000, minReturn: oneStock * 10_320 / 10_000), reference: reference), .stockPrice)
        XCTAssertEqual(refusal(sell(declared: 103_000_001, minReturn: 103_000_001), reference: reference), .stockPrice)
        XCTAssertEqual(refusal(sell(declared: 96_999_999, minReturn: 96_999_999), reference: reference), .stockPrice)
        // A minimum within the slippage limit but more than 3% off the reference.
        XCTAssertEqual(refusal(sell(declared: 97_500_000, minReturn: 96_525_000), reference: reference), .stockPrice)
        // Another stock's reference, or a pair that isn't the stock against USDC.
        let other = XStockReference.Snapshot(stock: XStockFixtures.other.address, answer: reference.answer, decimals: 8, stockDecimals: 18, updatedAt: 1, readAt: 2)
        XCTAssertEqual(refusal(buy(declared: oneStock, minReturn: oneStock), reference: other), .stockPrice)
        // The other bindings come first.
        XCTAssertEqual(refusal(buy(declared: oneStock, minReturn: oneStock, receiver: stranger), reference: reference), .recipient)
        XCTAssertEqual(refusal(buy(declared: oneStock, minReturn: oneStock * 98 / 100), reference: reference), .stockMinimumOut)
        // Through the public entry point, as the wallet calls it; with 1inch off in this build every router call is refused.
        let pair = buy(declared: oneStock, minReturn: oneStock)
        XCTAssertEqual(Policy.refusal(pair.0, intent: pair.1, account: account, reference: reference), .unreadableSwap)
        XCTAssertEqual(Policy.Reason.stockPrice.summary, "a price too far from the stock’s reference price")
    }
}

/// The proxy, answered from memory: every request it is sent is recorded (`count`, `paths`, `bodies`), `onSend` runs as
/// each arrives, and `answer` is the body and status sent back.
final class ProxyStub: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var reply: (Data, Int) = (Data(), 500)
    private var hook: (@Sendable () -> Void)?

    var answer: (Data, Int) {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }

    var onSend: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    var count: Int { lock.withLock { sent.count } }
    var paths: [String] { lock.withLock { sent.compactMap { $0.url?.path } } }
    var bodies: [Data] { lock.withLock { sent.compactMap(\.httpBody) } }

    func transport() -> OneInchVenue.Transport {
        { request in
            self.onSend?()
            return self.lock.withLock {
                self.sent.append(request)
                return self.reply
            }
        }
    }
}
