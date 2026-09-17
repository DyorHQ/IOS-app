import BigInt
import DyorKit
import Foundation

/// Monitors running delta-neutral strategies while the app is active (every 30 s): the market's funding rate and
/// its sign, the short's distance to liquidation, the drift between the two legs — and notifies on each change that
/// matters. Runs only while the app is in the foreground; there is no server watching for the user (see
/// PARAMETERS.md §Blockers), so the dashboard also shows when the last check happened.
@MainActor
final class DNWatcher {
    private var task: Task<Void, Never>?
    private(set) var lastCheck: Date?

    func start(env: AppEnvironment, settings: AppSettings) {
        guard task == nil else { return }
        task = Task { [weak env, weak settings] in
            while !Task.isCancelled {
                if let env, let settings { await DNWatcher.tick(env: env, settings: settings) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    static func tick(env: AppEnvironment, settings: AppSettings) async {
        guard let owner = env.session.address else { return }
        let strategies = DNStore.strategies(owner: owner).filter { $0.status == .running || $0.status == .entering }
        guard !strategies.isEmpty else { return }
        let ids = Array(Set(strategies.map(\.marketId)))
        guard let markets = try? await env.perpl.markets(ids: ids), let head = try? await env.rpc.blockNumber() else { return }
        let account = try? await env.perpl.account(owner)
        var positions: [PerpPosition] = []
        if let account { positions = (try? await env.perpl.positions(account, markets: markets)) ?? [] }
        let notify = settings.notificationsEnabled && settings.notifyStrategy
        env.dnWatcher.lastCheck = Date()
        var autoExits: [String] = []

        for var s in strategies {
            guard let market = markets.first(where: { $0.id == s.marketId }) else { continue }
            let before = s
            let hourly = market.fundingRateHourly
            let position = positions.first { $0.perpId == s.marketId && $0.side == .short }

            // Funding sign: notify the moment it flips either way, in dollars a day on this position.
            let positive = hourly > 0
            if let last = s.lastFundingSignPositive, last != positive, hourly != 0 {
                let pct = NumberStyle.percent(hourly * 100, fractionDigits: 4)
                let size = position?.size ?? s.perpShortSize
                let perDay = abs(size * market.mark * PerplFunding.daily(hourly: hourly)).formatted(.currency(code: "USD"))
                let text = positive
                    ? "Funding on \(market.asset) flipped back to \(pct)/h: longs pay shorts again, your hedge earns about \(perDay) a day."
                    : "Funding on \(market.asset) flipped to \(pct)/h: shorts now pay longs, your hedge is paying about \(perDay) a day."
                s.log(text)
                if notify { Notifications.strategy(kind: .funding, title: positive ? "Funding turned positive" : "Funding flipped against you", body: text, strategyID: s.id) }
            }
            if hourly != 0 { s.lastFundingSignPositive = positive }
            s.lastFundingHourly = hourly

            // Count consecutive settlement intervals at or below the exit threshold (one count per interval).
            let settlement = PerplFunding.nextSettlementBlock(startBlock: market.fundingStartBlock, head: head)
            if settlement != s.lastSettlementBlock {
                if s.lastSettlementBlock != 0 {
                    if hourly <= s.parameters.exitFundingHourly {
                        s.intervalsBelowThreshold += 1
                        if s.intervalsBelowThreshold == s.parameters.exitAfterIntervals {
                            if s.parameters.autoExitOnFundingFlip, s.status == .running, !env.dnRunner.isRunning {
                                let text = "Funding on \(market.asset) has been at or below your exit level for \(s.intervalsBelowThreshold) hourly settlements. Exiting now: closing the short, then selling the \(s.spotSymbol)."
                                s.log(text)
                                autoExits.append(s.id)
                                if notify { Notifications.strategy(kind: .funding, title: "Exiting: funding turned against you", body: text, strategyID: s.id) }
                            } else {
                                let text = "Funding on \(market.asset) has been at or below your exit level for \(s.intervalsBelowThreshold) hourly settlements. Consider exiting the \(s.symbol) hedge."
                                s.log(text)
                                if notify { Notifications.strategy(kind: .funding, title: "Exit recommended", body: text, strategyID: s.id) }
                            }
                        }
                    } else {
                        s.intervalsBelowThreshold = 0
                    }
                }
                s.lastSettlementBlock = settlement
            }

            // Liquidation distance and leg drift (running strategies only; entry is expected to drift).
            if s.status == .running {
                let spotPrice = market.mark
                let health = DeltaNeutral.health(spotUnits: s.spotHeldUnits, spotPrice: spotPrice, position: position, mark: market.mark, maintenanceFraction: market.maintMarginFraction)
                if let distance = health.liquidationDistancePct, distance < s.parameters.liquidationBufferPct,
                   Date().timeIntervalSince(s.lastLiquidationAlertAt ?? .distantPast) > 3_600 {
                    let text = "\(market.asset) is \(NumberStyle.percent(distance, fractionDigits: 1, signed: false)) from the short's liquidation price (\(NumberStyle.number(health.liquidationPrice ?? 0))). Add margin from the strategy page."
                    s.log(text)
                    s.lastLiquidationAlertAt = Date()
                    if notify { Notifications.strategy(kind: .risk, title: "Liquidation buffer low", body: text, strategyID: s.id) }
                }
                if position == nil, Date().timeIntervalSince(s.lastLiquidationAlertAt ?? .distantPast) > 3_600 {
                    let text = "The \(s.symbol) short is no longer open on Perpl (closed or liquidated). Your \(s.spotSymbol) is unhedged."
                    s.log(text)
                    s.lastLiquidationAlertAt = Date()
                    if notify { Notifications.strategy(kind: .risk, title: "Hedge missing", body: text, strategyID: s.id) }
                } else if health.driftPct > s.parameters.maxDeltaDriftPct, Date().timeIntervalSince(s.lastDriftAlertAt ?? .distantPast) > 6 * 3_600 {
                    let text = "Legs differ by \(NumberStyle.percent(health.driftPct, fractionDigits: 1, signed: false)) (\(health.netDelta.formatted(.currency(code: "USD").sign(strategy: .always()))) net \(health.netDelta >= 0 ? "long" : "short"))."
                    s.log(text)
                    s.lastDriftAlertAt = Date()
                    if notify { Notifications.strategy(kind: .risk, title: "Hedge drifted", body: text, strategyID: s.id) }
                }
            }

            if s != before {
                // Merge only monitoring fields onto the freshly read record (the runner may have advanced it meanwhile).
                var all = DNStore.strategies(owner: owner)
                if let i = all.firstIndex(where: { $0.id == s.id }) {
                    all[i].lastFundingHourly = s.lastFundingHourly
                    all[i].lastFundingSignPositive = s.lastFundingSignPositive
                    all[i].lastSettlementBlock = s.lastSettlementBlock
                    all[i].intervalsBelowThreshold = s.intervalsBelowThreshold
                    all[i].lastLiquidationAlertAt = s.lastLiquidationAlertAt
                    all[i].lastDriftAlertAt = s.lastDriftAlertAt
                    let newEvents = s.events.filter { e in !all[i].events.contains(where: { $0.id == e.id }) }
                    all[i].events = Array((newEvents + all[i].events).prefix(100))
                    DNStore.save(all, owner: owner)
                    NotificationCenter.default.post(name: .dnStrategyChanged, object: nil)
                }
            }
        }
        // The automatic exit starts after the records are saved; the runner re-reads the strategy itself.
        if let id = autoExits.first { env.dnRunner.beginExit(id: id, env: env) }
    }
}
