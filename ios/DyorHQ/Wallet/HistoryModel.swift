import DyorKit
import Foundation
import Observation

/// The wallet's on-chain history as every screen reads it (`WalletHistorySnapshot`), filled in behind the screens.
/// On a wallet the snapshot comes from the store at once, with no network (`WalletHistoryService.cached`, matched with the
/// reference kept for the wallet); what that left unread is read beside the first round (`WalletHistoryService.completed`),
/// and rounds of reading on (`WalletHistoryService.refresh`) follow until every scan has read its window, and every
/// minute or so after that for new blocks. Rounds that
/// couldn't reach the chain or read nothing new come further and further apart, and from the third in a row the
/// snapshot says what is left couldn't be read (`stalled`); a pull, a Retry (`kick`) or a return to the app (`resume`)
/// cuts the wait short. Screens never scan on their own, nor wait for a round: they read `snapshot`, and rebuild from it
/// when `version` moves; a pull awaits only the screen's own reads, and kicks the history on behind them.
@Observable
@MainActor
final class HistoryModel {
    private(set) var snapshot = WalletHistorySnapshot.empty
    private(set) var wallet: Address?
    /// Moves whenever `snapshot` changes, for models that rebuild from it.
    private(set) var version = 0
    /// A round is reading now.
    private(set) var refreshing = false
    /// The rounds of reading, nil once they ended (no wallet).
    @ObservationIgnored private var filler: Task<Void, Never>?
    /// Counts the rounds started, so rounds that end clear `filler` only when they are the current ones.
    @ObservationIgnored private var generation = 0
    /// The rounds are waiting out a round that couldn't reach the chain or read nothing: `resume` cuts it short.
    @ObservationIgnored private var backingOff = false
    /// The round reading now, joined by whoever asks for one meanwhile (the rounds, a pull), for the wallet it reads.
    @ObservationIgnored private var inFlight: (wallet: Address, round: Task<WalletHistorySnapshot, Never>)?
    /// Rounds in a row that couldn't reach the chain or read nothing new, across pulls and restarts: from `stalls`
    /// of them, what is published says the rest couldn't be read.
    @ObservationIgnored private var stalls = 0
    /// How far the history had got after the last round, to tell a round that read nothing.
    @ObservationIgnored private var lastProgress = -1.0
    /// Each scan's floor after the last round: a floor that moved down — the transfer scans reading back to the wallet's
    /// first transaction, found beside the first round — makes the window larger and the share read smaller, without the
    /// round having read nothing.
    @ObservationIgnored private var lastFloors: [String: UInt64] = [:]
    /// The curves whose fills count and the tokens' decimals, from the Portfolio's reference data, and the curves a
    /// screen added (`include`); until the Portfolio has read them, what was kept for the wallet (`restoreReference`).
    @ObservationIgnored private(set) var curves: Set<Address> = []
    @ObservationIgnored private var decimals: [Address: Int] = [:]
    /// The wallet the reference was last kept for (`setReference`): each wallet's is kept once it is read, then when it
    /// changes.
    @ObservationIgnored private var referenceKeptFor: Address?
    /// The store's count of erasures when the rounds started on the wallet (`WalletHistoryService.erasureMark`): the
    /// reference is kept only while no erase of this device's data came since, never with a mark read when it is written.
    @ObservationIgnored private var erasureMark: Int?
    /// Rounds published, so a build of the store that started before one never replaces it (`completeFacts`).
    @ObservationIgnored private var roundsPublished = 0

    /// What one round of reading may spend, per scan: about thirty seconds at the gate's pace (`HistoryCadence.roundSeconds`).
    static let roundBudget = LogsBudget(requests: 40, seconds: HistoryCadence.roundSeconds)
    /// What a pull to refresh spends between rounds (`kick`): the new blocks first, within a few seconds; the rounds read
    /// on after it.
    static let pullBudget = LogsBudget(requests: 12, seconds: 8)
    /// Between rounds once the history is complete: new blocks only, a request or two a scan (`HistoryCadence.topUpPause`,
    /// which the screens' "up to date" is measured against, `HistoryCadence.freshFor`).
    static let topUpPause: Duration = .seconds(HistoryCadence.topUpPause)
    /// Rounds in a row that couldn't reach the chain or read nothing new before the snapshot says what is left
    /// couldn't be read. The wait between such rounds doubles each time, from 20 seconds up to `longestPause`.
    static let stalls = 3
    static let longestPause = 600

    /// Whether some scan is still filling in, with the chain reachable.
    var filling: Bool { snapshot.filling }

    /// Reads the wallet's history from the store and starts filling it in; another wallet starts afresh, nil stops.
    func start(env: AppEnvironment, wallet: Address?) {
        guard wallet != self.wallet || filler == nil else { return }
        filler?.cancel()
        filler = nil
        backingOff = false
        stalls = 0
        lastProgress = -1
        lastFloors = [:]
        erasureMark = nil
        self.wallet = wallet
        snapshot = .empty
        version += 1
        guard let wallet else { return }
        run(env: env, wallet: wallet, fromStore: true)
    }

    /// A pull to refresh or a Retry, never waited for: a round reads for thirty seconds or more while the history fills
    /// in, too long to hold a pull's spinner or a screen's own reload, so the screen awaits only its own reads and
    /// follows `version` for what the round brings. Rounds waiting out a stall, or ended, go on at once (`resume`);
    /// between rounds (a second while the history fills in, `topUpPause` once it is complete), a short one for the new
    /// blocks starts (`refresh`); a round reading now is left to finish, and publishes when it does.
    func kick(env: AppEnvironment) {
        guard let wallet else { return }
        if filler == nil || backingOff {
            resume(env: env)
        } else if inFlight?.wallet != wallet {
            Task { [weak self] in await self?.refresh(env: env) }
        }
    }

    /// One round now (`kick`), waited for: the round already reading when there is one, else a short one for the new
    /// blocks (`pullBudget`). A round that read something cuts a stall's wait short; one that read nothing leaves the
    /// rounds to their wait.
    private func refresh(env: AppEnvironment) async {
        guard let wallet else { return }
        let (round, joined) = await round(env: env, wallet: wallet, budget: Self.pullBudget)
        guard self.wallet == wallet else { return }
        if !joined { took(round) }
        publish(round, wallet: wallet, env: env, round: true)
        if stalls == 0 { resume(env: env) }
    }

    /// Rounds that ended, or are waiting out a stall, go on at once (a return to the app, a pull or a Retry, a short
    /// round that read something); nothing while they read.
    func resume(env: AppEnvironment) {
        guard let wallet, filler == nil || backingOff else { return }
        filler?.cancel()
        backingOff = false
        run(env: env, wallet: wallet, fromStore: false)
    }

    /// The curves whose fills count and the tokens' decimals, once the Portfolio has read them: the snapshot is built
    /// again from the store with them, and they are kept for the wallet, for the first snapshot after the next launch
    /// (`restoreReference`). A curve is a launch's for good, so the curves are added to, never replaced: a listing that
    /// couldn't read a launchpad never drops the curves another screen added (`include`). What is kept on the device is the
    /// same union, and only while no erase of this device's data came since the rounds started (`erasureMark`).
    func setReference(env: AppEnvironment, curves: Set<Address>, decimals: [Address: Int]) {
        let changed = !curves.isSubset(of: self.curves) || decimals != self.decimals
        self.curves.formUnion(curves)
        self.decimals = decimals
        if let wallet, let erasureMark, changed || referenceKeptFor != wallet {
            referenceKeptFor = wallet
            let reference = WalletHistoryReference(curves: self.curves, decimals: decimals)
            Task { await env.walletHistory.keep(reference: reference, wallet: wallet, since: erasureMark) }
        }
        guard changed else { return }
        rebuild(env: env)
    }

    /// The reference kept for `wallet` (`setReference`), added to what this launch has: the launches' curves and the
    /// tokens' decimals the Portfolio read last time, so the first snapshot counts launch fills and weighs swap legs right
    /// before it has read them again. A curve is a launch's for good and a token's decimals never change, so what is kept
    /// only adds; what this launch read wins.
    private func restoreReference(env: AppEnvironment, wallet: Address) async {
        guard let kept = await env.walletHistory.reference(wallet: wallet), self.wallet == wallet else { return }
        curves.formUnion(kept.curves)
        decimals.merge(kept.decimals) { now, _ in now }
    }

    /// Adds `more` to the curves whose fills count, for a screen that reads a coin's fills (My Launchpad) before the
    /// Portfolio's launches are read, or with a launch they lack: the snapshot is built again from the store, with no
    /// scan, when any is new. Never drops a curve.
    func include(env: AppEnvironment, curves more: Set<Address>) {
        guard !more.isSubset(of: curves) else { return }
        curves.formUnion(more)
        rebuild(env: env)
    }

    /// Builds the snapshot again from the store with the current reference, and publishes it.
    private func rebuild(env: AppEnvironment) {
        guard let wallet else { return }
        let (curves, decimals) = (curves, decimals)
        Task { [weak self] in
            guard let self else { return }
            let rebuilt = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
            guard self.wallet == wallet else { return }
            publish(rebuilt, wallet: wallet, env: env)
        }
    }

    /// Publishes `snapshot` for `wallet`, said to be stalled while the last rounds read nothing (`stalls`). A snapshot
    /// built with curves since added to (a round that started before `include` or `setReference`) is built again from
    /// the store at once, so a coin's fills don't wait a round to count.
    private func publish(_ snapshot: WalletHistorySnapshot, wallet: Address, env: AppEnvironment, round: Bool = false) {
        guard self.wallet == wallet else { return }
        if round { roundsPublished += 1 }
        self.snapshot = stalls >= Self.stalls ? snapshot.stalled() : snapshot
        version += 1
        if snapshot.curves != curves { rebuild(env: env) }
    }

    /// The rounds of reading for `wallet`: first what the store has (`fromStore`), at once and with no network, matched
    /// with the reference kept for the wallet; then what that left unread (`completeFacts`) beside `fill`.
    private func run(env: AppEnvironment, wallet: Address, fromStore: Bool) {
        generation += 1
        let mine = generation
        filler = Task { [weak self] in
            guard let self else { return }
            if fromStore {
                let mark = await env.walletHistory.erasureMark
                guard !Task.isCancelled, self.wallet == wallet else { return }
                erasureMark = mark
                await restoreReference(env: env, wallet: wallet)
                guard !Task.isCancelled, self.wallet == wallet else { return }
                let cached = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
                guard !Task.isCancelled, self.wallet == wallet else { return }
                publish(cached, wallet: wallet, env: env)
                if cached.swapFactsUnread { completeFacts(env: env, wallet: wallet) }
            }
            await fill(env: env, wallet: wallet)
            if generation == mine { filler = nil }
        }
    }

    /// The instant read left transactions' facts unread (`WalletHistorySnapshot.swapFactsUnread`): they are read now,
    /// beside the first round rather than after it — a round reads for thirty seconds while the history fills in — and the
    /// snapshot is built again from the store with them (`WalletHistoryService.completed`) and published, unless a round
    /// published meanwhile: it read them too, and more.
    private func completeFacts(env: AppEnvironment, wallet: Address) {
        let rounds = roundsPublished
        let (curves, decimals) = (curves, decimals)
        Task { [weak self] in
            let completed = await env.walletHistory.completed(wallet: wallet, curves: curves, decimals: decimals)
            guard let self, self.wallet == wallet, roundsPublished == rounds else { return }
            publish(completed, wallet: wallet, env: env)
        }
    }

    /// One round of reading for `wallet`: the one under way (`joined`), else a new one within `budget`.
    private func round(env: AppEnvironment, wallet: Address, budget: LogsBudget) async -> (snapshot: WalletHistorySnapshot, joined: Bool) {
        if let inFlight, inFlight.wallet == wallet { return (await inFlight.round.value, true) }
        let round = Task { await env.walletHistory.refresh(wallet: wallet, budget: budget, curves: curves, decimals: decimals) }
        inFlight = (wallet, round)
        refreshing = true
        let snapshot = await round.value
        if inFlight?.round == round {
            inFlight = nil
            refreshing = false
        }
        return (snapshot, false)
    }

    /// Takes in what a round read, by whoever started it: a round that reached the chain and got further sets the
    /// stalls back; one that couldn't, or got no further, counts one more — but for one whose window grew (a floor moved
    /// down, `lastFloors`): its share read is of more blocks than the last round's. A round whose scans are complete
    /// counts one more when the facts of the transactions the swaps leave out couldn't be read either
    /// (`WalletHistorySnapshot.swapFactsFailed`, the archive endpoints refusing): the screens built from the swaps would
    /// otherwise wait at 99% for as long as they refuse, never saying so.
    private func took(_ round: WalletHistorySnapshot) {
        let floors = round.status.compactMapValues(\.floor)
        let widened = floors.contains { id, floor in lastFloors[id].map { floor < $0 } ?? false }
        lastFloors = floors
        if round.complete, !round.swapFactsFailed {
            stalls = 0
            lastProgress = 1
        } else if round.complete || round.unreachable || (!widened && round.progress <= lastProgress) {
            stalls += 1
            lastProgress = max(lastProgress, round.progress)
        } else {
            stalls = 0
            lastProgress = round.progress
        }
    }

    /// How long the rounds wait after `round`: a second while the history fills in — or while transactions' facts are
    /// still left out and the last build read some (`SwapHistoryService.factsPerBuild` a build: a wallet's first launch
    /// with this build reads hundreds, and each waiting a top-up would hold the screens at 99% for minutes) — `topUpPause`
    /// once complete, and after rounds that read nothing a wait that doubles with each (20 seconds up to `longestPause`),
    /// a failing archive included.
    private func pause(after round: WalletHistorySnapshot) -> Duration {
        if stalls > 0 { return .seconds(min(10 << min(stalls, 6), Self.longestPause)) }
        if round.complete, !round.unreadTransactionBlocks.isEmpty, (round.swapFactsRead ?? 0) > 0 { return .seconds(1) }
        return round.complete ? Self.topUpPause : .seconds(1)
    }

    /// Rounds of reading on, until the history is complete, then a top-up every `topUpPause`. A round that couldn't
    /// reach the chain or read nothing new (the endpoints refusing, or resting after throttling) is followed by a
    /// longer wait each time, and from the third in a row (`stalls`) the snapshot says what is left couldn't be
    /// read; a round that reads again sets both back.
    private func fill(env: AppEnvironment, wallet: Address) async {
        while !Task.isCancelled, self.wallet == wallet {
            let (round, joined) = await round(env: env, wallet: wallet, budget: Self.roundBudget)
            guard !Task.isCancelled, self.wallet == wallet else { return }
            if !joined { took(round) }
            let pause = pause(after: round)
            publish(round, wallet: wallet, env: env, round: true)
            backingOff = stalls > 0
            try? await Task.sleep(for: pause)
            backingOff = false
        }
    }
}
