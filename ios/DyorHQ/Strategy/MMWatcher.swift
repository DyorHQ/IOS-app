import BigInt
import DyorKit
import Foundation

/// Places and tears down an automated MM strategy over the authenticated Perpl path (no per-order signature). Each
/// level is a resting limit entry with a native take-profit / stop-loss trigger that Perpl's keeper fires when the
/// mark crosses — so exits are accurate and work even when the app is closed.
enum MMExecutor {
    /// A long TTL so resting MM orders don't expire mid-session (an expiry would otherwise look like a fill).
    static let orderTTLBlocks = Int(Monad.blocksPerDay)

    /// Places the ladder at `mark`. Returns ONLY the levels whose entry AND every requested TP/SL trigger were
    /// accepted — a level whose protective trigger was rejected is cancelled rather than left as a naked position.
    @MainActor static func place(_ strategy: MMStrategy, market: PerpMarket, mark: Double, env: AppEnvironment) async -> (placed: [MMLevel], error: String?) {
        // Make sure the trading socket is live before placing (it can silently drop between enabling and starting).
        await env.perplTrading.ensureConnected()
        guard let accountId = env.perplTrading.accountId, mark > 0 else {
            return ([], "Trading isn't connected. Enable one-click trading in Profile and try again.")
        }
        // Clamp leverage to the market's own cap so the order can't wholesale revert.
        let marketMaxLev = market.initMarginFraction > 0 ? (1 / market.initMarginFraction).rounded(.down) : 25
        let leverage = max(1, min(strategy.leverage, marketMaxLev))
        let minLot = pow(10, -Double(market.lotDecimals))

        var placed: [MMLevel] = []
        var firstError: String?
        for level in strategy.levels(mark: mark) {
            // A resting maker order must be on the correct side of the mark, and above the tradable minimum lot.
            let crosses = level.positionSide == .long ? level.entry >= mark : level.entry <= mark
            if crosses || level.size < minLot { continue }
            let input = OrderInput(market: market, side: level.positionSide, kind: .limit, size: level.size,
                                   price: level.entry, leverage: leverage, reduceOnly: false, slippageBps: 0, postOnly: true)
            guard let result = try? await env.perplTrading.submitBracket(input: input, accountId: accountId,
                                                                        takeProfit: level.takeProfit, stopLoss: level.stopLoss,
                                                                        env: env, ttlBlocks: orderTTLBlocks) else {
                firstError = firstError ?? "Order could not be sent — trading not connected."
                continue
            }
            let bracketsOk = (level.takeProfit == nil || result.takeProfit == true) && (level.stopLoss == nil || result.stopLoss == true)
            if result.entry, bracketsOk {
                placed.append(level)
            } else {
                firstError = firstError ?? result.error
                // Entry landed but a protective trigger did NOT — cancel the naked entry so it can't fill unprotected.
                if result.entry { await cancelEntry(level: level, market: market, env: env) }
            }
        }
        return (placed, placed.isEmpty ? firstError : nil)
    }

    @MainActor private static func cancelEntry(level: MMLevel, market: PerpMarket, env: AppEnvironment) async {
        guard let owner = env.session.address, let account = try? await env.perpl.account(owner),
              let orders = try? await env.perpl.openOrders(account, markets: [market]) else { return }
        for order in orders where order.perpId == market.id && abs(order.price - level.entry) / max(level.entry, 1) < 0.0005 {
            try? await env.perplTrading.cancel(perpId: order.perpId, orderId: order.orderId, env: env)
        }
    }

    /// Cancels every resting order and flattens every position on the strategy's market, then verifies the market is
    /// clean. Returns false if anything remains (so the caller can keep Stop available and retry).
    @MainActor @discardableResult static func stop(_ strategy: MMStrategy, env: AppEnvironment) async -> Bool {
        guard let owner = env.session.address, let account = try? await env.perpl.account(owner) else { return false }
        let markets = (try? await env.perpl.markets()) ?? []
        let orders = (try? await env.perpl.openOrders(account, markets: markets)) ?? []
        for order in orders where order.perpId == strategy.marketId {
            try? await env.perplTrading.cancel(perpId: order.perpId, orderId: order.orderId, env: env)
        }
        let positions = (try? await env.perpl.positions(account, markets: markets)) ?? []
        for position in positions where position.perpId == strategy.marketId {
            if let market = markets.first(where: { $0.id == position.perpId }) {
                try? await env.perplTrading.closePosition(market: market, side: position.side, size: position.size, slippageBps: 150, env: env)
            }
        }
        // Verify the teardown actually cleared the market.
        guard let after = try? await env.perpl.account(owner) else { return false }
        let leftoverOrders = ((try? await env.perpl.openOrders(after, markets: markets)) ?? []).contains { $0.perpId == strategy.marketId }
        let leftoverPositions = ((try? await env.perpl.positions(after, markets: markets)) ?? []).contains { $0.perpId == strategy.marketId }
        return !(leftoverOrders || leftoverPositions)
    }
}

/// Runs the automated MM strategies while the app is active: reconnects the trading socket, tracks fills for the
/// session stats, and re-arms a strategy once it has fully cycled out — recycling only after the market is confirmed
/// flat across two consecutive reads, so it can never double a position. Per-level TP/SL are native venue triggers
/// that run whether or not this loop is alive.
@MainActor
final class MMWatcher {
    private var task: Task<Void, Never>?

    func start(env: AppEnvironment) {
        guard task == nil else { return }
        task = Task { [weak env] in
            while !Task.isCancelled {
                if let env { await MMWatcher.tick(env: env) }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    @MainActor static func tick(env: AppEnvironment) async {
        guard let owner = env.session.address else { return }
        let strategies = MMStore.strategies(owner: owner)
        guard strategies.contains(where: \.active) else { return }

        await env.perplTrading.ensureConnected()
        let markets = (try? await env.perpl.markets()) ?? []
        // CRITICAL: a failed account/positions/orders read must NOT be treated as "flat / no orders" — that would
        // fabricate fills and re-place the ladder on top of live exposure. `try?` returning nil means the read failed
        // (a genuine empty book returns []), so bail out of the whole tick and try again next cycle.
        guard let account = try? await env.perpl.account(owner),
              let positions = try? await env.perpl.positions(account, markets: markets),
              let orders = try? await env.perpl.openOrders(account, markets: markets) else { return }

        var updated: [String: MMStrategy] = [:]
        var changed = false
        for strategy in strategies where strategy.active {
            let next = await manage(strategy, env: env, markets: markets, positions: positions, orders: orders)
            updated[strategy.id] = next
            if next != strategy { changed = true }
        }

        guard changed else { return }
        // Merge only runtime fields onto the freshly-read list, preserving a user's Stop (active=false) made mid-cycle.
        var all = MMStore.strategies(owner: owner)
        for i in all.indices {
            guard let next = updated[all[i].id] else { continue }
            all[i].volume = next.volume
            all[i].fills = next.fills
            all[i].placedLevels = next.placedLevels
            all[i].restingPrices = next.restingPrices
            all[i].recycleArmed = next.recycleArmed
        }
        MMStore.save(all, owner: owner)
        NotificationCenter.default.post(name: .mmStrategyChanged, object: nil)
    }

    @MainActor private static func manage(_ strategy: MMStrategy, env: AppEnvironment, markets: [PerpMarket],
                                          positions: [PerpPosition], orders: [PerpOrder]) async -> MMStrategy {
        var s = strategy
        let marketOrders = orders.filter { $0.perpId == s.marketId }
        let marketPositions = positions.filter { $0.perpId == s.marketId }
        let currentPrices = marketOrders.map(\.price)
        let now = Int(Date().timeIntervalSince1970)

        // Detect fills: a resting entry price that is no longer on the book. (With the long TTL and flat-only recycle,
        // in normal operation the only way a resting order leaves the book is a fill.)
        let stillResting = s.restingPrices.filter { prev in currentPrices.contains { near($0, prev) } }
        let filledPrices = s.restingPrices.filter { prev in !currentPrices.contains { near($0, prev) } }
        for price in filledPrices {
            if let level = s.placedLevels.first(where: { near($0.entry, price) }) {
                s.fills.append(MMFill(side: level.side, price: level.entry, size: level.size, time: now))
                s.volume += level.entry * level.size
            }
        }
        s.restingPrices = stillResting

        // Safe recycle: require the market to be fully flat (no position, no resting order) across TWO consecutive
        // ticks before re-placing, so a position that just filled but isn't visible yet can never be stacked on.
        let flat = marketPositions.isEmpty && marketOrders.isEmpty && s.restingPrices.isEmpty
        if flat {
            if s.recycleArmed {
                s.recycleArmed = false
                if let market = markets.first(where: { $0.id == s.marketId }), market.mark > 0 {
                    let placed = await MMExecutor.place(s, market: market, mark: market.mark, env: env).placed
                    if !placed.isEmpty {
                        s.placedLevels = placed
                        s.restingPrices = placed.map(\.entry)
                    }
                }
            } else {
                s.recycleArmed = true // first flat tick — confirm on the next one
            }
        } else {
            s.recycleArmed = false
        }
        return s
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) / max(abs(b), 1) < 0.0008 }
}
