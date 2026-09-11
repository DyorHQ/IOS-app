import Foundation

/* Authenticated Perpl trading history (fills, position history, account events). These endpoints are the only
   source for cumulative volume, realized P&L and a trade log — the on-chain Exchange keeps only live state. Every
   call is Ed25519-signed with the account's API key; see PerplAuth.signedGet and PerplFoundation/api-docs. Prices
   and sizes arrive as integers scaled by the market's decimals, and money amounts as decimal strings in collateral
   units (AUSD, 6 decimals); the parsers here return real display units so the app never re-scales. */

/// One order fill. `notional` and `fee` are in AUSD; `price`/`size` are in the market's own units.
public struct PerplFill: Identifiable, Sendable, Hashable {
    public let id: String
    public let time: Date
    public let marketId: Int
    public let symbol: String
    public let side: OrderSide
    public let isMaker: Bool
    public let price: Double
    public let size: Double
    public let fee: Double
    public var notional: Double { price * size }

    public init(id: String, time: Date, marketId: Int, symbol: String, side: OrderSide, isMaker: Bool, price: Double, size: Double, fee: Double) {
        self.id = id; self.time = time; self.marketId = marketId; self.symbol = symbol
        self.side = side; self.isMaker = isMaker; self.price = price; self.size = size; self.fee = fee
    }

    /// Parses one `Fill` row (see api-docs types.md). Returns nil for a market not in `markets` (can't scale it).
    init?(fill j: [String: Any], markets: [Int: PerpMarket]) {
        guard let mkt = (j["mkt"] as? NSNumber)?.intValue, let market = markets[mkt] else { return nil }
        let oid = (j["oid"] as? NSNumber)?.intValue ?? 0
        let at = j["at"] as? [String: Any]
        let ms = (at?["t"] as? NSNumber)?.doubleValue ?? 0
        let log = (at?["l"] as? NSNumber)?.intValue ?? 0
        // REST OrderType is 1-indexed (api-docs types.md): 1 OpenLong, 2 OpenShort, 3 CloseLong, 4 CloseShort — NOT
        // the on-chain 0-indexed PerpOrderType. A fill that increases a long or reduces a short is a buy.
        let typeRaw = (j["t"] as? NSNumber)?.intValue ?? 0
        let side: OrderSide = (typeRaw == 1 || typeRaw == 4) ? .buy : .sell
        let priceScaled = (j["p"] as? NSNumber)?.doubleValue ?? 0
        let sizeScaled = (j["s"] as? NSNumber)?.doubleValue ?? 0
        self.init(
            id: "\(mkt)-\(oid)-\(Int(ms))-\(log)",
            time: Date(timeIntervalSince1970: ms / 1000),
            marketId: mkt,
            symbol: market.asset,
            side: side,
            isMaker: (j["l"] as? NSNumber)?.intValue == 1,
            price: priceScaled / pow(10, Double(market.priceDecimals)),
            size: sizeScaled / pow(10, Double(market.lotDecimals)),
            fee: PerplHistory.amount(j["f"])
        )
    }
}

/// One position-history event that realized P&L (a close, a decrease or a liquidation). `realizedPnl` already
/// folds in funding; `ended` marks a fully-closed position (for the trade count and win rate).
public struct PerplPositionRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let time: Date
    public let marketId: Int
    public let symbol: String
    public let side: PositionSide
    public let entry: Double
    public let exit: Double?
    public let size: Double
    public let realizedPnl: Double
    public let fee: Double
    public let ended: Bool

    /// Position-history rows that realized P&L. Rows with no `dpnl` (a plain open/increase) are skipped so they
    /// don't count as trades or dilute the win rate.
    init?(position j: [String: Any], markets: [Int: PerpMarket]) {
        guard let mkt = (j["mkt"] as? NSNumber)?.intValue, let market = markets[mkt] else { return nil }
        guard j["dpnl"] != nil else { return nil }
        let at = j["at"] as? [String: Any]
        let ms = (at?["t"] as? NSNumber)?.doubleValue ?? 0
        let pid = (j["pid"] as? NSNumber)?.intValue ?? 0
        let status = (j["st"] as? NSNumber)?.intValue ?? 0
        let sdRaw = (j["sd"] as? NSNumber)?.intValue ?? 1
        let dpnl = PerplHistory.amount(j["dpnl"])
        let fnd = PerplHistory.amount(j["fnd"])
        let entryScaled = (j["ep"] as? NSNumber)?.doubleValue ?? 0
        let exitScaled = (j["xp"] as? NSNumber)?.doubleValue
        let sizeScaled = (j["s"] as? NSNumber)?.doubleValue ?? 0
        self.id = "\(mkt)-\(pid)-\(Int(ms))"
        self.time = Date(timeIntervalSince1970: ms / 1000)
        self.marketId = mkt
        self.symbol = market.asset
        self.side = sdRaw == 2 ? .short : .long
        self.entry = entryScaled / pow(10, Double(market.priceDecimals))
        self.exit = exitScaled.map { $0 / pow(10, Double(market.priceDecimals)) }
        self.size = sizeScaled / pow(10, Double(market.lotDecimals))
        self.realizedPnl = dpnl + fnd
        self.fee = PerplHistory.amount(j["fee"])
        self.ended = status == 2 || status == 3 || status == 4 || status == 5 // Closed / Liquidated / Deleveraged / Unwound
    }
}

/// A page of history plus the cursor to fetch the next (nil when there are no more rows).
public struct PerplHistoryPage<T: Sendable>: Sendable {
    public let items: [T]
    public let next: String?
    public init(items: [T], next: String?) { self.items = items; self.next = next }
}

enum PerplHistory {
    /// A collateral `Amount` — a decimal string of the value scaled by 6 — as a display Double in AUSD.
    static func amount(_ value: Any?) -> Double {
        if let s = value as? String { return (Double(s) ?? 0) / 1_000_000 }
        if let n = value as? NSNumber { return n.doubleValue / 1_000_000 }
        return 0
    }
}
