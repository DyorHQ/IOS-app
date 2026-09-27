import Foundation

/* Take-profit / stop-loss rules for Perpl, kept pure so the order ticket, the position TP/SL sheet and the tests share
   one definition. A trigger is a reduce-only close that Perpl's keeper fires when the price crosses it, so a bad one is
   worse than none: a zero or wrong-sided price fires the moment it is admitted, and a stop beyond the liquidation price
   never fires before the position is liquidated. Each is refused before anything is sent. */

public enum PerplTriggerKind: String, Sendable, Codable, CaseIterable {
    case takeProfit, stopLoss
}

public enum PerplTriggerRules {
    /// Why a trigger price can't be used. The app words these; the values carry what the message needs.
    public enum Problem: Equatable, Sendable {
        /// Zero, negative, or smaller than one price tick (it would be sent as `tp: 0`).
        case tooLow(PerplTriggerKind, minimum: Double)
        /// Not a whole number of ticks at the market's price precision.
        case offTick(PerplTriggerKind, decimals: Int)
        /// Not a finite price this market can represent.
        case outOfRange(PerplTriggerKind)
        /// On the wrong side of the reference price for this position side: it would fire at once.
        case wrongSide(PerplTriggerKind, side: PositionSide, reference: Double)
        /// A stop-loss at or beyond the position's liquidation price: liquidation comes first, so it protects nothing.
        case beyondLiquidation(side: PositionSide, liquidation: Double)
        /// Take-profit / stop-loss on a reduce-only order: its triggers would close the opposite side, which the
        /// account doesn't hold.
        case reduceOnly
    }

    /// The price as a whole number of ticks (`price × 10^decimals`), or nil when it isn't one: off the tick grid,
    /// below one tick, or not representable.
    public static func ticks(_ price: Double, decimals: Int) -> Int? {
        guard price.isFinite, price > 0 else { return nil }
        let scaled = price * pow(10, Double(decimals))
        let rounded = scaled.rounded()
        // Binary floating point: 95000.1 × 10 is 950001.0000000001. Anything further off than that is a real fraction.
        guard rounded >= 1, abs(scaled - rounded) <= max(1e-6, rounded * 1e-9) else { return nil }
        return Int(exactly: rounded)
    }

    /// The problem with a trigger at `price` for a `side` position, or nil.
    /// - reference: the price it is measured against — the entry for a new order (its limit price, else the mark), or
    ///   the current mark for a trigger added to an open position (it must not fire the moment it is placed).
    /// - liquidation: the position's (estimated) liquidation price; a stop-loss must sit strictly inside it.
    public static func problem(_ kind: PerplTriggerKind, price: Double, side: PositionSide, reference: Double,
                               liquidation: Double?, priceDecimals: Int) -> Problem? {
        let tick = pow(10, -Double(priceDecimals))
        // No market prices anywhere near 10^15 ticks; past that the scaled integer stops being exact.
        guard price.isFinite, price * pow(10, Double(priceDecimals)) < 1e15 else { return .outOfRange(kind) }
        guard price >= tick * 0.999_999 else { return .tooLow(kind, minimum: tick) }
        guard ticks(price, decimals: priceDecimals) != nil else { return .offTick(kind, decimals: priceDecimals) }
        if reference > 0 {
            // A long takes profit above and stops out below; a short the reverse.
            let above = price > reference
            let below = price < reference
            let ok: Bool
            switch (kind, side) {
            case (.takeProfit, .long), (.stopLoss, .short): ok = above
            case (.takeProfit, .short), (.stopLoss, .long): ok = below
            }
            if !ok { return .wrongSide(kind, side: side, reference: reference) }
        }
        if kind == .stopLoss, let liquidation, liquidation > 0, liquidation.isFinite {
            let inside = side == .long ? price > liquidation : price < liquidation
            if !inside { return .beyondLiquidation(side: side, liquidation: liquidation) }
        }
        return nil
    }
}

extension PerplTriggerRules.Problem {
    /// What to tell the user. `referenceName` names the price a wrong-sided trigger is measured against.
    public func message(market: PerpMarket, referenceName: String = "your entry") -> String {
        func name(_ kind: PerplTriggerKind) -> String { kind == .takeProfit ? "Take-profit" : "Stop-loss" }
        switch self {
        case .tooLow(let kind, let minimum):
            return "\(name(kind)) must be at least \(NumberStyle.number(minimum)) on \(market.asset)."
        case .offTick(let kind, let decimals):
            return decimals == 0 ? "\(name(kind)) must be a whole number on \(market.asset)."
                : "\(name(kind)) can have at most \(decimals) decimal place\(decimals == 1 ? "" : "s") on \(market.asset)."
        case .outOfRange(let kind):
            return "\(name(kind)) is not a valid price."
        case .wrongSide(let kind, let side, let reference):
            let above = (kind == .takeProfit) == (side == .long)
            return "\(name(kind)) must be \(above ? "above" : "below") \(referenceName) (\(NumberStyle.number(reference))) for a \(side == .long ? "long" : "short")."
        case .beyondLiquidation(let side, let liquidation):
            return "Stop-loss must be \(side == .long ? "above" : "below") the liquidation price (\(NumberStyle.number(liquidation))). Liquidation would come first, so it would never protect you."
        case .reduceOnly:
            return "Take-profit and stop-loss can't be attached to a reduce-only order. Set them on the position instead."
        }
    }
}

/// Which of the account's keeper triggers no longer protect anything. Perpl cancels a trigger linked to a position
/// (`lp`) when that position closes, but a trigger linked to its entry request (`tr`, how the order ticket attaches
/// TP/SL) is not documented to go with it — left armed, it would fire against the next position on that side.
public enum PerplTriggerCleanup {
    /// The sides where a resting entry (a limit OpenLong / OpenShort) could still open a position. The triggers closing
    /// that side of that market may be waiting on the entry, so none of them is treated as orphaned. Only that side: a
    /// resting short says nothing about the stop-loss of a long that is gone.
    public static func restingEntrySides(_ orders: [PerplOpenOrder]) -> Set<PerplMarketSide> {
        Set(orders.filter(\.isRestingEntry).map(\.side))
    }

    /// The reduce-only triggers with no open position on the side they close and no resting entry on that side. One
    /// that has already fired (Triggered, 9) is the keeper's to finish, never touched.
    public static func orphans(orders: [PerplOpenOrder], positions: [PerplLivePosition], extraRestingEntries: Set<PerplMarketSide> = []) -> [PerplOpenOrder] {
        let resting = restingEntrySides(orders).union(extraRestingEntries)
        let open = Set(positions.filter(\.isOpen).map { PerplMarketSide(marketId: $0.marketId, isLong: $0.isLong) })
        return orders.filter { order in
            order.isTrigger && order.isReduceOnly && order.statusRaw != 9 && !resting.contains(order.side) && !open.contains(order.side)
        }
    }

    /// The triggers to cancel because `ended` closed: the orphans on its market that closed its side.
    public static func siblings(of ended: PerplLivePosition, orders: [PerplOpenOrder], positions: [PerplLivePosition], extraRestingEntries: Set<PerplMarketSide> = []) -> [PerplOpenOrder] {
        orphans(orders: orders, positions: positions, extraRestingEntries: extraRestingEntries)
            .filter { $0.marketId == ended.marketId && $0.protectsLong == ended.isLong }
    }
}
