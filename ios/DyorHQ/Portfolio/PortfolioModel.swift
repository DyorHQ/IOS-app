import BigInt
import DyorKit
import OSLog
import Foundation
import Observation

/// The wallet's money history across every section of DyorHQ — Spot swaps, Perps, Launch and Moments — reduced to
/// volume, fees paid, P&L, claimed fees and trade counts, for any reporting period. Sources:
///  · Spot: the wallet's swaps reconstructed from ERC-20 `Transfer` logs (rpc1, up to 90 days).
///  · Perps: Perpl's authenticated fill and position history (exact notional, fees and realized P&L).
///  · Launch: the wallet's own `CurveBuy` / `CurveSell` fills (exact fee + tax), the creator fees the escrows paid straight
///    to it, and escrow / holder-reward claims.
///  · Moments: `Collected` / `Claimed` / `Withdrawn` events plus swaps on Moment pools.
/// Dollar values: stablecoins count at $1; everything else is valued at the current price (so P&L is marked to
/// today's prices, and a swap between two unpriced tokens counts zero volume rather than a guess).
@Observable
@MainActor
final class PortfolioModel {
    enum Section: String, CaseIterable, Identifiable {
        case spot, perps, launch, moments, bridge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .spot: return tr(LocalizedStringResource("Spot", comment: "Spot, as against perpetual futures (Perps): the wallet's own tokens, and trading them by swaps [tight]"))
            case .perps: return tr(LocalizedStringResource("Perps", comment: "Perpetual futures [tight]"))
            case .launch: return tr(LocalizedStringResource("Launch", comment: "A noun: the Launch tab, the launchpad's coins [tight]"))
            case .moments: return tr(LocalizedStringResource("Moments", comment: "The Moments feature's name [tight]"))
            case .bridge: return tr(LocalizedStringResource("Bridge", comment: "A noun: the cross-chain bridge [tight]"))
            }
        }
        var symbol: String {
            switch self {
            case .spot: return "arrow.left.arrow.right"
            case .perps: return "chart.line.uptrend.xyaxis"
            case .launch: return "flame"
            case .moments: return "camera.aperture"
            case .bridge: return "point.3.connected.trianglepath.dotted"
            }
        }
        var menuItem: MenuItem {
            switch self {
            case .spot: return .spot
            case .perps: return .perps
            case .launch: return .launch
            case .moments: return .moments
            case .bridge: return .home // the Bridge lives on Home
            }
        }
    }

    struct Stats: Hashable {
        var volume = 0.0
        var fees = 0.0
        var pnl = 0.0
        /// Fees and proceeds that reached the wallet: creator fees paid straight to it or claimed, holder rewards claimed,
        /// Moments proceeds and pool fees withdrawn (the "Fees received" figure).
        var claimedFees = 0.0
        var trades = 0
        /// False when part of the P&L could not be valued (an unpriced token), so the figure is a lower bound.
        var pnlComplete = true

        static func + (a: Stats, b: Stats) -> Stats {
            Stats(volume: a.volume + b.volume, fees: a.fees + b.fees, pnl: a.pnl + b.pnl, claimedFees: a.claimedFees + b.claimedFees, trades: a.trades + b.trades, pnlComplete: a.pnlComplete && b.pnlComplete)
        }
    }

    /// One thing the wallet did, for the activity list.
    struct Activity: Identifiable, Hashable {
        let id: String
        let section: Section
        let title: String
        let subtitle: String
        let time: Date
        let usd: Double?
        let hash: Data?
    }

    private(set) var loading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    /// Why perps history is missing, when it is (no Perpl API key on this device).
    private(set) var perpsNote: String?
    private(set) var loadedFor: Address?
    /// The wallet the latest load is for. A load started for another (a refresh or a reload that outlived an account
    /// switch) publishes nothing: `reset` cleared that wallet's data, and this one's must not come back (RS-10).
    private var loadingFor: Address?
    /// The on-chain history as the history model has it (`applyHistory`): how far each period's figures have been read
    /// (`historyFilling`, `historyProgress`), whether the chain could be reached, and the day the transfer history
    /// reaches back to.
    private var history = WalletHistorySnapshot.empty
    private(set) var historyUnreachable = false
    private(set) var historySince: Date?
    private var historyVersion = -1

    // Raw, period-agnostic material.
    private var swaps: [SwapRecord] = []
    private var fills: [PerplFill] = []
    private var closed: [PerplPositionRecord] = []
    private var launchHistory = LaunchpadWalletHistory.empty
    private var momentsHistory = MomentsAccountHistory.empty
    private var launchesByCurve: [Address: Launch] = [:]
    private var launchesByToken: [Address: Launch] = [:]
    private var momentsByCoin: [Address: MomentInfo] = [:]
    /// Moments of every cohort — the live one and the retired ones — by (factory, id): ids restart at 1 per factory.
    private var momentsByKey: [MomentKey: MomentInfo] = [:]
    private var tokens: [Address: Token] = [:]
    /// Current USD price per whole unit, for every token that could be priced.
    private var prices: [Address: Double] = [:]

    private static let stables: Set<Address> = [Monad.usdc, Monad.ausd, Monad.usdt0]

    // MARK: Reading

    func totals(_ period: VolumePeriod) -> Stats {
        Section.allCases.reduce(Stats()) { $0 + stats($1, period) }
    }

    /// Whether `period`'s figures built from `scans` (`WalletHistoryScans.volume` for Total Volume, every scan where fees
    /// received show too) are still being read: some of those scans hasn't read every block since the period began (All:
    /// its whole window), with the chain reachable. The store reads newest first, so the last day is read long before
    /// the last month: each period says so only until its own window is. Until then its figures are a part, and say so.
    func historyFilling(_ period: VolumePeriod, scans: [String]) -> Bool {
        history.filling(since: historyStart(period), scans: scans)
    }

    /// How far `scans` have read `period`'s window, 0 to 1 (`historyFilling`).
    func historyProgress(_ period: VolumePeriod, scans: [String]) -> Double {
        history.progress(since: historyStart(period), scans: scans)
    }

    /// The moment `period`'s window starts at, as its figures are cut (`stats`); nil for All, every scan's whole window.
    private func historyStart(_ period: VolumePeriod) -> Date? {
        period.seconds == nil ? nil : period.since()
    }

    func stats(_ section: Section, _ period: VolumePeriod) -> Stats {
        let since = period.since()
        switch section {
        case .spot: return spotStats(since: since, kind: .spot)
        case .perps: return perpsStats(since: since)
        case .launch: return launchStats(since: since)
        case .moments: return momentsStats(since: since)
        case .bridge: return bridgeStats(since: since)
        }
    }

    /// Cross-chain bridges aren't visible to the Monad history scan, so their volume comes from the local record the
    /// Bridge writes on completion (BridgeStore), keyed to the loaded wallet.
    private func bridgeStats(since: Date) -> Stats {
        var stats = Stats()
        for record in BridgeStore.all(owner: loadedFor) where record.time >= since {
            stats.volume += record.usd
            stats.trades += 1
        }
        return stats
    }

    /// Everything in the period, newest first.
    func activity(_ period: VolumePeriod) -> [Activity] {
        let since = period.since()
        var out: [Activity] = []
        for swap in swapsLessFills where swap.time >= since {
            let kind = classify(swap)
            let section: Section = kind == .launch ? .launch : kind == .moments ? .moments : .spot
            out.append(Activity(id: "swap-\(swap.id)", section: section, title: kind == .spot ? tr("Swapped") : tr("Traded on \(section.title)"), subtitle: SwapHistoryItem.describe(swap, tokens: tokens), time: swap.time, usd: swapUSD(swap), hash: swap.hash))
        }
        for fill in fills where fill.time >= since {
            out.append(Activity(id: "fill-\(fill.id)", section: .perps, title: "\(fill.direction) \(fill.symbol)", subtitle: tr("\(NumberStyle.number(fill.size)) at \(NumberStyle.number(fill.price)) · fee \(PriceFormat.usdValue(fill.fee))"), time: fill.time, usd: fill.notional, hash: nil))
        }
        for f in launchHistory.fills where f.time >= since {
            let launch = launchesByCurve[f.curve]
            let symbol = launch?.symbol ?? f.curve.short
            let pair = launch?.pair
            let quote = pair.map { "\(NumberStyle.units(f.quoteAmount, decimals: $0.decimals, compact: true)) \($0.symbol)" } ?? ""
            out.append(Activity(id: "curve-\(f.id)", section: .launch, title: f.isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)"), subtitle: "\(NumberStyle.units(f.tokenAmount, decimals: 18, compact: true)) \(symbol) · \(quote)", time: f.time, usd: launchQuoteUSD(f), hash: f.hash))
        }
        for c in launchHistory.claims where c.time >= since {
            let usd = claimUSD(c)
            out.append(Activity(id: "lclaim-\(c.id)", section: .launch, title: c.kind == .creatorFees ? tr("Claimed creator fees") : tr("Claimed holder rewards"), subtitle: c.launchToken.flatMap { launchesByToken[$0]?.symbol }.map { "$\($0)" } ?? "", time: c.time, usd: usd, hash: c.hash))
        }
        for p in launchHistory.payments where p.time >= since {
            let asset = paymentAsset(p)
            out.append(Activity(id: "lpaid-\(p.id)", section: .launch, title: tr("Received creator fees"), subtitle: "\(NumberStyle.units(p.amount, decimals: asset.decimals)) \(asset.symbol)", time: p.time, usd: paymentUSD(p), hash: p.hash))
        }
        for c in momentsHistory.collects where c.time >= since {
            let m = momentsByKey[c.key]
            out.append(Activity(id: "collect-\(c.id)", section: .moments, title: tr("Collected \(m?.name ?? tr("Moment #\(String(c.momentId))"))"), subtitle: tr("\(c.editions) editions · \(NumberStyle.number(MomentsMath.coins(c.entitlement), compact: true)) \(m?.symbol ?? tr("coins"))"), time: c.time, usd: MomentsMath.usdc(c.gross), hash: c.hash))
        }
        for c in momentsHistory.claims where c.time >= since {
            let m = momentsByKey[c.key]
            out.append(Activity(id: "mclaim-\(c.id)", section: .moments, title: m.map { tr("Claimed \($0.symbol)") } ?? tr("Claimed coins"), subtitle: tr("\(NumberStyle.number(MomentsMath.coins(c.total), compact: true)) \(m?.symbol ?? "") vested"), time: c.time, usd: m?.pool.map { MomentsMath.coins(c.total) * $0.usdcPerCoin }, hash: c.hash))
        }
        for w in momentsHistory.withdrawals where w.time >= since {
            let m = momentsByKey[w.key]
            out.append(Activity(id: "mwd-\(w.id)", section: .moments, title: w.kind == .poolFees ? tr("Withdrew pool fees") : tr("Withdrew proceeds"), subtitle: m?.name ?? tr("Moment #\(String(w.momentId))"), time: w.time, usd: MomentsMath.usdc(w.amount), hash: w.hash))
        }
        for p in momentsHistory.publishes where p.time >= since {
            let m = momentsByKey[p.key]
            out.append(Activity(id: "pub-\(p.id)", section: .moments, title: tr("Published \(m?.name ?? tr("Moment #\(String(p.momentId))"))"), subtitle: m.map { "$\($0.symbol)" } ?? "", time: p.time, usd: nil, hash: p.hash))
        }
        for b in BridgeStore.all(owner: loadedFor) where b.time >= since {
            out.append(Activity(id: "bridge-\(b.id)", section: .bridge, title: tr("Bridged \(b.inSymbol) → \(b.outSymbol)"), subtitle: "\(b.fromChain) → \(b.toChain)", time: b.time, usd: b.usd, hash: nil))
        }
        return out.sorted { $0.time > $1.time }
    }

    // MARK: Per-section math

    private enum SwapKind { case spot, launch, moments }

    private func classify(_ swap: SwapRecord) -> SwapKind {
        if momentsByCoin[swap.soldToken] != nil || momentsByCoin[swap.boughtToken] != nil { return .moments }
        if launchesByToken[swap.soldToken] != nil || launchesByToken[swap.boughtToken] != nil { return .launch }
        return .spot
    }

    /// The transactions of the wallet's curve fills: a curve buy or sell moves the coin and the pair asset in the same
    /// transaction, so the transfer history reads it as a swap too. The fill is the record; the swap is left out.
    private var fillTransactions: Set<Data> { Set(launchHistory.fills.map(\.hash)) }

    /// The wallet's swaps, less those that are curve fills.
    private var swapsLessFills: [SwapRecord] {
        let fills = fillTransactions
        return fills.isEmpty ? swaps : swaps.filter { !fills.contains($0.hash) }
    }

    private func units(_ token: Address, _ raw: BigUInt) -> Double {
        Amount.units(raw, decimals: tokens[token]?.decimals ?? 18)
    }

    /// The dollar size of a swap: a stable leg counts exactly; otherwise the priced leg at today's price.
    private func swapUSD(_ swap: SwapRecord) -> Double? {
        if Self.stables.contains(swap.soldToken) { return units(swap.soldToken, swap.soldAmount) }
        if Self.stables.contains(swap.boughtToken) { return units(swap.boughtToken, swap.boughtAmount) }
        if let price = prices[swap.soldToken] { return units(swap.soldToken, swap.soldAmount) * price }
        if !swap.boughtNativeUnknown, let price = prices[swap.boughtToken] { return units(swap.boughtToken, swap.boughtAmount) * price }
        return nil
    }

    /// Volume, P&L (dollars out minus dollars in plus the net token position at today's prices) and count for the
    /// wallet's swaps of one kind. Moment-pool swaps also carry the 1.5% all-in trading fee on the USDC side.
    private func spotStats(since: Date, kind: SwapKind) -> Stats {
        var stats = Stats()
        var spent = 0.0, received = 0.0
        var deltas: [Address: Double] = [:]
        for swap in swapsLessFills where swap.time >= since && classify(swap) == kind {
            stats.trades += 1
            let usd = swapUSD(swap)
            stats.volume += usd ?? 0
            if kind == .moments, let usd { stats.fees += usd * Double(MomentsConstants.totalTradeFeeBps) / 10_000 }
            // A sale into MON whose MON couldn't be read counts in volume, not in P&L: as "0 MON" it read as a loss of
            // everything sold. The P&L says it is incomplete.
            if swap.boughtNativeUnknown { stats.pnlComplete = false; continue }
            if Self.stables.contains(swap.soldToken) { spent += units(swap.soldToken, swap.soldAmount) } else { deltas[swap.soldToken, default: 0] -= units(swap.soldToken, swap.soldAmount) }
            if Self.stables.contains(swap.boughtToken) { received += units(swap.boughtToken, swap.boughtAmount) } else { deltas[swap.boughtToken, default: 0] += units(swap.boughtToken, swap.boughtAmount) }
        }
        var position = 0.0
        for (token, delta) in deltas where abs(delta) > 0 {
            if let price = prices[token] { position += delta * price } else { stats.pnlComplete = false }
        }
        stats.pnl = received - spent + position
        return stats
    }

    private func perpsStats(since: Date) -> Stats {
        var stats = Stats()
        for fill in fills where fill.time >= since {
            stats.volume += fill.notional
            stats.fees += fill.fee
            stats.trades += 1
        }
        for record in closed where record.time >= since {
            stats.pnl += record.realizedPnl
        }
        return stats
    }

    private func pairUSD(_ launch: Launch) -> Double? {
        launch.pair.isNative ? prices[Monad.native] : prices[launch.pairToken]
    }

    private func launchQuoteUSD(_ fill: WalletCurveFill) -> Double? {
        guard let launch = launchesByCurve[fill.curve], let price = pairUSD(launch) else { return nil }
        return Amount.units(fill.quoteAmount, decimals: launch.pair.decimals) * price
    }

    /// A creator fee paid straight to the wallet: its asset's symbol and decimals (MON, or a pair token).
    private func paymentAsset(_ payment: WalletFeePayment) -> (symbol: String, decimals: Int) {
        if payment.token.isZero { return ("MON", 18) }
        if let token = tokens[payment.token] { return (token.symbol, token.decimals) }
        if let core = Token.core(payment.token) { return (core.symbol, core.decimals) }
        return (payment.token.short, 18)
    }

    private func paymentUSD(_ payment: WalletFeePayment) -> Double? {
        guard let price = payment.token.isZero ? prices[Monad.native] : prices[payment.token] else { return nil }
        return Amount.units(payment.amount, decimals: paymentAsset(payment).decimals) * price
    }

    private func claimUSD(_ claim: WalletFeeClaim) -> Double? {
        switch claim.kind {
        case .creatorFees:
            let decimals = claim.token.isZero ? 18 : (tokens[claim.token]?.decimals ?? 18)
            guard let price = claim.token.isZero ? prices[Monad.native] : prices[claim.token] else { return nil }
            return Amount.units(claim.amount, decimals: decimals) * price
        case .holderRewards:
            guard let token = claim.launchToken, let launch = launchesByToken[token], let price = pairUSD(launch) else { return nil }
            return Amount.units(claim.amount, decimals: launch.pair.decimals) * price
        }
    }

    /// Curve fills: volume in the pair asset's dollars, exact fee + tax, P&L against today's curve price, plus the
    /// wallet's launch-pool swaps and every fee claim.
    private func launchStats(since: Date) -> Stats {
        var stats = spotStats(since: since, kind: .launch)
        var spent = 0.0, received = 0.0
        var deltas: [Address: Double] = [:]
        for fill in launchHistory.fills where fill.time >= since {
            guard let launch = launchesByCurve[fill.curve] else { continue }
            stats.trades += 1
            guard let price = pairUSD(launch) else { stats.pnlComplete = false; continue }
            let quoteUSD = Amount.units(fill.quoteAmount, decimals: launch.pair.decimals) * price
            stats.volume += quoteUSD
            stats.fees += Amount.units(fill.fee + fill.tax, decimals: launch.pair.decimals) * price
            let coins = Amount.units(fill.tokenAmount, decimals: 18)
            if fill.isBuy { spent += quoteUSD; deltas[launch.token, default: 0] += coins } else { received += quoteUSD; deltas[launch.token, default: 0] -= coins }
        }
        for (token, delta) in deltas where abs(delta) > 0 {
            if let price = prices[token] { stats.pnl += delta * price } else { stats.pnlComplete = false }
        }
        stats.pnl += received - spent
        for claim in launchHistory.claims where claim.time >= since {
            if let usd = claimUSD(claim) { stats.claimedFees += usd } else { stats.pnlComplete = false }
        }
        for payment in launchHistory.payments where payment.time >= since {
            if let usd = paymentUSD(payment) { stats.claimedFees += usd } else { stats.pnlComplete = false }
        }
        return stats
    }

    /// Collects (gross USDC, the platform share as the fee), coins valued once the Moment has a market, pool
    /// swaps, and withdrawn proceeds / pool fees as claimed fees.
    private func momentsStats(since: Date) -> Stats {
        var stats = spotStats(since: since, kind: .moments)
        for collect in momentsHistory.collects where collect.time >= since {
            stats.trades += 1
            let gross = MomentsMath.usdc(collect.gross)
            stats.volume += gross
            stats.fees += MomentsMath.usdc(collect.platformIn)
            // A collect's coins only have a price once the pool exists; until then the collect is pending, not a loss.
            if let pool = momentsByKey[collect.key]?.pool {
                stats.pnl += MomentsMath.coins(collect.entitlement) * pool.usdcPerCoin - gross
            }
        }
        for withdrawal in momentsHistory.withdrawals where withdrawal.time >= since {
            stats.claimedFees += MomentsMath.usdc(withdrawal.amount)
        }
        return stats
    }

    // MARK: Loading

    /// Loads the reference data (launches, Moments, the token universe), prices and perps for the wallet, and takes its
    /// on-chain history from the history model (`HistoryModel`), which fills it in behind every screen: `applyHistory`
    /// rebuilds the figures whenever it moves. `force` re-reads even when the last load is fresh (under five minutes
    /// old). `passkey`: the account signs with a passkey, whose Perpl history loads only while its session is unlocked.
    func load(env: AppEnvironment, address: Address?, perplKey: PerplApiKey?, force: Bool, passkey: Bool = false) async {
        guard let address else { reset(); return }
        // A cached load that skipped perps for lack of a Perpl key (or hit a transient perps error) must not be
        // served once a key is available — otherwise perps volume stays 0 in the whole-app total. On a cold start the
        // Portfolio load reads perplTrading.key before RootView's refresh(account:) has loaded it from the Keychain,
        // so re-fetch when we now have a key and the last load noted a perps gap. A clean keyed load clears perpsNote.
        if !force, loadedFor == address, !(perpsNote != nil && perplKey != nil), let updatedAt, Date().timeIntervalSince(updatedAt) < 300 {
            applyHistory(env.history.snapshot, version: env.history.version, for: address)
            return
        }
        if loadedFor != address { reset() }
        loadingFor = address
        loading = true
        defer { loading = false }
        // Nothing is published until every read is back, and a failed read never replaces what the last good one showed
        // (security audit 2026-09-26, RS-10): the history comes from the store, which only ever grows, and a load for a
        // wallet that is no longer the latest one asked for publishes nothing, so what is kept is always this wallet's.

        // Reference data first: the launch list (curves + pair assets), the Moments list (coins + pools), the token universe.
        // Launches on retired factories are history too: the coins and trades stay part of the wallet's record.
        async let launchesTask = env.launchpad.launchListing(limit: 200)
        async let momentsTask = env.moments.moments(limit: 200)
        // Moments of the retired cohorts are history too (their collects, claims and withdrawals); keyed by (factory, id).
        // A cohort that can't be read keeps the Moments the last load read of it, and the load says it is incomplete.
        let previousMoments = Array(momentsByKey.values)
        async let retiredMomentsTask = PastMomentsModel.allMoments(env: env, keeping: previousMoments)
        // A launchpad whose launches couldn't be read keeps its last good ones, and the load says it is incomplete.
        let listing = await launchesTask
        let fetchedMoments = try? await momentsTask
        let retired = await retiredMomentsTask
        let launches = listing.keeping(Array(launchesByCurve.values))
        let moments = fetchedMoments.map { $0 + retired.moments } ?? Array(momentsByKey.values)

        var universe = KnownTokenStore.universe(owner: address)
        universe += launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        universe += moments.map(\.coinToken)
        universe += Set(launches.map(\.pairToken)).compactMap { pair -> Token? in
            guard !pair.isZero, !universe.contains(where: { $0.address == pair }), let launch = launches.first(where: { $0.pairToken == pair }) else { return nil }
            return Token(address: pair, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
        }
        let tokenMap = Dictionary(universe.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let curves = Set(launches.map(\.curve))
        let momentsCoins = Set(moments.map(\.moment.coin))
        // The history model builds the records again with the launches' curves and the tokens' decimals.
        env.history.setReference(env: env, curves: curves, decimals: tokenMap.mapValues(\.decimals))

        let priceable = universe.filter { !$0.isLaunchpad && !momentsCoins.contains($0.address) }
        async let pricesTask = env.prices.prices(for: priceable)
        async let perpsTask = loadPerps(env: env, key: perplKey, passkey: passkey)
        let fetchedPrices = try? await pricesTask
        let perps = await perpsTask
        guard !Task.isCancelled, loadingFor == address else { return }

        launchesByCurve = Dictionary(launches.map { ($0.curve, $0) }, uniquingKeysWith: { first, _ in first })
        launchesByToken = Dictionary(launches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        momentsByCoin = Dictionary(moments.map { ($0.moment.coin, $0) }, uniquingKeysWith: { first, _ in first })
        momentsByKey = Dictionary(moments.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        tokens = tokenMap
        var priced: [Address: Double] = fetchedPrices == nil ? prices : [:]
        if let map = fetchedPrices { for (address, info) in map { priced[address] = info.usd } }
        for stable in Self.stables { priced[stable] = 1 }
        // Launch coins at the one decimal price Spot values them at: the price service's for a coin it priced, else the
        // launch's own live price in its pair asset (`DyorPrice.launch`), never the integer `Launch.price`. Moment coins
        // at their pool price.
        for launch in launches {
            priced[launch.token] = DyorPrice.launch(launch, spot: fetchedPrices?[launch.token]?.usd, pairUSD: launch.pair.isNative ? priced[Monad.native] : priced[launch.pairToken])
        }
        for info in moments { if let pool = info.pool { priced[info.moment.coin] = pool.usdcPerCoin } }
        prices = priced
        fills = perps.fills
        closed = perps.closed
        perpsNote = perps.note

        loadedFor = address
        hasLoaded = true
        applyHistory(env.history.snapshot, version: env.history.version, for: address, force: true)
        Logger(subsystem: "fun.dyorhq.app", category: "portfolio").info("portfolio for \(address.short, privacy: .public): swaps \(self.swaps.count) launch fills \(self.launchHistory.fills.count) collects \(self.momentsHistory.collects.count) launches \(launches.count) history \(self.history.progress)")
        if !listing.complete || fetchedMoments == nil || !retired.complete || fetchedPrices == nil {
            error = tr("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.")
            updatedAt = nil
        } else {
            error = nil
            updatedAt = .now
        }
    }

    /// The wallet's on-chain history as the history model has it now (`HistoryModel.snapshot`): the swaps, launchpad
    /// and Moments records the figures are built from, and how far it has got. Called whenever `HistoryModel.version`
    /// moves, and at the end of a load; a snapshot for another wallet, or one already applied, changes nothing.
    func applyHistory(_ snapshot: WalletHistorySnapshot, version: Int, for address: Address?, force: Bool = false) {
        guard let address, loadedFor == address || loadingFor == address, force || version != historyVersion else { return }
        historyVersion = version
        history = snapshot
        swaps = snapshot.swaps
        launchHistory = snapshot.launch
        momentsHistory = snapshot.moments
        historyUnreachable = snapshot.unreachable
        if let anchor = snapshot.anchor, let floor = snapshot.status(WalletHistoryScans.transfersInId).floor {
            historySince = BlockClock.time(of: floor, anchor: anchor, secondsPerBlock: BlockClock.fallbackSecondsPerBlock)
        }
    }

    private func reset() {
        loadingFor = nil
        swaps = []; fills = []; closed = []
        launchHistory = .empty; momentsHistory = .empty
        launchesByCurve = [:]; launchesByToken = [:]; momentsByCoin = [:]; momentsByKey = [:]
        tokens = [:]; prices = [:]
        hasLoaded = false; updatedAt = nil; loadedFor = nil; perpsNote = nil
        history = .empty; historyUnreachable = false; historySince = nil; historyVersion = -1
    }

    /// Perpl history needs the account's API key (one-click trading); up to 1,000 fills and 1,000 closed events. Without
    /// a key — never enrolled, or a passkey account whose session is locked — what was last read stays, and the note says
    /// what would load it.
    private func loadPerps(env: AppEnvironment, key: PerplApiKey?, passkey: Bool) async -> (fills: [PerplFill], closed: [PerplPositionRecord], note: String?) {
        guard let key else {
            return (fills, closed, passkey ? tr("Your Perpl history loads while your passkey session is unlocked.") : tr("Enable one-click trading in Profile → Perpl Trading to include your perps history."))
        }
        guard let markets = try? await env.perpl.markets(), !markets.isEmpty else { return (fills, closed, tr("Perpl markets could not be loaded.")) }
        do {
            let fills = try await Self.page(maxPages: 10) { try await env.perpl.fills(key: key, markets: markets, count: 100, cursor: $0) }
            let closed = try await Self.page(maxPages: 10) { try await env.perpl.positionHistory(key: key, markets: markets, count: 100, cursor: $0) }
            return (fills, closed, nil)
        } catch {
            return (self.fills, self.closed, tr("Perpl history: \(describe(error))"))
        }
    }

    private static func page<T: Sendable>(maxPages: Int, fetch: (String?) async throws -> PerplHistoryPage<T>) async rethrows -> [T] {
        var items: [T] = []
        var cursor: String? = nil
        for _ in 0..<maxPages {
            let page = try await fetch(cursor)
            items.append(contentsOf: page.items)
            guard let next = page.next, !next.isEmpty else { break }
            cursor = next
        }
        return items
    }
}
