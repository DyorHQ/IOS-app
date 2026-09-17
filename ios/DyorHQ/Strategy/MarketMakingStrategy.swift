import DyorKit
import Foundation

/// One resting order in a market-making ladder: a limit entry with a native take-profit (and optional stop-loss)
/// trigger that Perpl's keeper arms when the entry fills. Prices are absolute.
struct MMLevel: Codable, Hashable, Identifiable {
    let side: String // "long" | "short"
    let entry: Double
    let size: Double
    let takeProfit: Double?
    let stopLoss: Double?
    var id: String { "\(side)-\(entry)" }
    var positionSide: PositionSide { side == "short" ? .short : .long }
}

/// A fill the strategy manager observed (a resting order that filled), for the session's volume and fills feed.
struct MMFill: Codable, Hashable, Identifiable {
    let side: String
    let price: Double
    let size: Double
    let time: Int
    var id: String { "\(time)-\(price)-\(size)" }
    var notional: Double { price * size }
}

/// A running (or stopped) automated market-making strategy. Persists the config so the manager can recompute the
/// ladder to recycle, and the session runtime (baseline balance, volume, fills) so the status dashboard is accurate.
struct MMStrategy: Codable, Identifiable, Hashable {
    var id: String
    var marketId: Int
    var symbol: String
    var priceDecimals: Int
    var lotDecimals: Int
    var mode: String // "mid" | "grid"
    var startedAt: Int
    // Config
    var capital: Double
    var leverage: Double
    var takeProfitPct: Double
    var stopLossPct: Double // 0 = no stop
    // Mid
    var spreadBp: Double
    var levelsPerSide: Int
    var curve: String // flat | linear | geometric
    var bias: Double
    // Grid
    var gridLong: Bool
    var gridLevels: Int
    var gridStepBp: Double
    // Runtime
    var startBalance: Double
    var volume: Double
    var fills: [MMFill]
    /// The ladder currently placed on-chain (for attributing a filled price back to a side/size).
    var placedLevels: [MMLevel]
    /// Entry prices still resting (not yet filled), diffed against live open orders to detect fills.
    var restingPrices: [Double]
    /// Set true on the first tick the market is seen fully flat; a recycle only fires on a SECOND consecutive flat
    /// tick, so a just-filled position (visible on the next read) is never re-armed on top of.
    var recycleArmed: Bool = false
    var active: Bool

    // Fee-derived floors (maker round-trip 5bp → 2.5bp half-spread; grid step must clear the ~6.8bp round trip).
    static let midFloorBp = 2.5
    static let gridFloorBp = 6.8

    var deployed: Double { capital * leverage }
    var isGrid: Bool { mode == "grid" }

    private func curveWeights(_ n: Int) -> [Double] {
        switch curve {
        case "linear": return (1...max(1, n)).map(Double.init)
        case "geometric": return (0..<max(1, n)).map { pow(2, Double($0)) }
        default: return Array(repeating: 1, count: max(1, n))
        }
    }

    private func bracket(entry: Double, side: PositionSide) -> (tp: Double?, sl: Double?) {
        let tp: Double? = takeProfitPct > 0
            ? (side == .long ? entry * (1 + takeProfitPct / 100) : entry * (1 - takeProfitPct / 100))
            : nil
        let sl: Double? = stopLossPct > 0
            ? (side == .long ? entry * (1 - stopLossPct / 100) : entry * (1 + stopLossPct / 100))
            : nil
        return (tp, sl)
    }

    /// The full ladder for a given mark — the single source of truth used by the preview, placement, and recycling.
    func levels(mark: Double) -> [MMLevel] {
        guard mark > 0, capital > 0 else { return [] }
        return isGrid ? gridLevels(mark: mark) : midLevels(mark: mark)
    }

    private func midLevels(mark: Double) -> [MMLevel] {
        let n = max(1, levelsPerSide)
        let perSide = deployed / 2 // conservative: total across both sides ≤ margin × leverage
        let weights = curveWeights(n)
        let sum = weights.reduce(0, +)
        let skew = bias * 0.2
        var out: [MMLevel] = []
        for i in 0..<n {
            let sizeQuote = perSide * weights[i] / sum
            let bidBp = max(Self.midFloorBp, spreadBp * (1 - skew)) + spreadBp * Double(i)
            let askBp = max(Self.midFloorBp, spreadBp * (1 + skew)) + spreadBp * Double(i)
            let bid = mark * (1 - bidBp / 10_000)
            let ask = mark * (1 + askBp / 10_000)
            let b = bracket(entry: bid, side: .long)
            let a = bracket(entry: ask, side: .short)
            out.append(MMLevel(side: "long", entry: bid, size: sizeQuote / bid, takeProfit: b.tp, stopLoss: b.sl))
            out.append(MMLevel(side: "short", entry: ask, size: sizeQuote / ask, takeProfit: a.tp, stopLoss: a.sl))
        }
        return out
    }

    private func gridLevels(mark: Double) -> [MMLevel] {
        let n = max(1, gridLevels)
        let stepFrac = max(Self.gridFloorBp, gridStepBp) / 10_000
        let makerOffset = max(stepFrac / 2, 0.00015)
        let sizeQuote = deployed / Double(n)
        let side: PositionSide = gridLong ? .long : .short
        var out: [MMLevel] = []
        for i in 0..<n {
            let entry = gridLong
                ? mark * (1 - makerOffset - stepFrac * Double(i))
                : mark * (1 + makerOffset + stepFrac * Double(i))
            let b = bracket(entry: entry, side: side)
            out.append(MMLevel(side: side.rawValue, entry: entry, size: sizeQuote / entry, takeProfit: b.tp, stopLoss: b.sl))
        }
        return out
    }
}

/// Per-wallet persistence for automated MM strategies (mirrors CopyStore / PriceAlertStore).
enum MMStore {
    private static let prefix = "mm.strategies.v1."
    private static func key(_ owner: Address?) -> String { prefix + (owner?.hex.lowercased() ?? "none") }

    static func strategies(owner: Address?) -> [MMStrategy] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)),
              let list = try? JSONDecoder().decode([MMStrategy].self, from: data) else { return [] }
        return list
    }

    /// Mirrors the list to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([MMStrategy], Address?) -> Void)?

    static func save(_ strategies: [MMStrategy], owner: Address?) {
        guard let data = try? JSONEncoder().encode(strategies) else { return }
        UserDefaults.standard.set(data, forKey: key(owner))
        onChange?(strategies, owner)
    }

    static func upsert(_ strategy: MMStrategy, owner: Address?) {
        var list = strategies(owner: owner)
        if let i = list.firstIndex(where: { $0.id == strategy.id }) { list[i] = strategy } else { list.insert(strategy, at: 0) }
        save(list, owner: owner)
    }

    static func remove(id: String, owner: Address?) {
        save(strategies(owner: owner).filter { $0.id != id }, owner: owner)
    }

    static func active(owner: Address?) -> [MMStrategy] { strategies(owner: owner).filter(\.active) }
}

extension Notification.Name {
    /// Posted when an MM strategy's runtime changes (fill observed, recycled, stopped), so an open status view refreshes.
    static let mmStrategyChanged = Notification.Name("mmStrategyChanged")
}
