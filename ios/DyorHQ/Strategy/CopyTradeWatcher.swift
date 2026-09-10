import BigInt
import DyorKit
import Foundation

/// Polls each copied trader on-chain and turns their new trades into pending copy signals (and a local
/// notification). Spot traders are watched via their ERC-20 buys since a block checkpoint; perps traders via the
/// live positions they hold on Perpl. Modeled on `AlertWatcher`: one detached loop for the app's lifetime.
@MainActor
final class CopyTradeWatcher {
    private var task: Task<Void, Never>?

    /// The quote/stable tokens that, when *received*, mean a sell rather than a copy-worthy buy.
    private static let baseTokens: Set<Address> = {
        var set: Set<Address> = [Monad.native, Monad.wmon, Monad.usdc, Monad.usdt0, Monad.ausd]
        for token in Token.core where ["USD1", "mUSD", "USDe"].contains(token.symbol) { set.insert(token.address) }
        return set
    }()

    func start(env: AppEnvironment, settings: AppSettings) {
        guard task == nil else { return }
        task = Task { [weak env, weak settings] in
            while !Task.isCancelled {
                if let env, let settings { await CopyTradeWatcher.check(env: env, settings: settings) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    static func check(env: AppEnvironment, settings: AppSettings) async {
        guard let owner = env.session.address else { return }
        var traders = CopyStore.traders(owner: owner).filter(\.enabled)
        guard !traders.isEmpty else { return }
        let notify = settings.notificationsEnabled && settings.notifyCopyTrades

        // Perps markets are needed to read any trader's positions; fetch once per cycle only if a perps copy exists.
        var markets: [PerpMarket] = []
        if traders.contains(where: { $0.venue == .perps }) {
            markets = (try? await env.perpl.markets()) ?? []
        }

        var updated = traders
        for index in traders.indices {
            let trader = traders[index]
            switch trader.venue {
            case .spot: updated[index] = await checkSpot(trader, env: env, owner: owner, notify: notify)
            case .perps: updated[index] = await checkPerps(trader, env: env, owner: owner, markets: markets, notify: notify)
            }
        }

        // Persist ONLY the refreshed watcher checkpoints onto the freshly-read list — never the whole struct — so a
        // toggle/nickname/funding edit the user made during this cycle's network awaits isn't clobbered by our
        // pre-await snapshot. Traders removed mid-cycle simply aren't found and are left removed.
        var all = CopyStore.traders(owner: owner)
        for trader in updated {
            if let i = all.firstIndex(where: { $0.id == trader.id }) {
                all[i].lastBlock = trader.lastBlock
                all[i].perpsBaselined = trader.perpsBaselined
                all[i].seenPositions = trader.seenPositions
            }
        }
        CopyStore.setTraders(all, owner: owner)
    }

    // MARK: Spot — detect the trader's new token buys

    private static func checkSpot(_ trader: CopiedTrader, env: AppEnvironment, owner: Address, notify: Bool) async -> CopiedTrader {
        var trader = trader
        guard let head = await env.swapHistory.head() else { return trader }
        // First sight of this trader: set the checkpoint to now, so only trades made *after* copying start count.
        if trader.lastBlock == 0 { trader.lastBlock = head; return trader }
        guard head > trader.lastBlock else { return trader }

        // Advance the checkpoint oldest-first in bounded spans, not by result count, so a large backlog (e.g. after a
        // long background suspension) is chewed through over several cycles instead of being silently truncated.
        let maxSpan: UInt64 = 50_000
        let to = min(head, trader.lastBlock + maxSpan)
        let records = await env.swapHistory.swaps(wallet: trader.address, fromBlock: trader.lastBlock + 1, toBlock: to, limit: 200)
        trader.lastBlock = to

        for record in records.sorted(by: { $0.block < $1.block }) {
            // A buy = received a non-quote token. Receiving a stable/WMON is a sell, so skip it.
            guard !baseTokens.contains(record.boughtToken) else { continue }
            guard let token = try? await ERC20.metadata(record.boughtToken, multicall: env.multicall) else { continue }
            let logo = token.logoURL ?? VenueTokenStore.all().first { $0.address == token.address }?.logoURL
            let action = "Bought \(NumberStyle.units(record.boughtAmount, decimals: token.decimals, compact: true)) \(token.symbol)"
            let signal = CopySignal(
                id: "\(trader.id)|\(record.hash.hexString)|\(token.address.hex)",
                traderAddress: trader.address, traderName: trader.displayName, venue: .spot,
                detectedAt: Int(Date().timeIntervalSince1970), token: token.address, symbol: token.symbol,
                decimals: token.decimals, logo: logo, action: action, traderHash: record.hash
            )
            if CopyStore.addSignal(signal, owner: owner) {
                NotificationCenter.default.post(name: .copySignalsChanged, object: nil)
                if notify { Notifications.copyTrade(trader: trader.displayName, action: action) }
            }
        }
        return trader
    }

    // MARK: Perps — detect the trader's newly opened positions

    private static func checkPerps(_ trader: CopiedTrader, env: AppEnvironment, owner: Address, markets: [PerpMarket], notify: Bool) async -> CopiedTrader {
        var trader = trader
        guard !markets.isEmpty, let account = try? await env.perpl.account(trader.address) else { return trader }
        guard let positions = try? await env.perpl.positions(account, markets: markets) else { return trader }

        // Fingerprint by market + side only (NOT entry price): adding size to an open position moves the average
        // entry but isn't a new open, so it must not re-signal. A close removes the position from the current set, so
        // a genuine close-then-reopen re-appears as unseen and re-signals.
        func fingerprint(_ p: PerpPosition) -> String { "\(p.perpId):\(p.side.rawValue)" }
        let current = positions.map(fingerprint)
        let seen = Set(trader.seenPositions)
        let now = Int(Date().timeIntervalSince1970)
        // Conviction anchor: the leader's largest open position by notional. A position sized near this is a strong
        // bet copied near the full budget; a small probe is copied proportionally small.
        let leaderMaxNotional = positions.map(\.notional).max() ?? 0

        if trader.perpsBaselined {
            for position in positions where !seen.contains(fingerprint(position)) {
                let action = "Opened \(position.side.rawValue.uppercased()) \(position.symbol) \(NumberStyle.number(position.leverage, maximumFractionDigits: 0))x"
                let market = markets.first { $0.id == position.perpId }
                // Nadobro sizing: copyMargin = marginPerTrade · weight · entryFraction; copySize = copyMargin · lev / entry.
                let weight = leaderMaxNotional > 0 ? min(1.0, position.notional / leaderMaxNotional) : 1.0
                // Clamp leverage to BOTH the user's max and the market cap: the perps ticket re-clamps to the market
                // cap, so if we baked a higher leverage the ticket would keep the size but drop leverage, over-committing.
                let marketMaxLev = market.map { $0.initMarginFraction > 0 ? (1 / $0.initMarginFraction).rounded(.down) : 25 } ?? 25
                let leverage = max(1.0, min(position.leverage > 0 ? position.leverage : trader.maxLeverage, trader.maxLeverage, marketMaxLev))
                let copyMargin = trader.marginPerTrade * weight * 0.5 // initial-entry fraction; leaves headroom for scale-ins
                var copySize = position.entry > 0 ? copyMargin * leverage / position.entry : 0
                // Floor a tiny-conviction probe up to the market's minimum lot so it isn't rounded to a zero/sub-min
                // order that reverts on-chain.
                if let market, copySize > 0 {
                    let minLot = pow(10, -Double(market.lotDecimals))
                    if copySize < minLot { copySize = minLot }
                }
                let signal = CopySignal(
                    // Unique per detection so a genuine reopen isn't suppressed; `seen` handles per-poll dedup.
                    id: "\(trader.id)|\(fingerprint(position))|\(now)",
                    traderAddress: trader.address, traderName: trader.displayName, venue: .perps,
                    detectedAt: now, token: Monad.native, symbol: position.symbol,
                    decimals: 18, logo: nil, action: action, traderHash: nil,
                    side: position.side.rawValue, marketId: position.perpId, leverage: leverage, suggestedSize: copySize
                )
                if CopyStore.addSignal(signal, owner: owner) {
                    NotificationCenter.default.post(name: .copySignalsChanged, object: nil)
                    if notify { Notifications.copyTrade(trader: trader.displayName, action: action) }
                }
            }
        }
        trader.seenPositions = current
        trader.perpsBaselined = true
        return trader
    }
}
