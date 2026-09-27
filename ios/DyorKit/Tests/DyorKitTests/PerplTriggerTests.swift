import XCTest
@testable import DyorKit

/// Take-profit / stop-loss rules, the frame guard that keeps a `tp: 0` close off the wire, the trading stream's
/// trigger and position events, and orphan detection.
@MainActor
final class PerplTriggerTests: XCTestCase {
    private func btc() -> PerpMarket {
        PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                   mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                   fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
    }

    // MARK: Trigger price rules

    func testTicks() {
        XCTAssertEqual(PerplTriggerRules.ticks(95000.1, decimals: 1), 950001) // 950001.0000000001 in binary
        XCTAssertEqual(PerplTriggerRules.ticks(0.1, decimals: 1), 1)
        XCTAssertEqual(PerplTriggerRules.ticks(0.031234, decimals: 6), 31234)
        XCTAssertNil(PerplTriggerRules.ticks(95000.05, decimals: 1), "half a tick is off the grid")
        XCTAssertNil(PerplTriggerRules.ticks(0.04, decimals: 1), "below one tick")
        XCTAssertNil(PerplTriggerRules.ticks(0, decimals: 1))
        XCTAssertNil(PerplTriggerRules.ticks(-1, decimals: 1))
        XCTAssertNil(PerplTriggerRules.ticks(.infinity, decimals: 1))
    }

    func testZeroNegativeAndSubTickPricesAreTooLow() {
        for price in [0, -5, 0.04] {
            XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: price, side: .long, reference: 95000, liquidation: nil, priceDecimals: 1),
                           .tooLow(.stopLoss, minimum: 0.1), "\(price)")
            XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: price, side: .short, reference: 95000, liquidation: nil, priceDecimals: 1),
                           .tooLow(.takeProfit, minimum: 0.1), "\(price)")
        }
        XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: 90000.05, side: .short, reference: 95000, liquidation: nil, priceDecimals: 1),
                       .offTick(.takeProfit, decimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.takeProfit, price: 1e300, side: .long, reference: 95000, liquidation: nil, priceDecimals: 1),
                       .outOfRange(.takeProfit))
    }

    func testSides() {
        let rules = { (kind: PerplTriggerKind, price: Double, side: PositionSide) in
            PerplTriggerRules.problem(kind, price: price, side: side, reference: 95000, liquidation: nil, priceDecimals: 1)
        }
        XCTAssertNil(rules(.takeProfit, 100000, .long))
        XCTAssertNil(rules(.stopLoss, 90000, .long))
        XCTAssertNil(rules(.takeProfit, 90000, .short))
        XCTAssertNil(rules(.stopLoss, 100000, .short))
        XCTAssertEqual(rules(.takeProfit, 90000, .long), .wrongSide(.takeProfit, side: .long, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 100000, .long), .wrongSide(.stopLoss, side: .long, reference: 95000))
        XCTAssertEqual(rules(.takeProfit, 100000, .short), .wrongSide(.takeProfit, side: .short, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 90000, .short), .wrongSide(.stopLoss, side: .short, reference: 95000))
        XCTAssertEqual(rules(.stopLoss, 95000, .long), .wrongSide(.stopLoss, side: .long, reference: 95000), "at the reference fires at once")
        // No reference (no price yet): the side can't be judged, the price itself still can.
        XCTAssertNil(PerplTriggerRules.problem(.takeProfit, price: 1, side: .long, reference: 0, liquidation: nil, priceDecimals: 1))
    }

    func testStopLossMustSitInsideLiquidation() {
        // Long at 95,000, liquidated at 86,000: a stop at or below 86,000 never fires before liquidation.
        XCTAssertNil(PerplTriggerRules.problem(.stopLoss, price: 86000.1, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 86000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1),
                       .beyondLiquidation(side: .long, liquidation: 86000))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 80000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1),
                       .beyondLiquidation(side: .long, liquidation: 86000))
        // Short at 95,000, liquidated at 104,000.
        XCTAssertNil(PerplTriggerRules.problem(.stopLoss, price: 103999.9, side: .short, reference: 95000, liquidation: 104000, priceDecimals: 1))
        XCTAssertEqual(PerplTriggerRules.problem(.stopLoss, price: 110000, side: .short, reference: 95000, liquidation: 104000, priceDecimals: 1),
                       .beyondLiquidation(side: .short, liquidation: 104000))
        // A take-profit is on the other side of the entry from liquidation: never judged against it.
        XCTAssertNil(PerplTriggerRules.problem(.takeProfit, price: 120000, side: .long, reference: 95000, liquidation: 86000, priceDecimals: 1))
    }

    func testMessages() {
        let m = btc()
        XCTAssertEqual(PerplTriggerRules.Problem.tooLow(.stopLoss, minimum: 0.1).message(market: m), "Stop-loss must be at least 0.1 on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 1).message(market: m), "Take-profit can have at most 1 decimal place on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 0).message(market: m), "Take-profit must be a whole number on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.wrongSide(.takeProfit, side: .short, reference: 950).message(market: m), "Take-profit must be below your entry (950) for a short.")
        XCTAssertEqual(PerplTriggerRules.Problem.wrongSide(.stopLoss, side: .long, reference: 950).message(market: m, referenceName: "the mark price"),
                       "Stop-loss must be below the mark price (950) for a long.")
        XCTAssertTrue(PerplTriggerRules.Problem.beyondLiquidation(side: .short, liquidation: 990).message(market: m).hasPrefix("Stop-loss must be below the liquidation price (990)."))
    }

    // MARK: Frame guard

    func testZeroTriggerPriceNeverLeavesTheDevice() {
        // A stop-loss typed as 0.01 on BTC (one decimal) scales to tp: 0 — a reduce-only market close that would
        // execute the moment it is admitted.
        let subTick = PerplOrders.stopLoss(side: .long, price: 0.01, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertEqual(subTick.triggerPricePNS, 0)
        XCTAssertNotNil(PerplOrders.problem(subTick))
        let zero = PerplOrders.takeProfit(side: .short, price: 0, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertNotNil(PerplOrders.problem(zero))
        let noSize = PerplOrders.takeProfit(side: .long, price: 100000, size: 0.000001, market: btc(), accountId: 1, linkedPositionId: nil)
        XCTAssertNotNil(PerplOrders.problem(noSize), "size below one lot")
        XCTAssertNil(PerplOrders.problem(PerplOrders.takeProfit(side: .long, price: 100000, size: 0.1, market: btc(), accountId: 1, linkedPositionId: 7)))
        XCTAssertNil(PerplOrders.problem(PerplOrders.stopLoss(side: .short, price: 100000, size: 0.1, market: btc(), accountId: 1, linkedPositionId: nil)))
    }

    func testZeroPriceLimitIsRefusedButMarketIsNot() {
        let limit = PerplOrders.entry(OrderInput(market: btc(), side: .long, kind: .limit, size: 0.1, price: 0.01, leverage: 5), accountId: 1, head: 0)
        XCTAssertEqual(limit.pricePNS, 0)
        XCTAssertNotNil(PerplOrders.problem(limit), "a GTC order with p: 0 is a market order")
        XCTAssertNil(PerplOrders.problem(PerplOrders.entry(OrderInput(market: btc(), side: .long, kind: .market, size: 0.1, leverage: 5), accountId: 1, head: 0)))
        XCTAssertNil(PerplOrders.problem(PerplOrders.cancel(perpId: 1, orderId: 9, accountId: 1, head: 0)))
    }

    // MARK: Trading stream

    private func client() -> PerplTradeClient {
        PerplTradeClient(key: PerplApiKey(token: "t", secret: Data(repeating: 7, count: 32), address: "0x0000000000000000000000000000000000000001", scopeMask: 2))
    }

    private func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func trigger(oid: Int, st: Int, sr: Int = 0, removed: Bool = false, tpc: Int = 4, market: Int = 1) -> [String: Any] {
        var order: [String: Any] = ["oid": oid, "mkt": market, "t": 3, "st": st, "sr": sr, "p": 0, "os": 10000, "fs": 0, "tp": 900000, "tpc": tpc, "lv": 0]
        if removed { order["r"] = true }
        return order
    }

    func testTriggerEventsComeFromUpdatesOnceEach() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        XCTAssertFalse(c.hasOrdersSnapshot)

        // A trigger already Triggered in the snapshot is state, not news.
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8), trigger(oid: 6, st: 9)]]))
        XCTAssertTrue(c.hasOrdersSnapshot)
        XCTAssertEqual(c.openOrders.map(\.oid), [5, 6])
        XCTAssertTrue(events.isEmpty)
        // An update that leaves out the status keeps the order live, with the status it had.
        c.handle(frame(["mt": 24, "d": [["oid": 5, "fs": 0]]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [5, 6])
        XCTAssertEqual(c.openOrders.first?.statusRaw, 8)

        // Fires: Triggered, then Executed and removed — one event.
        c.handle(frame(["mt": 24, "d": [["oid": 5, "st": 9, "sr": 54]]]))
        c.handle(frame(["mt": 24, "d": [["oid": 5, "st": 10, "sr": 65, "r": true]]]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, .triggered)
        // The partial update kept the order's own terms (market, type, trigger).
        XCTAssertEqual(events.first?.order.marketId, 1)
        XCTAssertEqual(events.first?.order.triggerPriceRaw, 900000)
        XCTAssertEqual(events.first?.order.isStopLoss, true)
        XCTAssertEqual(c.openOrders.map(\.oid), [6])

        // Fails to execute after firing: reported, with Perpl's reason.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 7, sr: 64, removed: true)]]))
        XCTAssertEqual(events.last?.outcome, .failed(reason: 64))
        XCTAssertTrue(c.openOrders.isEmpty)

        // A cancelled trigger and a plain limit order that fills report nothing.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 7, st: 8)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 7, st: 5, removed: true)]]))
        c.handle(frame(["mt": 24, "d": [["oid": 8, "mkt": 1, "t": 1, "st": 4, "p": 950000, "os": 10000, "fs": 10000, "lv": 500]]]))
        XCTAssertEqual(events.count, 2)
    }

    func testPositionsAndEndings() {
        let c = client()
        var ended: [PerplLivePosition] = []
        c.onPositionEnded = { ended.append($0) }
        c.handle(frame(["mt": 26, "d": [["pid": 41, "mkt": 1, "sd": 1, "s": 20000, "st": 1], ["pid": 42, "mkt": 20, "sd": 2, "s": 5, "st": 1]]]))
        XCTAssertTrue(c.hasPositionsSnapshot)
        XCTAssertEqual(c.positions.map(\.pid), [41, 42])
        XCTAssertEqual(c.positions.first?.isLong, true)
        XCTAssertEqual(c.positions.last?.isLong, false)

        c.handle(frame(["mt": 27, "d": [["pid": 41, "st": 3, "sr": 19, "s": 0]]]))
        XCTAssertEqual(c.positions.map(\.pid), [42])
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.wasLiquidated, true)
        XCTAssertEqual(ended.first?.marketId, 1, "an update's missing fields come from the position it updates")
        XCTAssertEqual(ended.first?.isLong, true)

        // Reported once; a still-open update reports nothing; a side-less unknown position is ignored.
        c.handle(frame(["mt": 27, "d": [["pid": 41, "st": 3, "sr": 19, "s": 0]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 42, "st": 1, "s": 9]]]))
        c.handle(frame(["mt": 27, "d": [["pid": 99, "st": 2, "s": 0]]]))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(c.positions.first?.sizeRaw, 9)
    }

    func testNothingInFlightOnAFreshClient() async {
        let c = client()
        XCTAssertFalse(c.hasRequestsInFlight)
        do {
            _ = try await c.sendEach([PerplOrders.cancel(perpId: 1, orderId: 3, accountId: 1, head: 0)])
            XCTFail("not signed in")
        } catch let error as PerplTradeError {
            XCTAssertFalse(error.outcomeUnknown, "nothing was sent")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(c.hasRequestsInFlight)
    }

    func testUnknownAckIsNotAccepted() {
        XCTAssertTrue(PerplOrderAck(code: 0, error: nil).accepted)
        XCTAssertFalse(PerplOrderAck(code: 0, error: nil, outcomeUnknown: true).accepted)
        XCTAssertFalse(PerplOrderAck(code: 400, error: "bad").accepted)
        XCTAssertFalse(PerplTradeError.invalidOrder("x").outcomeUnknown)
        XCTAssertTrue(PerplTradeError.closed("x").outcomeUnknown)
    }

    // MARK: Orphans

    private func order(oid: Int, market: Int = 1, type: Int, tp: Int? = 900000, tpc: Int? = 4) -> PerplOpenOrder {
        PerplOpenOrder(oid: oid, marketId: market, typeRaw: type, statusRaw: 8, priceRaw: 0, sizeRaw: 10000, filledRaw: 0,
                       triggerPriceRaw: tp, triggerConditionRaw: tpc, linkedPositionId: nil, leverageHundredths: 0)
    }

    func testOrphansAndSiblings() {
        let longSL = order(oid: 1, type: 3)                       // CloseLong stop on BTC
        let longTP = order(oid: 2, type: 3, tp: 1_100_000, tpc: 1) // CloseLong take-profit on BTC
        let shortSL = order(oid: 3, type: 4, tpc: 3)               // CloseShort on BTC
        let ethSL = order(oid: 4, market: 20, type: 3)             // CloseLong on ETH
        let orders = [longSL, longTP, shortSL, ethSL]
        let btcLong = PerplLivePosition(pid: 10, marketId: 1, isLong: true, sizeRaw: 10000, statusRaw: 1)

        // Holding a BTC long: its own triggers stay; the short-side one and ETH's (no ETH position) are orphans.
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong]).map(\.oid), [3, 4])
        // A resting ETH entry may be what the ETH trigger waits on.
        let ethEntry = order(oid: 5, market: 20, type: 1, tp: nil, tpc: nil)
        XCTAssertTrue(ethEntry.isRestingEntry)
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders + [ethEntry], positions: [btcLong]).map(\.oid), [3])
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong], extraRestingEntries: [PerplMarketSide(marketId: 20, isLong: true)]).map(\.oid), [3])
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: orders, positions: [btcLong], extraRestingEntries: [PerplMarketSide(marketId: 20, isLong: false)]).map(\.oid), [3, 4],
                       "an entry sent on the other side says nothing about the long's triggers")

        // The BTC long closed: its take-profit and stop-loss are the siblings to cancel — not the short-side one.
        let closed = PerplLivePosition(pid: 10, marketId: 1, isLong: true, sizeRaw: 0, statusRaw: 2)
        XCTAssertEqual(PerplTriggerCleanup.siblings(of: closed, orders: orders, positions: []).map(\.oid), [1, 2])
        // ...unless a new long on BTC is already open, or an entry is resting there.
        let reopened = PerplLivePosition(pid: 11, marketId: 1, isLong: true, sizeRaw: 5000, statusRaw: 1)
        XCTAssertTrue(PerplTriggerCleanup.siblings(of: closed, orders: orders, positions: [reopened]).isEmpty)
        XCTAssertTrue(PerplTriggerCleanup.siblings(of: closed, orders: orders + [order(oid: 6, type: 1, tp: nil, tpc: nil)], positions: []).isEmpty)
        // A trigger that already fired is the keeper's to finish.
        let firing = PerplOpenOrder(oid: 7, marketId: 1, typeRaw: 3, statusRaw: 9, priceRaw: 0, sizeRaw: 10000, filledRaw: 0,
                                    triggerPriceRaw: 900000, triggerConditionRaw: 4, linkedPositionId: nil, leverageHundredths: 0)
        XCTAssertEqual(PerplTriggerCleanup.siblings(of: closed, orders: [firing, longSL], positions: []).map(\.oid), [1])
    }

    // MARK: Security audit review (GT-1, GT-2, GT-3, GT-6, GT-9)

    func testRestingEntryExemptsOnlyItsOwnSide() {
        let longSL = order(oid: 1, type: 3)                              // CloseLong stop on BTC, no BTC long open
        let restingShort = order(oid: 2, type: 2, tp: nil, tpc: nil)     // a far-away limit short on BTC
        let restingLong = order(oid: 3, type: 1, tp: nil, tpc: nil)      // a limit long on BTC
        XCTAssertEqual(restingShort.side, PerplMarketSide(marketId: 1, isLong: false))
        XCTAssertEqual(longSL.side, PerplMarketSide(marketId: 1, isLong: true))
        XCTAssertEqual(PerplTriggerCleanup.orphans(orders: [longSL, restingShort], positions: []).map(\.oid), [1],
                       "a resting short never hides the orphaned stop-loss of a long")
        XCTAssertTrue(PerplTriggerCleanup.orphans(orders: [longSL, restingLong], positions: []).isEmpty, "it may be waiting on the resting long")
    }

    func testTheSameOrderIdOnTwoMarketsIsTwoOrders() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        // BTC's trigger 12 and ETH's resting entry 12: both kept.
        let ethEntry: [String: Any] = ["oid": 12, "mkt": 20, "t": 1, "st": 2, "p": 30000000, "os": 100, "fs": 0, "lv": 500]
        c.handle(frame(["mt": 23, "d": [trigger(oid: 12, st: 8), ethEntry]]))
        XCTAssertEqual(Set(c.openOrders.map(\.id)), [PerplOpenOrder.Key(marketId: 1, oid: 12), PerplOpenOrder.Key(marketId: 20, oid: 12)])
        // ETH's order fills: BTC's trigger is untouched, and nothing is announced for it.
        c.handle(frame(["mt": 24, "d": [["oid": 12, "mkt": 20, "st": 4, "fs": 100, "r": true]]]))
        XCTAssertEqual(c.openOrders.map(\.id), [PerplOpenOrder.Key(marketId: 1, oid: 12)])
        XCTAssertEqual(c.openOrders.first?.triggerPriceRaw, 900000)
        XCTAssertTrue(events.isEmpty)
        // An ETH trigger with the same id: its own order, and its firing is its own event.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 8, market: 20)]]))
        XCTAssertEqual(c.openOrders.count, 2)
        // An update with no market can't be told apart while two orders share the id: ignored, not merged into either.
        c.handle(frame(["mt": 24, "d": [["oid": 12, "st": 9, "sr": 54]]]))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(c.openOrders.map(\.statusRaw), [8, 8])
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 9, sr: 54)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 9, sr: 54, market: 20)]]))
        XCTAssertEqual(events.map(\.order.marketId), [1, 20], "one trigger firing never hides the other market's")
        // With one order left for the id, an update without a market is that order's.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 12, st: 10, sr: 65, removed: true, market: 20)]]))
        c.handle(frame(["mt": 24, "d": [["oid": 12, "st": 10, "sr": 65, "r": true]]]))
        XCTAssertTrue(c.openOrders.isEmpty)
    }

    func testALateDuplicateFailureKeepsTheLiveTrigger() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8)]]))
        // The late failure of a resent request (request id too low): Perpl's first non-failure status stands.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 7, sr: 32)]]))
        XCTAssertEqual(c.openOrders.map(\.oid), [5])
        XCTAssertEqual(c.openOrders.first?.statusRaw, 8)
        XCTAssertTrue(events.isEmpty)
        // A real outcome after it still counts: it fired and couldn't be carried out.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 7, sr: 64, removed: true)]]))
        XCTAssertEqual(events.map(\.outcome), [.failed(reason: 64)])
        XCTAssertTrue(c.openOrders.isEmpty)
        // A failure for an order never admitted is its answer, whatever the reason.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 7, sr: 32)]]))
        XCTAssertEqual(events.last?.outcome, .failed(reason: 32))
    }

    func testATriggeredOrderThatExpiresIsReportedAsFailed() {
        let c = client()
        var events: [PerplTriggerEvent] = []
        c.onTriggerEvent = { events.append($0) }
        c.handle(frame(["mt": 23, "d": [trigger(oid: 5, st: 8), trigger(oid: 6, st: 8)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 9, sr: 54)]]))
        c.handle(frame(["mt": 24, "d": [trigger(oid: 5, st: 6, sr: 67, removed: true)]]))
        XCTAssertEqual(events.map(\.outcome), [.triggered, .failed(reason: 67)], "told it was closing, then that it couldn't")
        // One that expires without firing no longer protects anything either.
        c.handle(frame(["mt": 24, "d": [trigger(oid: 6, st: 6, sr: 6, removed: true)]]))
        XCTAssertEqual(events.last?.outcome, .expired)
        XCTAssertTrue(c.openOrders.isEmpty)
    }

    func testTriggerOutcomes() {
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 9, reason: 68), .triggered, "a recoverable failure is still being retried")
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 7, reason: 68), .failed(reason: 68))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 68), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 67), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 5, reason: 67), .failed(reason: 67))
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 6, reason: 0), .expired)
        XCTAssertEqual(PerplTradeClient.triggerOutcome(status: 10, reason: 65), .triggered)
        XCTAssertNil(PerplTradeClient.triggerOutcome(status: 5, reason: 28), "cancelled")
        XCTAssertNil(PerplTradeClient.triggerOutcome(status: 8, reason: 0))
    }

    func testAnOrderThatOnlyReducesTheOtherSideTakesNoTriggers() {
        // Holding 1 BTC long: a 0.3 short only shrinks it; a 1.3 short turns it into a 0.3 short.
        XCTAssertTrue(PerplTriggerRules.onlyReduces(side: .short, size: 0.3, positionSide: .long, positionSize: 1))
        XCTAssertTrue(PerplTriggerRules.onlyReduces(side: .short, size: 1, positionSide: .long, positionSize: 1), "closes it exactly")
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .short, size: 1.3, positionSide: .long, positionSize: 1))
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .long, size: 0.3, positionSide: .long, positionSize: 1), "adds to it")
        XCTAssertFalse(PerplTriggerRules.onlyReduces(side: .short, size: 0.3, positionSide: nil, positionSize: 0))
        XCTAssertEqual(PerplTriggerRules.Problem.reducesPosition(.long).message(market: btc()),
                       "This order only reduces your long, so its take-profit and stop-loss would have no short to close and would stay armed for your next short here. Set them with TP/SL on the position instead.")
    }
}
