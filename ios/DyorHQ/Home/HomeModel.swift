import BigInt
import DyorKit
import SwiftUI

// Home's model (`HomeModel`), and the row a token is listed as there (`MarketRow`).

/// A token as the Home screen shows it: price, movement, and the signed-in wallet's balance. `info` is the price read as
/// it came (a DyorHQ coin's "vs MON", "New" and price source); `notTradingYet` marks a Moment still collecting, which
/// has no price yet. Codable: Home saves its rows as it last showed them (`HomeModel.Saved`).
struct MarketRow: Identifiable, Hashable, Codable {
    let token: Token
    let usd: Double?
    let change24h: Double?
    let balance: BigUInt
    var info: PriceInfo? = nil
    var notTradingYet = false
    var id: Address { token.address }
    var value: Double? { usd.map { Amount.units(balance, decimals: token.decimals) * $0 } }
}

@Observable
@MainActor
final class HomeModel {
    /// A launch coin the wallet holds (or created), with the Launch tab's price for it: Spot's, else its own decimal
    /// price (`DyorPrice.launch`); nil when neither is known.
    struct LaunchHolding: Identifiable, Hashable, Codable {
        let launch: Launch
        let balance: BigUInt
        let priceUSD: Double?
        var id: Address { launch.token }
        /// Whole coins held.
        var units: Double { Amount.units(balance, decimals: 18) }
        var valueUSD: Double? { priceUSD.map { units * $0 } }
    }

    /// Home's four parts as the balance card splits them, once each of them can be told (`HomeReadState.showsValue`).
    struct Split: Hashable {
        let spot: Double
        let perps: Double
        let launch: Double
        let moments: Double
        var total: Double { spot + perps + launch + moments }
    }

    private(set) var rows: [MarketRow] = []
    private(set) var launches: [Launch] = []
    private(set) var launchHoldings: [LaunchHolding] = []
    private(set) var positions: [PerpPosition] = []
    /// The Perpl account's equity: 0 without an account, nil until it is read for the wallet (never taken for 0).
    private(set) var perpEquity: Double?
    /// The wallet's Moments stakes (editions, entitlements, coins), valued at each graduated pool's price.
    private(set) var momentRows: [MomentPortfolioRow] = []
    /// How far each part of the wallet has been read for it (`HomeReadState`): a figure from a part not read yet is nil,
    /// a placeholder on screen, and its holdings tab shows a loading row, or says it couldn't be read, with Retry.
    private(set) var reads = HomeReadState()
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    /// Tokens the wallet was sent rather than chose (`KnownTokenStore.unverified`): marked in holdings, and never
    /// ranked in Top Tokens.
    private(set) var unverified: Set<Address> = []
    /// When each part on screen was read for the wallet: in this session (`record`), or, for a part still showing what was
    /// saved, when that was read (`restoreSaved`). What Home saves carries these times (`save`). Not observed: `savedAt`
    /// changes only with `reads`, which is.
    @ObservationIgnored private var readAt: [HomeReadState.Part: Date] = [:]
    /// Whose data the model holds.
    private var loadedFor: Address?
    /// The launchpads whose launches have been read at least once, whoever is signed in (as `launches`, which they fill):
    /// one that couldn't be read keeps only the launches an earlier read found (`LaunchListing.keeping`), so the Launch
    /// tab is read in full only once every launchpad has been. Only reads in this session count: `launches` taken from a
    /// saved Home empties it (`restoreSaved`).
    @ObservationIgnored private var listedFactories: Set<Address> = []
    /// The registry taking in the coins of the launches and Moments the last load read (`DyorCoinsModel.ingest`).
    @ObservationIgnored private var ingesting: Task<Void, Never>?

    var holdings: [MarketRow] { rows.filter { $0.balance > 0 }.sorted { ($0.value ?? 0) > ($1.value ?? 0) } }

    /// When the oldest part still showing what was saved for the wallet was read (`restoreSaved`): Home says it ("Updated
    /// 3 min ago") until every part on screen was read in this session, and then this is nil.
    var savedAt: Date? { HomeReadState.Part.allCases.filter { reads.isSaved($0) }.compactMap { readAt[$0] }.min() }

    /// Spot, Launch and Moments with every address counted once (`HomeTotals`): a DyorHQ coin stays listed in Spot but
    /// counts under Launch or Moments when that tab lists it, at the one price Spot shows for it.
    var totals: HomeTotals {
        HomeTotals(spot: holdings.map { HomeTotals.Line(address: $0.id, units: Amount.units($0.balance, decimals: $0.token.decimals), price: $0.usd) },
                   launch: launchHoldings.map { HomeTotals.Line(address: $0.id, units: $0.units, price: $0.priceUSD) },
                   moments: momentRows.map { HomeTotals.Line(address: $0.moment.moment.coin, units: Self.coins($0), price: WalletHoldings.momentPrice($0.moment)) })
    }

    /// A Moments stake's coins: held, plus still owed (entitled, not yet claimed).
    nonisolated static func coins(_ row: MomentPortfolioRow) -> Double {
        let owed = row.entitlement > row.claimed ? row.entitlement - row.claimed : 0
        return MomentsMath.coins(row.coinBalance) + MomentsMath.coins(owed)
    }

    // Each part's figure is nil until it can be told for the wallet (`HomeReadState.showsValue`): a placeholder on
    // screen, never "$0.00" for want of an answer.

    /// The tokens no other tab counts (`HomeTotals.spot`), once the Launch and Moments tabs are read too.
    var spotValue: Double? { reads.showsValue(of: .spot) ? totals.spot : nil }
    /// The Perpl account's equity, 0 without one; nil while it is unread, a failed read included.
    var perpsValue: Double? { reads.showsValue(of: .perps) ? perpEquity : nil }
    /// Value of the launch coins the Launch tab lists. Feeds the allocation ring and total.
    var launchpadValue: Double? { reads.showsValue(of: .launch) ? totals.launch : nil }
    /// Value of the wallet's Moment coins (held plus still owed) at Spot's price or each pool's live one; a Moment with no
    /// market yet counts at zero.
    var momentsValue: Double? { reads.showsValue(of: .moments) ? totals.moments : nil }
    var availableBalance: Double? { spotValue }
    var inUse: Double? { perpsValue }

    /// The four parts' figures, once every one of them can be told: the allocation ring's shares and the total.
    var split: Split? {
        guard let spot = spotValue, let perps = perpsValue, let launch = launchpadValue, let moments = momentsValue else { return nil }
        return Split(spot: spot, perps: perps, launch: launch, moments: moments)
    }

    /// Everything the wallet holds: nil until every part is read for it, so a total short of one is never shown.
    var totalValue: Double? { split?.total }

    /// Value-weighted 24h change of the wallet, when every priced holding has a change.
    var change24h: Double? {
        let priced = holdings.filter { $0.value != nil && $0.change24h != nil }
        let total = priced.compactMap(\.value).reduce(0, +)
        guard total > 0 else { return nil }
        return priced.reduce(0) { $0 + ($1.value! / total) * $1.change24h! }
    }

    /// Top-tokens list per tab. Popular keeps the curated order; the movers sort by 24h change; hot ranks by the
    /// strength of the move in either direction (a stand-in for volume, which the price service does not surface).
    func topTokens(_ tab: HomeTokenTab) -> [MarketRow] {
        let priced = rows.filter { $0.usd != nil && !unverified.contains($0.id) }
        switch tab {
        case .popular: return priced
        case .hot: return priced.sorted { abs($0.change24h ?? 0) > abs($1.change24h ?? 0) }
        case .gainers: return priced.filter { ($0.change24h ?? 0) > 0 }.sorted { ($0.change24h ?? 0) > ($1.change24h ?? 0) }
        case .losers: return priced.filter { ($0.change24h ?? 0) < 0 }.sorted { ($0.change24h ?? 0) < ($1.change24h ?? 0) }
        }
    }

    /// The wallet and the state of its transfer history the tokens were last read for (`discoverHeldTokens`).
    private var discoveredFor: String?

    func poll(env: AppEnvironment, address: Address?) async {
        while !Task.isCancelled {
            await load(env: env, address: address)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Finds ERC-20s the wallet holds on-chain that aren't in its universe yet (received outside the app, airdropped,
    /// bridged), persists them to the shared token store as Unverified, and reloads — so every held token appears in
    /// holdings, marked, while the swap picker lists it only when searched for. Runs once per wallet; the
    /// persisted tokens then price and balance like any curated asset.
    /// The tokens the wallet's history shows it received, from the history model's transfers (no scan of its own): read
    /// again as the history fills in, and once more after it is complete.
    func discoverHeldTokens(env: AppEnvironment, address: Address?) async {
        guard let address, address == env.history.wallet else { return }
        let snapshot = env.history.snapshot
        let stage = "\(address.hex)-\(snapshot.transfersIn.count)-\(snapshot.status(WalletHistoryScans.transfersInId).complete)"
        guard discoveredFor != stage else { return }
        let known = Set(KnownTokenStore.universe(owner: address).map(\.address))
        let found = await env.walletDiscovery.held(wallet: address, incoming: snapshot.transfersIn, complete: snapshot.status(WalletHistoryScans.transfersInId).complete, known: known).tokens
        // Cut short (the history moved on meanwhile): read again at its next move, never skipped for good.
        guard !Task.isCancelled else { return }
        discoveredFor = stage
        guard !found.isEmpty else { return }
        // Give each discovered token an accurate logo from Kuru's directory (the venues don't serve icons).
        let logos = await env.kuruTokens.logos()
        for token in found {
            let enriched = token.logoURL == nil && logos[token.address] != nil
                ? Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logos[token.address], isLaunchpad: token.isLaunchpad)
                : token
            KnownTokenStore.addDiscovered(enriched, owner: address)
        }
        await load(env: env, address: address)
    }

    /// Takes in `address` before Home's first frame (`HomeView`'s `onAppear`) and at the start of every load: another
    /// account's figures go, and what was saved for this one when it was last read — a small file on the device, read on
    /// the spot — shows at once, each part said to be saved until its own read replaces it (`restoreSaved`). So a warm
    /// launch opens on the wallet's figures rather than on placeholders until the first load's task starts.
    func showSaved(env: AppEnvironment, address: Address?) {
        // Another account: nothing of the previous one's may stay on screen, even when a read below fails. What was saved
        // for this one when it was last read shows at once instead, each part said to be saved until its own read below
        // replaces it (`restoreSaved`).
        if address != loadedFor {
            rows = []; launchHoldings = []; positions = []; perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState(); readAt = [:]
            loadedFor = address
            restoreSaved(env: env, address: address)
        }
    }

    func load(env: AppEnvironment, address: Address?) async {
        loading = true
        defer { loading = false }
        // Already done before Home's first frame (`showSaved`), unless the account changed since.
        showSaved(env: env, address: address)
        // What this load reads is saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`).
        let epoch = env.savedScreens.epoch
        // The curated list plus anything the wallet has acquired (swapped into, launched), so held tokens like an
        // RWA or a launched coin still show up with a balance and a price.
        let tokens = KnownTokenStore.universe(owner: address).filter { $0.symbol != "WMON" }
        // The tokens the wallet was sent rather than chose, as the device has them now: the rows published below are
        // marked with them; the coins it made are taken out once the registry has read them (after the reads).
        unverified = KnownTokenStore.unverified(owner: address)
        // Each part is published as its own read lands, never held back by the slowest (`publishSpot`, `publishLaunch`,
        // `publishPerps`, `publishMoments`): its tab and its figure in the split fill in one by one. A load cancelled
        // part-way (the screen went away, the account changed) publishes nothing more:
        // what the rest of its reads answer is dropped.
        var priceMap: [Address: PriceInfo]?
        var priceError: Error?
        var notTrading: Set<Address> = []
        var pricesIn = false
        var balanceMap: [Address: BigUInt]?
        var balancesIn = false
        var listing: LaunchListing?
        var launchList: [Launch] = []
        var holdingsAsked = false
        var momentState: [MomentPortfolioRow]?
        await withTaskGroup(of: Answer.self) { group in
            // Which of them are DyorHQ coins, from their factories (MON, the curated tokens and coins already known cost
            // nothing): their pictures and labels, and the wallet's own coins below.
            group.addTask { await env.dyorCoins.prove(tokens); return .proven }
            group.addTask { await Self.readPrices(env: env, tokens: tokens) }
            group.addTask { .balances(await self.walletBalances(env: env, address: address, tokens: tokens)) }
            group.addTask { .listing(await env.launchpad.launchListing(limit: 30)) }
            group.addTask { .perps(await self.loadPerps(env: env, address: address)) }
            group.addTask { .moments(await self.loadMoments(env: env, address: address)) }
            while let answer = await group.next() {
                let stands = !Task.isCancelled && address == loadedFor
                switch answer {
                case .proven:
                    break
                case let .prices(map, error, collecting):
                    priceMap = map; priceError = error; notTrading = collecting; pricesIn = true
                    if stands, balancesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }
                case .balances(let map):
                    balanceMap = map; balancesIn = true
                    if stands, pricesIn { publishSpot(tokens: tokens, priceMap: priceMap, balanceMap: balanceMap, notTrading: notTrading) }
                case .listing(let read):
                    listing = read
                    // A launchpad whose launches couldn't be read keeps its last good ones, and the screen says so.
                    launchList = read.keeping(self.launches)
                    if stands {
                        listedFactories.formUnion(read.factories.filter { read.unread[$0] == nil })
                        self.launches = launchList
                    }
                case .launchHoldings(let holdings):
                    if stands, let listing { publishLaunch(holdings, priceMap: priceMap, listing: listing) }
                case .perps(let state):
                    if stands { publishPerps(state) }
                case .moments(let state):
                    momentState = state
                    if stands { publishMoments(state) }
                }
                // The launch coins once the launches and the prices that value them are in: one balance read over them.
                // Without prices they can't be valued, so the part isn't read, and keeps what it showed.
                if stands, !holdingsAsked, pricesIn, let listing {
                    holdingsAsked = true
                    if let priceMap {
                        let launches = launchList
                        group.addTask { .launchHoldings(await self.loadLaunchHoldings(env: env, address: address, launches: launches, priceMap: priceMap)) }
                    } else {
                        publishLaunch(nil, priceMap: nil, listing: listing)
                    }
                }
            }
        }
        // The registry takes in the coins of the launches and Moments just read without holding the rows back: their
        // pictures and labels follow once they are proven, as the coins model re-renders the rows. One at a time, so a
        // slow node never stacks them up across refreshes.
        if ingesting == nil {
            let readLaunches = launchList
            let readMoments = momentState?.map(\.moment) ?? []
            ingesting = Task {
                await env.dyorCoins.ingest(readLaunches)
                await env.dyorCoins.ingest(readMoments)
                ingesting = nil
            }
        }
        let ownCoins = address == nil ? [] : await env.dyorCoins.created(by: address ?? .zero)
        // A read that failed keeps what the last good one showed, and says so; a load cancelled part-way (the screen
        // went away, the account changed) publishes nothing more.
        guard !Task.isCancelled, address == loadedFor, let listing else { return }
        // The coins the registry says this wallet made are its own, not Unverified: recorded as chosen through the helper
        // the Portfolio and the Send sheet use (`WalletTokens.markOwnCoins`). A coin it was only sent stays Unverified, out
        // of Top Tokens.
        if let address { WalletTokens.markOwnCoins(ownCoins, among: tokens, owner: address) }
        unverified = KnownTokenStore.unverified(owner: address)
        if let priceError {
            error = describe(priceError)
        } else if balanceMap == nil {
            // Balances to show — read in this session, or saved when the wallet was last read, said to be — are the last
            // ones read; with none, there are no last ones to show.
            error = reads.hasFigures(.spot) ? tr("Your balances couldn't be read just now — showing the last ones read.") : tr("Your balances couldn't be read. Check your connection and try again.")
        } else if !listing.complete {
            error = tr("Some launch coins couldn't be read just now — showing the last ones read.")
        } else if let part = reads.failed.first {
            // A part not read for the wallet yet: its tab says so, with Retry, and the total waits for it.
            error = tr(Self.unreadMessage(part))
        } else {
            error = nil
            updatedAt = .now
        }
        save(env: env, address: address, epoch: epoch)
    }

    /// One of `load`'s reads, as it answers.
    private enum Answer: Sendable {
        case proven
        /// The prices, the Moments still collecting among the tokens (when the prices were read), or why they weren't.
        case prices([Address: PriceInfo]?, Error?, Set<Address>)
        case balances([Address: BigUInt]?)
        case listing(LaunchListing)
        case launchHoldings([LaunchHolding]?)
        case perps((positions: [PerpPosition], equity: Double)?)
        case moments([MomentPortfolioRow]?)
    }

    /// The prices of `tokens`, and the Moments still collecting among them as the read just made found them: "Not trading
    /// yet" in place of a price. The error when the prices couldn't be read.
    private static func readPrices(env: AppEnvironment, tokens: [Token]) async -> Answer {
        do {
            let map = try await env.prices.prices(for: tokens)
            return .prices(map, nil, await env.prices.notTradingYet(tokens))
        } catch {
            return .prices(nil, error, [])
        }
    }

    /// One read of `part` answered for the wallet (`answered`), or failed (`HomeReadState.record`); set only when it
    /// changed, so an unchanged refresh doesn't redraw what follows it. An answer is dated, for what Home saves.
    private func record(_ part: HomeReadState.Part, answered: Bool) {
        var next = reads
        next.record(part, answered: answered)
        if next != reads { reads = next }
        if answered { readAt[part] = .now }
    }

    /// Spot, once the prices and the balances have both answered: read when both were, and the rows priced again whenever
    /// the prices were (a token whose balance couldn't be read keeps its last one).
    private func publishSpot(tokens: [Token], priceMap: [Address: PriceInfo]?, balanceMap: [Address: BigUInt]?, notTrading: Set<Address>) {
        record(.spot, answered: priceMap != nil && balanceMap != nil)
        guard let priceMap else { return }
        let previous = Dictionary(rows.map { ($0.id, $0.balance) }, uniquingKeysWith: { first, _ in first })
        rows = tokens.map { token in
            // A price that isn't a positive number is none: the row shows "—", never "$0.00".
            let info = priceMap[token.address].flatMap { DyorPrice.valid($0.usd) != nil ? $0 : nil }
            return MarketRow(token: token, usd: info?.usd, change24h: info?.change24h,
                             balance: balanceMap?[token.address] ?? previous[token.address] ?? 0, info: info, notTradingYet: notTrading.contains(token.address))
        }
    }

    /// The launch coins, read over every launchpad's launches and valued at the prices: read only when the balances and
    /// the prices were, and every launchpad's launches have been.
    private func publishLaunch(_ holdings: [LaunchHolding]?, priceMap: [Address: PriceInfo]?, listing: LaunchListing) {
        record(.launch, answered: holdings != nil && priceMap != nil && listing.factories.allSatisfy(listedFactories.contains))
        if let holdings, priceMap != nil { launchHoldings = holdings } // valued at the pair's price: not without one
    }

    private func publishPerps(_ state: (positions: [PerpPosition], equity: Double)?) {
        record(.perps, answered: state != nil)
        if let state {
            positions = state.positions
            perpEquity = state.equity
        }
    }

    private func publishMoments(_ state: [MomentPortfolioRow]?) {
        record(.moments, answered: state != nil)
        if let state { momentRows = state }
    }

    // MARK: Saved

    /// What Home saves for a wallet (`SavedScreens.Screen.home`): each part it had figures of, and when each was read
    /// (`readAt`). Perps is the account's equity only: its positions are read every time.
    struct Saved: Codable, Sendable {
        var rows: [MarketRow]?
        /// The launches the Launch part was read over: a launchpad that can't be read next time keeps these.
        var launches: [Launch]
        var launchHoldings: [LaunchHolding]?
        var momentRows: [MomentPortfolioRow]?
        var perpEquity: Double?
        var readAt: [HomeReadState.Part: Date]
    }

    /// What Home saved for `address` when it was last read (`SavedScreens`), shown at once: each part read under a day ago
    /// shows its figures, said to be saved (`HomeReadState.showSaved`, `savedAt`), until its own read replaces it. Nothing
    /// of another wallet's: the file is the wallet's own, and says so.
    private func restoreSaved(env: AppEnvironment, address: Address?) {
        guard let address, let saved = env.savedScreens.load(Saved.self, .home, wallet: address)?.value else { return }
        let now = Date()
        var parts: Set<HomeReadState.Part> = []
        for (part, at) in saved.readAt where SavedScreens.isShowable(savedAt: at, now: now) {
            switch part {
            case .spot:
                guard let rows = saved.rows else { continue }
                self.rows = rows
            case .perps:
                guard let equity = saved.perpEquity else { continue }
                perpEquity = equity
            case .launch:
                guard let holdings = saved.launchHoldings else { continue }
                launchHoldings = holdings
                // The launches a launchpad that can't be read keeps (`LaunchListing.keeping`) are this session's once it
                // has read any (another wallet's launches are the same chain's). The saved ones, up to a day old, only
                // while none has been listed, and then no launchpad counts as listed until a read of it lands here
                // (`listedFactories`): a part kept from the copy stays saved, said to be, opens its coins by reference, and
                // is saved again with its first time — never counted as read in this session.
                if launches.isEmpty {
                    launches = saved.launches
                    listedFactories = []
                }
            case .moments:
                guard let rows = saved.momentRows else { continue }
                momentRows = rows
            }
            parts.insert(part)
            readAt[part] = min(at, now)
        }
        reads.showSaved(parts)
    }

    /// Saves each part Home has figures of for the wallet, with when it was read: in this session, or still the saved one,
    /// which keeps its first time (a part is never said to be newer than its read). A part with none is left out, and
    /// opens unread next time. Dropped when this device's data was erased since the load began (`epoch`).
    private func save(env: AppEnvironment, address: Address?, epoch: Int) {
        guard let address else { return }
        let times = readAt.filter { reads.hasFigures($0.key) }
        guard let newest = times.values.max() else { return }
        let saved = Saved(rows: times[.spot] == nil ? nil : rows, launches: times[.launch] == nil ? [] : launches,
                          launchHoldings: times[.launch] == nil ? nil : launchHoldings, momentRows: times[.moments] == nil ? nil : momentRows,
                          perpEquity: times[.perps] == nil ? nil : perpEquity, readAt: times)
        env.savedScreens.save(saved, .home, wallet: address, savedAt: newest, epoch: epoch)
    }

    /// The wallet's Moments stakes, or nil when they couldn't be read.
    private func loadMoments(env: AppEnvironment, address: Address?) async -> [MomentPortfolioRow]? {
        guard let address, env.config.moments.isDeployed else { return [] }
        return (try? await env.moments.portfolio(account: address, limit: 100))?.rows
    }

    /// The wallet's balances of `tokens`, or nil when they couldn't be read (never read as zero).
    private func walletBalances(env: AppEnvironment, address: Address?, tokens: [Token]) async -> [Address: BigUInt]? {
        guard let address else { return [:] }
        return try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)
    }

    /// The wallet's launch-coin balances (and coins it created), each valued at the curve price × the pair asset's
    /// USD price, in one balanceOf multicall over the recent launches; nil when the balances couldn't be read.
    private func loadLaunchHoldings(env: AppEnvironment, address: Address?, launches: [Launch], priceMap: [Address: PriceInfo]) async -> [LaunchHolding]? {
        guard let address, !launches.isEmpty else { return [] }
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        guard let balances = try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall) else { return nil }
        return launches.compactMap { launch -> LaunchHolding? in
            let balance = balances[launch.token] ?? 0
            let created = launch.deployer == address
            // A coin the wallet created shows at a zero balance only while the board lists it: a retired launchpad's
            // sell-only coin shows only while held (owner decision 2026-09-29).
            guard balance > 0 || (created && launch.listsOnBoard) else { return nil }
            let pairUSD = launch.pair.isNative ? priceMap[Monad.native]?.usd : priceMap[launch.pairToken]?.usd
            return LaunchHolding(launch: launch, balance: balance, priceUSD: DyorPrice.launch(launch, spot: priceMap[launch.token]?.usd, pairUSD: pairUSD))
        }
        .sorted { ($0.valueUSD ?? 0) > ($1.valueUSD ?? 0) }
    }

    /// What a part's holdings tab says when no read of it has answered for the wallet and the last one failed
    /// (`HomeReadState.Status.failed`); the header's warning says it too.
    static func unreadMessage(_ part: HomeReadState.Part) -> LocalizedStringResource {
        switch part {
        case .spot: return LocalizedStringResource("Your tokens couldn't be read just now.", comment: "Home, My Holdings' Spot tab before anything was read: the wallet's token balances or their prices couldn't be read. A Retry button follows")
        case .perps: return LocalizedStringResource("Your Perpl account couldn't be read just now.", comment: "Home, My Holdings' Perps tab before anything was read: the wallet's Perpl trading account (equity and positions) couldn't be read. A Retry button follows")
        case .launch: return LocalizedStringResource("Your launch coins couldn't be read just now.", comment: "Home, My Holdings' Launch tab before anything was read: the launchpad coins the wallet holds couldn't be read. A Retry button follows")
        case .moments: return LocalizedStringResource("Your Moments couldn't be read just now.", comment: "Home, My Holdings' Moments tab before anything was read: the wallet's Moments editions and coins couldn't be read. A Retry button follows")
        }
    }

    /// The Perpl account's positions and equity: none and 0 without an account, nil when a read failed (never read as 0).
    private func loadPerps(env: AppEnvironment, address: Address?) async -> (positions: [PerpPosition], equity: Double)? {
        guard let address else { return ([], 0) }
        let found: PerpAccount?
        do { found = try await env.perpl.account(address) } catch { return nil }
        guard let account = found else { return ([], 0) }
        guard let markets = try? await env.perpl.markets(), let positions = try? await env.perpl.positions(account, markets: markets) else { return nil }
        let equity = Amount.units(account.balance, decimals: Perpl.collateralDecimals) + positions.reduce(0) { $0 + $1.unrealized }
        return (positions, equity)
    }
}
