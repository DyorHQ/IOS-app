import DyorKit
import Foundation

/// The app's one alert watcher while DyorHQ is open (build 17, N2): it checks the signed-in wallet's price alerts and its
/// open Perpl positions — margin warnings, fills and closes — on any screen, not only on the screen that shows them.
/// There is no push: while DyorHQ is in the background or closed, iOS suspends it and nothing is checked; a check runs at
/// once when the app comes back to the foreground. The rules are DyorKit's (`AlertLoop`, `PriceAlertCheck`, `PerpRisk`,
/// `PerpRiskWatch`, `PerpPositionWatch`, `PerpEndingNotice`, `PerpAlertText`), so `swift test` pins them.
///
/// One loop at a time: RootView binds the account signed in (`bind`), which starts the loop, keeps it for the same
/// account, and stops it on a sign-out or an account switch. Each loop is a numbered run (`AlertLoop`); after every read
/// it checks it is still the newest run for the account it was started for before it posts or changes anything, so a
/// run that outlives its account never posts for it.
@MainActor
final class AlertCenter {
    private var loop = AlertLoop()
    private var task: Task<Void, Never>?
    /// The sleep between checks, so a return to the foreground can end it early (`enteredForeground`).
    private var sleeper: (run: Int, task: Task<Void, Never>)?
    private var wakeRequested = false
    private var foreground = true

    private weak var env: AppEnvironment?
    private var signedIn: () -> Address? = { nil }
    private var canAct: () -> Bool = { false }

    // What one run knows. A new run (another account) starts with none of it.
    private var positions = PerpPositionWatch()
    private var risk = PerpRiskWatch()
    private var markets: [PerpMarket] = []
    private var marketsReadAt: Date?
    /// Markets with a reduce-only (close) order resting at the last read of the account's orders.
    private var restingCloseMarkets: Set<Int> = []
    /// Positions seen ended whose notice waits for the trading stream (`PerpEndingNotice.wait`).
    private var pendingEndings: [Int: (position: PerpPosition, since: Date, restingClose: Bool)] = [:]
    /// Markets the user closed, or sent a close for, from this app — and when.
    private var userCloses: [Int: Date] = [:]
    /// Price alerts this run fired: never fired twice, even before their removal is read back.
    private var firedPriceAlerts: Set<UUID> = []
    private var lastPerps: Date?
    private var lastPrices: Date?

    /// Follows the account signed in (nil when none): starts the loop for a new account, keeps the one watching this
    /// account, stops it when no one is signed in. `signedIn` is read again before a price alert fires; `canAct` is false
    /// for a watched (watch-only) wallet, whose alerts never suggest an action it can't take.
    func bind(owner: Address?, env: AppEnvironment, signedIn: @escaping () -> Address?, canAct: @escaping () -> Bool) {
        self.env = env
        self.signedIn = signedIn
        self.canAct = canAct
        switch loop.bind(owner) {
        case .keep:
            return
        case .stop:
            stopRun()
        case .start(let run):
            stopRun()
            guard let owner else { return }
            task = Task { [weak self] in await self?.watch(run: run, owner: owner) }
        }
    }

    /// The app went to the background: checks pause until it is back.
    func enteredBackground() { foreground = false }

    /// The app is back in the foreground: everything is checked at once, not at the next tick.
    func enteredForeground() {
        guard !foreground else { return }
        foreground = true
        wakeRequested = true
        sleeper?.task.cancel()
    }

    /// The user closed `perpId`'s position, or sent a close for it, from this app: its ending is expected, not news.
    func noteUserClose(_ perpId: Int) { userCloses[perpId] = Date() }

    /// A close noted as sent never left the device: the position's ending is news again.
    func forgetUserClose(_ perpId: Int) { userCloses[perpId] = nil }

    private func stopRun() {
        task?.cancel()
        task = nil
        sleeper?.task.cancel()
        sleeper = nil
        wakeRequested = false
        positions = PerpPositionWatch()
        risk = PerpRiskWatch()
        markets = []
        marketsReadAt = nil
        restingCloseMarkets = []
        pendingEndings = [:]
        userCloses = [:]
        firedPriceAlerts = []
        lastPerps = nil
        lastPrices = nil
    }

    private func watch(run: Int, owner: Address) async {
        var woke = true
        while !Task.isCancelled, loop.mayPost(run: run, owner: owner) {
            if foreground {
                if AlertLoop.due(last: lastPerps, interval: AlertLoop.perpsInterval, now: Date(), woke: woke) {
                    lastPerps = Date()
                    await checkPerps(run: run, owner: owner)
                }
                if loop.mayPost(run: run, owner: owner), AlertLoop.due(last: lastPrices, interval: AlertLoop.priceInterval, now: Date(), woke: woke) {
                    lastPrices = Date()
                    await checkPrices(run: run, owner: owner)
                }
            }
            woke = await pause(AlertLoop.perpsInterval, run: run)
        }
    }

    /// Sleeps `seconds`, or less when the app comes back to the foreground; true when it was woken. A run that is no
    /// longer the newest returns at once, and never touches the newest run's sleep or wake.
    private func pause(_ seconds: TimeInterval, run: Int) async -> Bool {
        guard loop.run == run else { return false }
        if wakeRequested { wakeRequested = false; return true }
        let sleep = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleeper = (run, sleep)
        await sleep.value
        // A newer run owns the sleep and the wake now.
        guard loop.run == run else { return false }
        sleeper = nil
        defer { wakeRequested = false }
        return wakeRequested
    }

    private var preferences: AlertPreferences? {
        guard let settings = env?.settings else { return nil }
        return AlertPreferences(notificationsEnabled: settings.notificationsEnabled, fills: settings.notifyFills,
                                priceAlerts: settings.notifyPriceAlerts, marginWarnings: settings.notifyMargin)
    }

    // MARK: Price alerts

    /// Checks the account's price alerts on the prices every screen shows (DyorHQ coins on their own curve or pool), fires
    /// the ones crossed and removes them. A price that can't be read never fires and never removes its alert.
    private func checkPrices(run: Int, owner: Address) async {
        guard let env, preferences?.checksPriceAlerts == true else { return }
        let alerts = PriceAlertStore.all(owner: owner)
        guard !alerts.isEmpty else { return }
        let tokens = alerts.map { Token(address: $0.token, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) }
        guard let prices = try? await env.prices.prices(for: tokens) else { return }
        // The account may have changed during the read: its alerts are not this one's to fire.
        guard loop.mayPost(run: run, owner: owner), NotificationHub.shared.owner == owner, preferences?.checksPriceAlerts == true else { return }
        // Read again: an alert deleted during the read doesn't fire.
        let current = PriceAlertStore.all(owner: owner)
        let checks = current.map { PriceAlertCheck.Alert(id: $0.id, token: $0.token, target: $0.target, above: $0.above) }
        let firing = PriceAlertCheck.firing(checks, prices: prices.mapValues(\.usd), readFor: owner, signedIn: signedIn(), alreadyFired: firedPriceAlerts)
        for check in firing {
            guard let alert = current.first(where: { $0.id == check.id }), let price = prices[alert.token]?.usd else { continue }
            Notifications.priceAlert(symbol: alert.symbol, above: alert.above, target: alert.target, price: price)
            firedPriceAlerts.insert(alert.id)
        }
        PriceAlertStore.removeFired(Set(firing.map(\.id)), owner: owner)
    }

    // MARK: Perps

    /// Reads the account's open positions — the reads the Perps screen makes — and posts what changed: an order that
    /// filled, a position that ended (unless the trading stream already said how), and a margin warning that rose. A read
    /// that fails changes nothing.
    private func checkPerps(run: Int, owner: Address) async {
        guard let env else { return }
        let perpl = env.perpl
        let account: PerpAccount?
        do { account = try await perpl.account(owner) } catch { return }
        var fresh: [PerpPosition] = []
        var resting: Set<Int>?
        if let account, !account.positionPerpIds.isEmpty {
            // The markets (decimals and maintenance margin), read again every five minutes, and at once for a market not
            // read yet.
            let stale = marketsReadAt.map { Date().timeIntervalSince($0) > 300 } ?? true
            let missing = account.positionPerpIds.filter { id in !markets.contains { $0.id == id } }
            if stale || !missing.isEmpty {
                guard let read = try? await perpl.markets(ids: Self.marketIds(including: account.positionPerpIds)) else { return }
                guard loop.mayPost(run: run, owner: owner) else { return }
                markets = read
                marketsReadAt = Date()
                env.perplTrading.noteMarkets(read)
            }
            do { fresh = try await perpl.positions(account, markets: markets) } catch { return }
            // Only a market with a position can hold a close order that matters here.
            let held = markets.filter { account.positionPerpIds.contains($0.id) }
            if let orders = try? await perpl.openOrders(account, markets: held) { resting = Set(orders.filter(\.reduceOnly).map(\.perpId)) }
        }
        guard loop.mayPost(run: run, owner: owner), signedIn() == owner, let preferences else { return }
        let now = Date()

        let changes = positions.update(fresh, stillOpen: Set(account?.positionPerpIds ?? []))
        for ended in changes.ended {
            // The TP/SL that position leaves behind, in case the stream's own report was missed (security audit GT-2).
            env.perplTrading.positionClosedOnChain(marketId: ended.perpId, isLong: ended.side == .long)
            pendingEndings[ended.perpId] = (ended, now, restingCloseMarkets.contains(ended.perpId))
        }
        if let resting { restingCloseMarkets = resting } else if account?.positionPerpIds.isEmpty ?? true { restingCloseMarkets = [] }

        if preferences.postsFills {
            for position in changes.filled {
                Notifications.perpOrder(.filled, side: position.side == .long ? "Long" : "Short",
                                        market: "\(asset(position.perpId, symbol: position.symbol))-PERP", perpId: position.perpId)
            }
        }

        for (perpId, ending) in pendingEndings.sorted(by: { $0.key < $1.key }) {
            let notice = PerpEndingNotice.decide(endedAt: ending.since, now: now, userClosedAt: userCloses[perpId],
                                                 explainedByStream: env.perplTrading.endingExplained(marketId: perpId),
                                                 streamLive: env.perplTrading.positionsAreLive, restingClose: ending.restingClose)
            if notice == .wait { continue }
            pendingEndings[perpId] = nil
            if let text = PerpAlertText.ending(notice, position: ending.position, asset: asset(perpId, symbol: ending.position.symbol)) {
                Activity.record(ActivityRecord(kind: .perp, title: text.title, subtitle: text.body, hash: nil, section: "perps",
                                               reference: PerpAlertText.reference(perpId: perpId)), owner: owner)
            }
        }

        guard preferences.checksMargin else { risk.reset(); return }
        let maintenance = Dictionary(markets.compactMap { market in market.maintMarginFraction.map { (market.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for notice in risk.update(fresh, maintenance: maintenance) {
            let text = PerpAlertText.risk(notice, asset: asset(notice.position.perpId, symbol: notice.position.symbol), canAct: canAct())
            NotificationHub.shared.post(kind: .perp, title: text.title, body: text.body, route: .perps,
                                        reference: PerpAlertText.reference(perpId: notice.position.perpId), owner: owner)
        }
    }

    /// The app's markets, plus any market the account holds a position in that Perpl added after this build.
    private static func marketIds(including held: [Int]) -> [Int] {
        let listed = PerplService.markets.map(\.id)
        return listed + held.filter { !listed.contains($0) }
    }

    private func asset(_ perpId: Int, symbol: String) -> String {
        markets.first { $0.id == perpId }?.asset ?? symbol
    }
}
