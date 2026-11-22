import XCTest
@testable import DyorKit

/// The Swap screen's xStocks (tokenized stocks) flow, read from the app's sources (the app target doesn't build here).
///
/// - Every pair that isn't a stock pair keeps the one Review button and sheet it always had.
/// - A stock trade's Review never reviews the estimate: it reads the router's allowance, signs an exact approval in a
///   sheet of its own when that isn't exactly the amount, then fetches the firm quote and opens a review built from that
///   quote alone, whose last check before signing is the switches and the deadline.
/// - The route shown is DyorHQ's constant line, never text from 1inch or the proxy, and the single venue is no "Best".
/// - A buy asks nothing until the wallet has acknowledged the notice, which signing out forgets.
/// - The environment wires the proxy with the wallet's own session, and hands the owner's switch to the engine.
final class XStocksSwapScreenTests: XCTestCase {
    private func swap() throws -> String { AppSource.squeezed(try AppSource.app("Swap/SwapView.swift")) }

    func testOrdinaryPairsKeepTheirReview() throws {
        let swap = try swap()
        XCTAssertTrue(swap.contains("if env.swap.stockPair(model.tokenIn, model.tokenOut) == nil { PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.selectedQuote == nil || model.insufficient || !session.canSign) { reviewing = model.review }"))
        XCTAssertTrue(swap.contains(".sheet(item: $reviewing) { review in confirmation(review) }"))
        XCTAssertTrue(swap.contains(".task(id: model.quoteKey) { await model.quote(env: env, account: model.account) }"))
        XCTAssertTrue(swap.contains("var review: SwapReview? { guard let quote = selectedQuote else { return nil } return SwapReview(quote: quote, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps, payUSD: payUSD, receiveUSD: receiveUSD) }"),
                      "an ordinary review carries no stock terms")
        // The stock checks run only for a stock pair, before anything is asked.
        XCTAssertTrue(swap.contains("while !Task.isCancelled { // A stock pair's own checks come before anything is asked for it (`prepareStock`). if let pair = env.swap.stockPair(tokenIn, tokenOut) { guard await prepareStock(isBuy: pair.isBuy, env: env, account: account) else { return } } quoting = true"))
    }

    func testAStockReviewIsBuiltFromTheFirmQuoteOnly() throws {
        let swap = try swap()
        // One tap, one request: Review is off while the allowance or the firm quote is read.
        XCTAssertTrue(swap.contains("PrimaryButton(title: model.actionTitle, isBusy: fetchingFirm, isDisabled: fetchingFirm || model.selectedQuote == nil || model.insufficient || !session.canSign) { reviewStock() }"))
        XCTAssertTrue(swap.contains("guard !fetchingFirm, let estimate = model.selectedQuote, let account = session.address,"))
        // Not exact: the approval alone, to the router, for exactly the amount; the firm quote after it closed.
        XCTAssertTrue(swap.contains("let exact = try await env.swap.routerAllowanceIsExact(token: trade.request.tokenIn.address, amount: trade.request.amountIn, owner: account) if exact { try await openFirmQuote(trade) } else { stockSheet = StockSheet(.approval(trade)) }"))
        XCTAssertTrue(swap.contains(#"[.approve(token: token.address, spender: OneInch.router, amount: request.amountIn, label: tr("Approve \(token.symbol) for 1inch"))]"#))
        XCTAssertTrue(swap.contains("}, onDone: {}, onCompleted: { _ in approvedStock = trade }, intent: .swap(venue: .oneInch,"))
        XCTAssertTrue(swap.contains(".sheet(item: $stockSheet, onDismiss: fetchFirmAfterApproval) { sheet in stockSheetView(sheet) }"))
        // The review comes from the firm quote alone; the estimate only says whether the price changed.
        XCTAssertTrue(swap.contains("guard let firm = try await env.swap.firmQuote(for: trade.request) else { throw OneInchError.unavailable }"))
        XCTAssertTrue(swap.contains("stockSheet = StockSheet(.review(trade.review(firm: firm, reference: reference,"))
        XCTAssertTrue(swap.contains("return SwapReview(quote: firm, tokenIn: request.tokenIn, tokenOut: request.tokenOut, amountIn: request.amountIn,"))
        XCTAssertTrue(swap.contains("receiveUSD: receivePrice.map { Amount.units(firm.amountOut, decimals: request.tokenOut.decimals) * $0 }, stock: terms)"))
        XCTAssertEqual(swap.components(separatedBy: "estimate.amountOut").count - 1, 4, "the estimate is read only for \"Price changed\", and for the approval's intent")
        XCTAssertTrue(swap.contains("receive: .init(token: request.tokenOut.address, amount: trade.estimate.amountOut)"), "the approval's intent")
        // What the sheet shows and declares to a passkey session is the reviewed (firm) quote's.
        XCTAssertTrue(swap.contains(#"DetailRow("You receive", verbatim: "\(NumberStyle.units(quote.amountOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")"#))
        XCTAssertTrue(swap.contains(#"DetailRow("Minimum received", verbatim: "\(NumberStyle.units(quote.minOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")"#))
        XCTAssertTrue(swap.contains("receive: .init(token: review.tokenOut.address, amount: review.quote.amountOut), usd: review.payUSD)"))
        // The last check before signing: the switches as known now and the deadline, which offers a new quote.
        XCTAssertTrue(swap.contains("case .review(let review): confirmation(review, mayStart: stockMayStart(review))"))
        XCTAssertTrue(swap.contains("}, onDone: onDone, onCompleted: onCompleted, intent: intent, mayStart: mayStart) {"))
        XCTAssertTrue(swap.contains("if terms.isBuy, !availability.canBuy { return StartRefusal(XStockRefusal.buyingClosed.message) }"))
        XCTAssertTrue(swap.contains("if !terms.isBuy, !availability.canSell { return StartRefusal(XStockRefusal.sellingClosed.message) }"))
        XCTAssertTrue(swap.contains("if let deadline = review.quote.deadline, deadline - ContinuousClock.now < OneInch.startMargin { return StartRefusal(TransactionError.quoteExpired.localizedDescription, hint: .newQuote) }"))
    }

    func testTheRouteIsConstantAndThereIsNoBest() throws {
        let swap = try swap()
        XCTAssertTrue(swap.contains(#"DetailRow("Route", quote.venue == .oneInch ? SwapEngine.oneInchRoute : quote.route)"#))
        XCTAssertFalse(swap.contains(#"DetailRow("Route", quote.route)"#))
        XCTAssertTrue(swap.contains("if result.isFinal, quote.venue == result.quotes.first?.venue { // A stock pair has one venue, 1inch: there is nothing for it to be the best of. if quote.venue != .oneInch {"))
        XCTAssertTrue(swap.contains("if let below = stock.belowEstimateBps, below > OneInch.priceChangedBps {"))
        XCTAssertTrue(swap.contains("} else if let off = stock.referenceDeviationBps, abs(off) > OneInch.priceWarningBps {"))
        XCTAssertEqual(OneInch.priceChangedBps, 50)
        XCTAssertEqual(OneInch.priceWarningBps, 100)
    }

    func testABuyWaitsForTheNoticeWhichSigningOutForgets() throws {
        let swap = try swap()
        // Signed out: nothing is asked, and the screen says to sign in.
        XCTAssertTrue(swap.contains("guard let account else { showNoQuote(OneInchError.signedOut.localizedDescription, for: round) return false }"))
        // The notice: asked for only when the buy is otherwise open, and nothing is asked until it is acknowledged.
        XCTAssertTrue(swap.contains("var once = await env.swap.xStocksAvailability(for: account) once.disclosureAcknowledged = true guard once.canBuy, !Task.isCancelled else { return !Task.isCancelled }"))
        XCTAssertTrue(swap.contains("while !Task.isCancelled, !acknowledged { try? await Task.sleep(for: .milliseconds(300)) acknowledged = XStocksDisclosureStore.isAcknowledged(account) }"))
        XCTAssertTrue(swap.contains("XStocksDisclosureStore.acknowledge(wallet) dismiss()"))
        for line in ["They aren't offered to US persons or to people in other restricted jurisdictions.", "the issuer may refuse any trade",
                     "Selling xStocks in DyorHQ can be paused at any time.", "you can always send them to another wallet or export your wallet",
                     "the swap fails and you still pay its network fee"] {
            XCTAssertTrue(swap.contains(line), line)
        }
        XCTAssertEqual(XStocksDisclosureStore.currentVersion, 1)

        let session = AppSource.squeezed(try AppSource.app("Wallet/Session.swift"))
        XCTAssertEqual(session.components(separatedBy: "if let address { XStocksDisclosureStore.forget(address) }").count - 1, 2, "sign-out and this device's erase")
        XCTAssertTrue(session.contains("func signOut() async { // The wallet's acknowledgement of the xStocks notice goes with it: signing in again asks for it again. if let address { XStocksDisclosureStore.forget(address) }"))
    }

    func testTheEnvironmentWiresTheProxyAndTheSwitch() throws {
        let environment = AppSource.squeezed(try AppSource.app("App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains(#"oneInchProxy: backend.functionURL("oneinch-proxy"), oneInchCredentials: { wallet in try await backend.sessionHeaders(for: wallet) })"#))
        XCTAssertTrue(environment.contains("xStocksFlag = flags.xStocks XStocksSwitchStore.save(flags) handXStocksFlag(flags.xStocks)"))
        XCTAssertTrue(environment.contains("warmConnections() // The xStocks switch as last read on this device, until the flags are read again. handXStocksFlag(xStocksFlag) }"))
        XCTAssertTrue(environment.contains("xStocksSwitch = Task { [swap] in await previous?.value await swap.setXStocksFlag(on) }"))
        XCTAssertFalse(environment.contains("ONEINCH_API_KEY"), "the key is the proxy's alone")

        let run = AppSource.squeezed(try AppSource.app("Wallet/TransactionRun.swift"))
        XCTAssertEqual(run.components(separatedBy: "if let refusal = await mayStart?() { run.fail(refusal.message, hint: refusal.hint); return } onStarted?()").count - 1, 2,
                       "asked after App Lock and any passkey approval, before the plan starts, on both paths")
        XCTAssertTrue(run.contains("} else if case .failed = run.phase, run.hint == .newQuote {"))
    }

    /// A passkey account's wallet prices a 1inch router swap against the stock's reference feed where it refuses, both
    /// when it signs and when a sheet assesses the plan: without it every passkey stock trade would read as a bad price.
    func testThePasskeyWalletPricesARouterSwapAgainstTheReference() throws {
        let wallet = AppSource.squeezed(try AppSource.app("Wallet/Mera/MeraWallet.swift"))
        XCTAssertEqual(wallet.components(separatedBy: "Mera.SigningPolicy.refusal(").count - 1, 2)
        XCTAssertTrue(wallet.contains("let price = await reference(for: [call]) if let reason = Mera.SigningPolicy.refusal(call, intent: action.intent, account: account, retiredCurves: retired, reference: price) {"))
        XCTAssertTrue(wallet.contains("let price = await reference(for: calls) for call in calls { if let reason = Mera.SigningPolicy.refusal(call, intent: intent, account: account, retiredCurves: retired, reference: price) {"))
        XCTAssertTrue(wallet.contains("guard let stock = Mera.SigningPolicy.referenceStock(calls), let lookup = xStockReferenceLookup else { return nil } return await lookup(stock)"))

        let environment = AppSource.squeezed(try AppSource.app("App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains("session.mera.xStockReferenceLookup = { [swap] stock in try? await swap.referencePrice(for: stock) }"))
    }
}
