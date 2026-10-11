import BigInt
import DyorKit
import SwiftUI

// MARK: - Model

/// My Launchpad's state, for one wallet at a time. The environment keeps it (`AppEnvironment.launchpadProfile`), so the
/// sheet opened again shows the last good state read for the wallet at once and reads it again behind it; a change of
/// the wallet signed in, or a sign-out, clears it (`follow`), so no wallet ever sees another's. Every figure is unread
/// (nil, or a flag says so) until its first read for the wallet answered: never 0 or "none" for want of an answer.
@Observable
@MainActor
final class LaunchpadProfileModel {
    /// A holding's profit and loss, from the wallet's own curve fills in its history (`LaunchpadWalletHistory.pnl`).
    enum PositionPnL: Hashable {
        /// The history is still reading the fills since the coin's launch, up to the block its balance was read at
        /// (`WalletHistorySnapshot.fillsCoverage`).
        case reading
        /// The fills are all read, and the coin's value waits for the first price read.
        case pricing
        /// The history couldn't be read: the section says so, with Retry.
        case unread
        /// Nothing to show: no fill on the coin's curve (bought on Swap, or sent to the wallet), or no value for it.
        case unavailable
        case value(LaunchPositionPnL)
    }

    struct Position: Identifiable, Hashable {
        let launch: Launch
        let balance: BigUInt
        /// As Home values it (`DyorPrice.launch`): Spot's price when Spot has one, else the coin's decimal price
        /// (`Launch.pairPrice`) times its pair asset's; nil when neither is known.
        let valueUSD: Double?
        let pnl: PositionPnL
        /// Holder rewards waiting for the wallet (fee-sharing coins), in the pair asset; nil when they couldn't be read.
        let claimableRewards: BigUInt?
        var id: Address { launch.token }
        var mcapText: String { launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—" }
    }

    struct Created: Identifiable, Hashable {
        let launch: Launch
        let mcapUSD: Double?
        var id: Address { launch.token }
    }

    /// One launchpad stack's fee escrow and what the wallet can claim from it. Each stack (the live one and every
    /// retired one) keeps its own escrow, so creator fees are claimed per escrow.
    struct EscrowHolding: Hashable {
        let escrow: Address
        let retired: Bool
        let balances: EscrowBalances
        /// Read in the latest load. False: that read failed, and these are the balances last read for the same wallet
        /// (`LaunchpadEscrowRead.keeping`), shown until a read succeeds but never claimed by Claim All.
        let current: Bool
    }

    /// One row of the Activity tab: a fill, which opens its transaction, or a coin the wallet launched, which opens the
    /// coin's page.
    struct ActivityEntry: Identifiable, Hashable {
        let item: FeedItem
        let launch: Launch?
        var id: String { item.id }
    }

    /// The coins the wallet holds, valued and with their profit and loss, published right after the one read of every
    /// balance (`LaunchpadService.holdings`): nil until a read of THIS wallet's balances answered, so nothing says "none
    /// held" while they are unread; after a failed read, the last good ones read for it (`holdingsUnread` says so).
    private(set) var positions: [Position]?
    /// Every coin the wallet created, on every stack.
    private(set) var created: [Created] = []
    /// The coins it created that "Coins You Launched" shows: those the board lists (`Launch.listsOnBoard`). A retired
    /// launchpad's sell-only coin is left out (owner decision 2026-09-29), still under Holdings while held, and its
    /// creator fees are still read: every stack's escrow, in every pair asset (`LaunchpadService.escrowReads`).
    var launched: [Created] { created.filter(\.launch.listsOnBoard) }
    /// The live stack's escrow first, then the retired stacks'.
    private(set) var escrows: [EscrowHolding] = []
    /// The Activity tab: the wallet's own launchpad trades and the coins it launched, newest first, at most
    /// `activityRows` of them.
    private(set) var activity: [ActivityEntry] = []
    /// How much of the Activity tab the wallet's history holds: all of it, part of it still being read, or unread.
    private(set) var activityCoverage: HistoryCoverage = .reading
    private(set) var loading = false
    /// Said when part of the launchpad couldn't be read: the holdings, launches and fees shown may be missing some.
    private(set) var incomplete: String?
    /// The last launches read, which a launchpad that can't be read now keeps (`LaunchListing.keeping`).
    private var lastLaunches: [Launch] = []
    /// The launchpads (factories) whose launches a listing gave for the wallet on screen, as Home keeps them
    /// (`HomeModel.listedFactories`): one that can't be read now keeps its launches from then.
    private var listedFactories: Set<Address> = []
    /// Every launchpad's launches were read for the wallet on screen, now or in an earlier load (`listedFactories`): the
    /// coins it launched and the coins held are read from them, and only then is "none" said of either.
    private(set) var launchesRead = false
    /// The latest listing has returned, and some launchpad's launches were never read for the wallet (a first load with
    /// a retired launchpad, or all of them, unreachable): the Launched figure, the holdings' count and value, and the
    /// Launches tab are unread, with Retry, never "none" — that launchpad may hold the wallet's coins.
    private(set) var launchesUnread = false
    /// Some escrow couldn't be read in the latest load: the claim section says so, with Retry, and never says there is
    /// nothing to claim.
    private(set) var feesUnread = false
    /// The escrows as last kept (`LaunchpadEscrowRead.keeping`), and the wallet they were read for: an escrow whose read
    /// fails keeps its balances only for that same wallet, never another's.
    private var lastEscrowReads: [LaunchpadEscrowRead] = []
    private var escrowsFor: Address?
    /// The wallet whose coins, fees and activity are on screen: another wallet starts from nothing.
    private var shownFor: Address?
    /// Counts loads: only the newest one publishes what it read, so a slower load (for a wallet no longer shown, or a
    /// Retry overtaken by a pull to refresh) never overwrites a newer one.
    private var loads = 0

    /// Every launch coin's balance and every fee-sharing coin's holder rewards, as last read for `shownFor`
    /// (`LaunchHoldings.keeping`): nil until a read of them answered.
    private var held: LaunchHoldings?
    /// The latest read of the balances got no answer (or there was no launch to read them for), and none were kept for
    /// the wallet: the Holdings section says so, with Retry.
    private var holdingsFailed = false

    // Pair asset → USD price, and pair asset → (symbol, decimals) for escrow display.
    private var pairUSD: [Address: Double] = [:]
    private var pairMeta: [Address: (symbol: String, decimals: Int)] = [:]
    /// Spot's price of each coin held (`PriceService`), which values it as Home does; a coin Spot has none for is
    /// valued at its own price (`DyorPrice.launch`).
    private var spotUSD: [Address: Double] = [:]
    /// A price read answered for the wallet on screen; the latest one failed (the last prices read stay).
    private var pricesRead = false
    private var pricesFailed = false
    /// The wallet's history as last applied (`applyHistory`): the holdings' profit and loss and the Activity tab are
    /// built from it.
    private var history = WalletHistorySnapshot.empty
    /// Monad's pace, for estimating a coin's launch block from its launch time (`WalletHistorySnapshot.launchBlock`).
    @ObservationIgnored private var secondsPerBlock = BlockClock.fallbackSecondsPerBlock

    /// A read My Launchpad saves, while what is on screen of it is still the saved one (`restoreSaved`).
    enum SavedPart: Hashable {
        case launches, holdings, escrows, prices
    }

    /// The reads still showing what was saved for the wallet when it was last read in full (`restoreSaved`), each until its
    /// own read answers in this session; and when that was. The header says it ("Updated 3 min ago") while any is.
    private var savedParts: Set<SavedPart> = []
    private var savedTime: Date?
    /// When what is on screen still saved was read; nil once every read answered in this session.
    var savedAt: Date? { savedParts.isEmpty ? nil : savedTime }
    /// The launches on screen are still those saved (`restoreSaved`): no launchpad's were read in full yet.
    var launchesSaved: Bool { savedParts.contains(.launches) }

    /// What My Launchpad saves for a wallet once a load read all of it (`SavedScreens.Screen.myLaunchpad`): the launches it
    /// read and the launchpads they came from, the balances and holder rewards (`LaunchHoldings`), every escrow's balances
    /// and the prices. What comes from the wallet's history — fees received, profit and loss, the Activity tab — isn't:
    /// the device keeps the history itself (`HistoryModel`).
    struct Saved: Codable, Sendable {
        let launches: [Launch]
        let factories: [Address]
        let held: LaunchHoldings
        let escrows: [LaunchpadEscrowRead]
        let pairUSD: [Address: Double]
        let spotUSD: [Address: Double]
    }

    /// The Activity tab's rows at most.
    static let activityRows = 100

    /// One claimable creator-fee balance, in a single pair asset (native MON is `token == .zero`) of one escrow.
    /// Claimed on its own so the user always knows which asset they're withdrawing.
    struct ClaimableAsset: Identifiable, Hashable {
        let escrow: Address
        let retired: Bool
        let token: Address
        let symbol: String
        let amount: BigUInt
        let decimals: Int
        /// At today's price of the asset; nil while it has none (unread), never $0.00.
        let usd: Double?
        /// Read in the latest load (`EscrowHolding.current`).
        let current: Bool
        var id: String { "\(escrow.hex)-\(token.hex)" }
        var isNative: Bool { token.isZero }
        var amountText: String { "\(NumberStyle.units(amount, decimals: decimals, compact: true)) \(symbol)" }
        /// Under the row: a retired launchpad's escrow, and balances kept from an earlier read.
        var caption: String? {
            let parts = [retired ? tr("Retired launchpad") : nil, current ? nil : tr("As last read")].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// One coin's claimable holder rewards (fee-sharing coins), in that coin's pair asset.
    struct RewardClaim: Identifiable, Hashable {
        let launch: Launch
        let amount: BigUInt
        /// Read in the latest load. False: that read failed, and this is the amount last read for the same wallet,
        /// shown until a read succeeds but never claimed by Claim All.
        let current: Bool
        var id: Address { launch.token }
        var amountText: String { "\(NumberStyle.units(amount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" }
    }

    // MARK: What the sections show

    /// The first read of the wallet's balances is under way.
    var holdingsReading: Bool { held == nil && !holdingsFailed }
    /// The latest read of the balances got no answer, or none for some coin.
    var holdingsUnread: Bool { held.map { !$0.balancesUnread.isEmpty } ?? holdingsFailed }
    /// Some coin's balance was never read: what is held can't be counted or totalled in full.
    var holdingsMissing: Bool { held?.balancesMissing ?? true }
    /// The latest read of the holder rewards got no answer, or none for some coin.
    var rewardsUnread: Bool { held.map { !$0.rewardsUnread.isEmpty } ?? holdingsFailed }
    /// How many coins are held; nil while unread, while some coin's balance was never read, or while some launchpad's
    /// launches were never read (`launchesRead`).
    var holdingsCount: Int? { holdingsMissing || !launchesRead ? nil : positions?.count }
    /// The first price read for the wallet is under way: a value not known yet is a placeholder.
    var valuing: Bool { !pricesRead && !pricesFailed }

    /// The held coins' value, each as Home values it; nil while unread, while some coin's balance or some launchpad's
    /// launches were never read, or when a coin held has no value: a partial sum is never shown as the whole.
    var portfolioValueUSD: Double? {
        guard let positions, !holdingsMissing, launchesRead else { return nil }
        var total = 0.0
        for position in positions {
            guard let value = position.valueUSD else { return nil }
            total += value
        }
        return total
    }

    /// The Portfolio figure waits for a first read: of the balances, or of the prices that value them.
    var portfolioReading: Bool {
        guard let positions else { return holdingsReading }
        return valuing && positions.contains { $0.valueUSD == nil }
    }

    /// Some holding's profit and loss waits for the history to read the fills since the coin's launch.
    var pnlReading: Bool { positions?.contains { $0.pnl == .reading } ?? false }
    /// Some holding's profit and loss couldn't be read from the history.
    var pnlUnread: Bool { positions?.contains { $0.pnl == .unread } ?? false }
    /// How far the history has read what the holdings' profit and loss waits for, 0 to 1: the least read of the coins
    /// still waiting, each from its launch up to the block the balances were read at (`WalletHistorySnapshot.fillsProgress`),
    /// and never "100%" beside a figure still waited for (`WalletHistorySnapshot.readingCap`).
    var pnlProgress: Double {
        let waiting = positions?.filter { $0.pnl == .reading } ?? []
        let least = waiting.map { history.fillsProgress(launchedAt: $0.launch.launchedAt, secondsPerBlock: secondsPerBlock, through: held?.block) }.min() ?? 0
        return min(least, WalletHistorySnapshot.readingCap)
    }

    /// How far the history has read what the Activity tab waits for (`WalletHistorySnapshot.fillsProgress(through:)`): the
    /// launchpad scan's whole window, up to the block the balances were read at.
    var activityProgress: Double { min(history.fillsProgress(through: held?.block), WalletHistorySnapshot.readingCap) }

    /// Creator fees claimable, one entry per escrow and pair asset (MON first, then each token), largest first.
    var creatorClaimables: [ClaimableAsset] {
        var out: [ClaimableAsset] = []
        for holding in escrows {
            let escrow = holding.balances
            if escrow.native > 0 {
                out.append(ClaimableAsset(escrow: holding.escrow, retired: holding.retired, token: .zero, symbol: "MON", amount: escrow.native, decimals: 18,
                                          usd: DyorPrice.valid(pairUSD[Monad.native]).map { Amount.units(escrow.native, decimals: 18) * $0 }, current: holding.current))
            }
            for (token, amount) in escrow.tokens where amount > 0 {
                let meta = pairMeta[token] ?? ("", 18)
                out.append(ClaimableAsset(escrow: holding.escrow, retired: holding.retired, token: token, symbol: meta.symbol, amount: amount, decimals: meta.decimals,
                                          usd: DyorPrice.valid(pairUSD[token]).map { Amount.units(amount, decimals: meta.decimals) * $0 }, current: holding.current))
            }
        }
        return out.sorted { ($0.usd ?? 0) > ($1.usd ?? 0) }
    }

    /// Holder rewards claimable, one entry per fee-sharing coin with rewards waiting, held or not (a coin sold keeps what
    /// it earned while held), largest first; an amount kept from an earlier read is marked.
    var rewardClaimables: [RewardClaim] {
        guard let held else { return [] }
        let byToken = Dictionary(lastLaunches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        // Rewards saved when last read, not read again yet, are as last read: never claimed by Claim All.
        let saved = savedParts.contains(.holdings)
        let claims = held.rewards.compactMap { coin, amount -> RewardClaim? in
            guard amount > 0, let launch = byToken[coin] else { return nil }
            return RewardClaim(launch: launch, amount: amount, current: !saved && !held.rewardsUnread.contains(coin))
        }
        func usd(_ claim: RewardClaim) -> Double {
            Amount.units(claim.amount, decimals: claim.launch.pair.decimals) * (pairUSD[claim.launch.pair.isNative ? Monad.native : claim.launch.pairToken] ?? 0)
        }
        return claims.sorted { a, b in usd(a) == usd(b) ? a.launch.symbol < b.launch.symbol : usd(a) > usd(b) }
    }

    /// One asset's amount on a fee tile: creator fees and holder rewards in it together.
    struct FeeAmount: Identifiable, Hashable {
        let token: Address
        let symbol: String
        let decimals: Int
        let amount: BigUInt
        var id: Address { token }
        var text: String { "\(NumberStyle.units(amount, decimals: decimals)) \(symbol)" }
    }

    /// Fees the wallet received, from its history (`WalletHistorySnapshot.feeIncome`): creator fees paid straight to it
    /// or claimed, and holder rewards claimed. Nil until the history has read its window.
    private(set) var income: LaunchpadFeeIncome?
    /// The fee history couldn't be read to the head, or a holder reward's coin isn't among the launches read: Received
    /// and Total say so (with Retry) instead of showing part of it as the whole.
    private(set) var incomeUnread = false
    /// The launchpad and fee-sharing scans, the only ones the fees come from (`WalletHistoryScans.feeIncome`), are still
    /// filling in: Received and Total wait for them, and say how far they have got — never held up by another scan.
    private(set) var incomeFilling = false
    private(set) var incomeProgress = 0.0

    /// Everything My Launchpad builds from the wallet's history as the history model has it now (`HistoryModel`; no
    /// scan of its own): the fees received, each holding's profit and loss, and the Activity tab. A snapshot of another
    /// wallet is never taken in. Called whenever `HistoryModel.version` moves, and by `load`.
    func applyHistory(_ snapshot: WalletHistorySnapshot, wallet: Address?) {
        guard let shownFor else { return }
        if wallet == shownFor {
            history = snapshot
            applyIncome(snapshot)
        }
        rebuildPositions()
        rebuildActivity()
    }

    /// The fees received as the history model has them now: shown once the launchpad and fee-sharing scans have read
    /// their windows; while they fill in, waited for; when the chain couldn't be reached, or the filling stalled, said
    /// to be unread, with Retry.
    private func applyIncome(_ snapshot: WalletHistorySnapshot) {
        guard shownFor != nil else { return }
        let complete = snapshot.feeIncome.complete
        // Every fee ever received: the two scans' whole windows (All).
        let filling = snapshot.filling(since: nil, scans: WalletHistoryScans.feeIncome)
        incomeFilling = !complete && filling
        incomeProgress = snapshot.progress(since: nil, scans: WalletHistoryScans.feeIncome)
        if complete {
            income = snapshot.feeIncome
            incomeUnread = snapshot.feeIncome.rewardsClaimed.keys.contains { rewardPairs[$0] == nil }
        } else if !filling {
            incomeUnread = true
        }
    }

    /// What is waiting to be claimed, per asset: the creator-fee balances (as `creatorClaimables` lists them) and the
    /// holder rewards (in each coin's pair asset).
    var claimableFees: [FeeAmount] {
        var amounts: [Address: BigUInt] = [:]
        for asset in creatorClaimables { amounts[asset.token, default: 0] += asset.amount }
        for reward in rewardClaimables { amounts[reward.launch.pairToken, default: 0] += reward.amount }
        return feeAmounts(amounts)
    }

    /// What reached the wallet, per asset; nil while unread or incomplete. Creator fees paid straight to it or claimed,
    /// plus holder rewards claimed, each in its coin's pair asset (`rewardPairs`).
    var receivedFees: [FeeAmount]? {
        guard let received = receivedAmounts else { return nil }
        return feeAmounts(received)
    }

    /// Everything the wallet earned in fees, per asset: received plus claimable. Nil while Received is, or while an
    /// escrow or a coin's holder rewards couldn't be read (what it holds may be missing from Claimable).
    var totalFees: [FeeAmount]? {
        guard !feesUnread, !rewardsUnread, var amounts = receivedAmounts else { return nil }
        for fee in claimableFees { amounts[fee.token, default: 0] += fee.amount }
        return feeAmounts(amounts)
    }

    /// Received is being read for the first time.
    var feesLoading: Bool { income == nil && !incomeUnread }
    /// The escrows, or the holder rewards read with the balances, haven't been read for this wallet yet.
    var claimableLoading: Bool { (escrowsFor == nil && !feesUnread) || holdingsReading }
    /// Claimable as the tile shows it: nil ("—") when an escrow or a coin's rewards couldn't be read and nothing was kept
    /// from an earlier read; otherwise what the claim rows list.
    var claimableShown: [FeeAmount]? {
        let fees = claimableFees
        return (feesUnread || rewardsUnread) && fees.isEmpty ? nil : fees
    }

    /// A dollar value for `amounts` at today's prices; nil when an asset in it has no price, so a partial sum is never
    /// shown as the whole.
    func feeUSD(_ amounts: [FeeAmount]) -> Double? {
        var total = 0.0
        for fee in amounts where fee.amount > 0 {
            guard let price = DyorPrice.valid(pairUSD[fee.token]) else { return nil }
            total += Amount.units(fee.amount, decimals: fee.decimals) * price
        }
        return total
    }

    private var receivedAmounts: [Address: BigUInt]? {
        guard let income, income.complete, !incomeUnread else { return nil }
        var amounts = income.creatorFeesReceived
        for (coin, amount) in income.rewardsClaimed {
            guard let pair = rewardPairs[coin] else { return nil }
            amounts[pair, default: 0] += amount
        }
        return amounts
    }

    /// A launch coin → its pair asset, for the holder rewards claimed in it.
    private var rewardPairs: [Address: Address] = [:]

    /// `amounts` with their symbols and decimals, MON first, then the others by value; zero amounts left out.
    private func feeAmounts(_ amounts: [Address: BigUInt]) -> [FeeAmount] {
        amounts.filter { $0.value > 0 }.map { token, amount in
            if token.isZero { return FeeAmount(token: token, symbol: "MON", decimals: 18, amount: amount) }
            let symbol = pairMeta[token]?.symbol ?? Token.core(token)?.symbol ?? token.short
            let decimals = pairMeta[token]?.decimals ?? Token.core(token)?.decimals ?? 18
            return FeeAmount(token: token, symbol: symbol, decimals: decimals, amount: amount)
        }
        .sorted { a, b in
            if a.token.isZero != b.token.isZero { return a.token.isZero }
            let usdA = Amount.units(a.amount, decimals: a.decimals) * (pairUSD[a.token] ?? 0), usdB = Amount.units(b.amount, decimals: b.decimals) * (pairUSD[b.token] ?? 0)
            return usdA == usdB ? a.symbol < b.symbol : usdA > usdB
        }
    }

    var claimableCount: Int { creatorClaimables.count + rewardClaimables.count }
    var hasClaimable: Bool { claimableCount > 0 }
    /// The creator fees Claim All claims: those read in the latest load, never balances kept from an earlier one.
    var claimAllCreatorClaimables: [ClaimableAsset] { creatorClaimables.filter(\.current) }
    /// The holder rewards Claim All claims: likewise, those read in the latest load.
    var claimAllRewardClaimables: [RewardClaim] { rewardClaimables.filter(\.current) }
    var claimAllCount: Int { claimAllCreatorClaimables.count + claimAllRewardClaimables.count }

    /// Claims everything at once: every escrow read in the latest load, across every asset, plus every coin's holder
    /// rewards read in it (each on its launch's own stack).
    func claimAllPlan(env: AppEnvironment) async -> [TransactionStep] {
        var steps: [TransactionStep] = []
        for holding in escrows where holding.current && !holding.balances.isEmpty {
            steps += await env.launchpad.claimEscrowPlan(native: holding.balances.hasNative, tokens: holding.balances.claimableTokens, escrow: holding.escrow)
        }
        for reward in claimAllRewardClaimables { steps += await env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) }
        return steps
    }

    /// The escrows the claim section lists: every one read or kept, marked current when read in the latest load.
    private static func holdings(_ reads: [LaunchpadEscrowRead]) -> [EscrowHolding] {
        reads.compactMap { read in read.balances.map { EscrowHolding(escrow: read.escrow, retired: read.retired, balances: $0, current: !read.kept) } }
    }

    /// Forgets balances just claimed (`LaunchpadEscrowRead.claimed`): the reload after a claim whose escrow read fails
    /// keeps what is left, never the amount already withdrawn.
    func claimed(_ assets: [ClaimableAsset], for address: Address?) {
        guard let address, escrowsFor == address else { return }
        for asset in assets { lastEscrowReads = LaunchpadEscrowRead.claimed(asset.token, escrow: asset.escrow, in: lastEscrowReads) }
        escrows = Self.holdings(lastEscrowReads)
    }

    /// Forgets holder rewards just claimed (`LaunchHoldings.claimed`): likewise, a reload whose read fails never brings
    /// back the amount already withdrawn.
    func claimedRewards(_ coins: [Address], for address: Address?) {
        guard let address, shownFor == address, let held else { return }
        self.held = held.claimed(coins)
        rebuildPositions()
    }

    // MARK: Loading

    /// Follows the wallet signed in (RootView): another wallet, or none, clears everything kept for the last one, and a
    /// load still reading for it publishes nothing.
    func follow(_ address: Address?) {
        guard address != shownFor else { return }
        loads += 1
        reset()
    }

    /// Nothing of any wallet: every figure unread again.
    private func reset() {
        positions = nil; created = []; escrows = []; activity = []; activityCoverage = .reading; incomplete = nil; shownFor = nil
        lastLaunches = []; listedFactories = []; launchesRead = false; launchesUnread = false
        held = nil; holdingsFailed = false
        lastEscrowReads = []; escrowsFor = nil; feesUnread = false; loading = false
        income = nil; incomeUnread = false; incomeFilling = false; incomeProgress = 0; rewardPairs = [:]
        pairUSD = [:]; pairMeta = [:]; spotUSD = [:]; pricesRead = false; pricesFailed = false
        history = .empty
        savedParts = []; savedTime = nil
    }

    /// Takes in `address` before the sheet's first frame (`LaunchpadProfileView`'s `onAppear`) and at the start of every
    /// load, when it isn't the wallet shown: another wallet's coins, rewards, fees and activity go, and what was saved for
    /// this one when it was last read in full — a small file on the device, read on the spot — shows at once, said to be,
    /// until each read in `load` replaces its part (`restoreSaved`). So the sheet opens on the wallet's figures rather
    /// than on placeholders until the load's task starts.
    func showSaved(env: AppEnvironment, address: Address) {
        // Another wallet's coins, rewards, fees and activity never show while this one's load, or a failed read, is under
        // way. The same wallet's last good state stays on screen while it is read again.
        if shownFor != address {
            reset()
            shownFor = address
            // What was saved for this wallet when it was last read in full shows at once, said to be, until each read
            // in `load` replaces its part (`restoreSaved`).
            restoreSaved(env: env, address: address)
        }
    }

    func load(env: AppEnvironment, address: Address?) async {
        // The retired stacks keep serving the wallet's coins and fees while the live (v2) stack is pending.
        loads += 1
        let load = loads
        // Whether this load may still publish: it is the newest, and not cancelled (the sheet closed mid-load; reads cut
        // short that way aren't failures to show).
        func current() -> Bool { load == loads && !Task.isCancelled }
        guard let address else {
            reset()
            return
        }
        // Already done before the sheet's first frame (`showSaved`), unless the wallet changed since.
        showSaved(env: env, address: address)
        loading = true
        defer { if load == loads { loading = false } }
        // Saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`), dated when its reads began.
        let epoch = env.savedScreens.epoch
        let began = Date()

        async let pace = env.clock.secondsPerBlock()
        let listing = await env.launchpad.launchListing(limit: 100)
        secondsPerBlock = await pace
        guard current() else { return }
        let launches = listing.keeping(lastLaunches)
        lastLaunches = launches
        // Every launchpad read now: no launch on screen is a saved one.
        if listing.complete { savedParts.remove(.launches) }
        var unread = !listing.complete
        // A launchpad whose launches were never read for the wallet (every one, on a first load offline, or a retired one
        // that timed out) is no answer either: what the wallet launched and holds there is unread, with Retry, never "none".
        // One read in an earlier load keeps its launches (`keeping`), as on Home.
        listedFactories.formUnion(listing.factories.filter { listing.unread[$0] == nil })
        launchesRead = listing.factories.allSatisfy(listedFactories.contains)
        launchesUnread = !launchesRead
        // A holder reward is paid in its coin's pair asset, which the launches read name; one whose coin isn't among them
        // is unread too (`applyIncome`).
        rewardPairs = Dictionary(launches.map { ($0.token, $0.pairToken) }, uniquingKeysWith: { first, _ in first })
        rebuildCreated(for: address)
        // Their curves' fills count in the wallet's history, whether or not the Portfolio has read these launches yet.
        env.history.include(env: env, curves: Set(launches.map(\.curve)))

        // Escrow (claimable creator fees): every stack's escrow, for MON and every pair asset a launch can use, whether or
        // not the coins you created are among the launches read (`escrowReads`). A failed read says so, never zero, and
        // keeps the balances last read for this wallet (marked, and left out of Claim All). Beside it, every launch
        // coin's balance and every fee-sharing coin's holder rewards, in one read (`LaunchpadService.holdings`): the
        // holdings show as soon as it answers, never held back by a log scan.
        let createdPairs = launches.filter { $0.deployer == address }.map(\.pairToken)
        async let escrowRead = env.launchpad.escrowReads(account: address, extraPairTokens: createdPairs)
        async let holdingsRead: LaunchHoldings? = launches.isEmpty ? nil : (try? await env.launchpad.holdings(of: launches, account: address))
        let read = await holdingsRead
        guard current() else { return }
        takeHoldings(read, launches: launches)
        // The holdings on screen now, each with its profit and loss as far as the history has read.
        applyHistory(env.history.snapshot, wallet: env.history.wallet)
        // Their profit and loss, and the Activity tab, wait for the history's head to reach the block the balances were read
        // at (`WalletHistorySnapshot.fillsCoverage`), which a round that started before this read never does: a short one
        // reads it now, rather than at the next top-up.
        if let block = held?.block, !history.status(WalletHistoryScans.launchpadId).isCurrent(through: block, at: Date()) { env.history.kick(env: env) }

        let escrowReads = await escrowRead
        guard current() else { return }
        let kept = LaunchpadEscrowRead.keeping(escrowReads, previous: escrowsFor == address ? lastEscrowReads : [])
        lastEscrowReads = kept
        escrowsFor = address
        escrows = Self.holdings(kept)
        // An escrow that couldn't be read keeps its saved balances, marked as last read, and out of Claim All.
        savedParts.remove(.escrows)
        feesUnread = escrowReads.contains(where: { $0.balances == nil })
        if escrowReads.contains(where: { $0.balances == nil }) { unread = true }

        // Pair-asset prices (MON priced live; USDC/AUSD pinned to 1 by the price service), for the launches' pairs and
        // every pair asset an escrow can hold, and Spot's price of every coin held, in one read: each holding is valued as
        // Home values it. A read that fails keeps the last prices read, and the screen says part couldn't be read.
        let pairTokens = Set(launches.map(\.pairToken)).union(Token.launchpadPairAssets).union([Monad.native])
        let heldCoins = launches.filter { (held?.balances[$0.token] ?? 0) > 0 }
        let priceTokens = pairTokens.map { addr -> Token in
            if let launch = launches.first(where: { $0.pairToken == addr }) {
                return Token(address: addr, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
            }
            return Token.core(addr) ?? Token(address: addr, symbol: "", name: "", decimals: 18)
        } + heldCoins.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        let priceMap = try? await env.prices.prices(for: priceTokens)
        guard current() else { return }
        if let priceMap {
            pairUSD = Dictionary(uniqueKeysWithValues: pairTokens.map { ($0, priceMap[$0]?.usd ?? ($0.isZero ? (priceMap[Monad.native]?.usd ?? 0) : 0)) })
            spotUSD = Dictionary(heldCoins.compactMap { launch in DyorPrice.valid(priceMap[launch.token]?.usd).map { (launch.token, $0) } }, uniquingKeysWith: { first, _ in first })
            pricesRead = true
            pricesFailed = false
            savedParts.remove(.prices)
        } else {
            pricesFailed = true
            unread = true
        }
        rebuildPairMeta(launches)
        incomplete = unread ? tr("Part of your launchpad couldn't be read just now, so some coins or fees may be missing. Pull to refresh.") : nil

        // Fees received, each holding's value and profit and loss, and the Activity tab: from the wallet's history as the
        // history model has it (`HistoryModel`), which fills in behind the screen; `applyHistory` follows it.
        rebuildCreated(for: address)
        applyHistory(env.history.snapshot, wallet: env.history.wallet)

        // Saved for the next opening once every part was read: every launchpad's launches, every balance and reward, every
        // escrow and the prices. A part that couldn't be read leaves the last save as it was.
        if !unread, launchesRead, let held, held.complete {
            let saved = Saved(launches: launches, factories: Array(listedFactories), held: held, escrows: lastEscrowReads, pairUSD: pairUSD, spotUSD: spotUSD)
            env.savedScreens.save(saved, .myLaunchpad, wallet: address, savedAt: began, epoch: epoch)
        }
    }

    /// Each pair asset's symbol and decimals, from the launches that use it. Multiple launches share a pair asset (MON /
    /// USDC / AUSD), so keys repeat — dedupe instead of Dictionary(uniqueKeysWithValues:), which traps on the first
    /// duplicate key and crashed this screen. A pair asset no launch read uses takes its symbol and decimals from the
    /// curated list.
    private func rebuildPairMeta(_ launches: [Launch]) {
        pairMeta = Dictionary(launches.map { ($0.pairToken, ($0.pair.symbol, $0.pair.decimals)) }, uniquingKeysWith: { first, _ in first })
        for token in Token.launchpadPairAssets where pairMeta[token] == nil {
            if let core = Token.core(token) { pairMeta[token] = (core.symbol, core.decimals) }
        }
    }

    /// What was saved for `address` when it was last read in full (`SavedScreens`), shown at once: its launches, holdings,
    /// escrows and prices, each said to be saved (`savedAt`) until its read in `load` answers. The escrows' balances are
    /// marked as last read (`LaunchpadEscrowRead.kept`) and the holder rewards not current, so Claim All never claims
    /// them; a claim of one withdraws what the chain holds, never the saved amount. Fees received, profit and loss and the
    /// Activity tab follow from the wallet's history (`applyHistory`).
    private func restoreSaved(env: AppEnvironment, address: Address) {
        guard let saved = env.savedScreens.load(Saved.self, .myLaunchpad, wallet: address) else { return }
        let value = saved.value
        lastLaunches = value.launches
        listedFactories = Set(value.factories)
        launchesRead = true
        launchesUnread = false
        rewardPairs = Dictionary(value.launches.map { ($0.token, $0.pairToken) }, uniquingKeysWith: { first, _ in first })
        held = value.held
        holdingsFailed = false
        lastEscrowReads = value.escrows.map { LaunchpadEscrowRead(escrow: $0.escrow, factory: $0.factory, retired: $0.retired, balances: $0.balances, kept: true) }
        escrowsFor = address
        escrows = Self.holdings(lastEscrowReads)
        pairUSD = value.pairUSD
        spotUSD = value.spotUSD
        pricesRead = true
        rebuildPairMeta(value.launches)
        savedParts = [.launches, .holdings, .escrows, .prices]
        savedTime = saved.savedAt
        rebuildCreated(for: address)
        applyHistory(env.history.snapshot, wallet: env.history.wallet)
    }

    /// Takes in a read of the balances and rewards (nil: it got no answer, or there was no launch to read): what it
    /// answered as read, the rest as last read for this wallet (`LaunchHoldings.keeping`), marked unread; with none
    /// kept, the holdings stay unread (`holdingsFailed`), never "none held".
    private func takeHoldings(_ read: LaunchHoldings?, launches: [Launch]) {
        if let read {
            held = LaunchHoldings.keeping(read, previous: held)
            holdingsFailed = false
            savedParts.remove(.holdings)
        } else if let previous = held {
            let coins = Set(previous.balances.keys).union(launches.map(\.token))
            let sharing = Set(previous.rewards.keys).union(launches.filter(\.holderFeeSharing).map(\.token))
            held = LaunchHoldings.keeping(.unread(coins: Array(coins), sharing: Array(sharing)), previous: previous)
        } else {
            holdingsFailed = true
        }
    }

    /// The coins the wallet created, with their market cap at the pair's price when it is known.
    private func rebuildCreated(for address: Address) {
        created = lastLaunches.filter { $0.deployer == address }.map { launch in
            let usd = launch.marketCapInPair.flatMap { cap in DyorPrice.valid(pairUSD[launch.pairToken]).map { cap * $0 } }
            return Created(launch: launch, mcapUSD: usd)
        }
        .sorted { ($0.mcapUSD ?? 0) > ($1.mcapUSD ?? 0) }
    }

    /// The positions from the holdings, the prices and the history as they stand: every coin held, valued as Home values
    /// it, with its profit and loss once the history holds every fill since its launch, up to the block its balance was
    /// read at; nil while the holdings are unread.
    private func rebuildPositions() {
        guard let held else {
            positions = nil
            return
        }
        let byToken = Dictionary(lastLaunches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        positions = held.balances.compactMap { token, balance -> Position? in
            guard balance > 0, let launch = byToken[token] else { return nil }
            let pairUSD = launch.pair.isNative ? self.pairUSD[Monad.native] : self.pairUSD[launch.pairToken]
            // At Spot's price when Spot has one, else the coin's decimal price, never the integer `Launch.price`: unvalued
            // (and no P&L) when neither was read.
            let valueUSD = DyorPrice.launch(launch, spot: spotUSD[token], pairUSD: pairUSD).map { Amount.units(balance, decimals: 18) * $0 }
            return Position(launch: launch, balance: balance, valueUSD: valueUSD, pnl: pnl(launch, valueUSD: valueUSD, pairUSD: pairUSD, now: now), claimableRewards: held.rewards[token])
        }
        .sorted { a, b in (a.valueUSD ?? 0) == (b.valueUSD ?? 0) ? a.launch.symbol < b.launch.symbol : (a.valueUSD ?? 0) > (b.valueUSD ?? 0) }
    }

    /// A holding's profit and loss from the wallet's own fills on the coin's curve, which the history's launchpad scan
    /// holds (`snapshot.launch.fills`; no scan of its own): shown only once that scan has read every block since the coin's
    /// launch, up to the block the balance was read at (`WalletHistorySnapshot.fillsCoverage`) — a buy made since the
    /// history last read would otherwise be in the value and not in the cost; until then still reading, never a part shown
    /// as final.
    private func pnl(_ launch: Launch, valueUSD: Double?, pairUSD: Double?, now: Date) -> PositionPnL {
        switch history.fillsCoverage(curve: launch.curve, launchedAt: launch.launchedAt, secondsPerBlock: secondsPerBlock, through: held?.block, now: now) {
        case .reading: return .reading
        case .unread: return .unread
        case .complete:
            if let pnl = history.launch.pnl(curve: launch.curve, pairDecimals: launch.pair.decimals, valueUSD: valueUSD, pairUSD: pairUSD) { return .value(pnl) }
            return valueUSD == nil && valuing ? .pricing : .unavailable
        }
    }

    /// The Activity tab: the wallet's own buys and sells from its history and the coins it launched, newest first. The
    /// tab only ever showed this wallet's rows (it kept `actor == address` of four scans of every trader's trades), so it
    /// is built from the history the app already reads, with no scan of its own, and reaches back to the wallet's first
    /// launchpad trade rather than the last five days. While the launchpad scan reads on, it says so.
    private func rebuildActivity() {
        guard let shownFor else {
            activity = []
            activityCoverage = .reading
            return
        }
        let byCurve = Dictionary(lastLaunches.map { ($0.curve, $0) }, uniquingKeysWith: { first, _ in first })
        var entries = history.launch.fills.compactMap { fill -> ActivityEntry? in
            guard let launch = byCurve[fill.curve] else { return nil }
            return ActivityEntry(item: Self.feedItem(fill, launch: launch), launch: launch)
        }
        entries += lastLaunches.filter { $0.deployer == shownFor }.map { ActivityEntry(item: Self.launchedItem($0), launch: $0) }
        activity = Array(entries.sorted { $0.item.time > $1.item.time }.prefix(Self.activityRows))
        // Up to the block the balances were read at, as the holdings' profit and loss: never "No launchpad activity" from a
        // head read before the wallet's first trade.
        activityCoverage = launchesRead ? history.fillsCoverage(curves: Set(lastLaunches.map(\.curve)), through: held?.block) : launchesUnread ? .unread : .reading
    }

    /// A fill as a row: the gross quote a buyer paid, the net quote a seller received.
    private static func feedItem(_ fill: WalletCurveFill, launch: Launch) -> FeedItem {
        let symbol = launch.symbol
        let subtitle = "\(NumberStyle.units(fill.tokenAmount, decimals: 18, compact: true)) \(symbol) · \(NumberStyle.units(fill.quoteAmount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)"
        return FeedItem(id: fill.id, icon: fill.isBuy ? "arrow.down" : "arrow.up", title: fill.isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)"), subtitle: subtitle, time: fill.time, hash: fill.hash)
    }

    /// A coin the wallet launched, at its launch time; it opens the coin's page.
    private static func launchedItem(_ launch: Launch) -> FeedItem {
        FeedItem(id: "launch-\(launch.token.hex)", icon: "flame.fill", title: tr("Launched $\(launch.symbol)"), subtitle: launch.name,
                 time: Date(timeIntervalSince1970: TimeInterval(launch.launchedAt)), hash: nil)
    }
}
