import DyorKit
import Foundation
import Observation

/// The wallet's on-chain history as every screen reads it (`WalletHistorySnapshot`), filled in behind the screens.
/// On a wallet the snapshot comes from the store at once, then rounds of reading on (`WalletHistoryService.refresh`)
/// follow until every scan has read its window, and every minute or so after that for new blocks. Rounds that
/// couldn't reach the chain or read nothing new come further and further apart, and from the third in a row the
/// snapshot says what is left couldn't be read (`stalled`); a pull, a Retry or a return to the app cuts the wait
/// short (`resume`). Screens never scan on their own: they read `snapshot`, and rebuild from it when `version` moves.
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
    /// The curves whose fills count and the tokens' decimals, from the Portfolio's reference data.
    @ObservationIgnored private var curves: Set<Address> = []
    @ObservationIgnored private var decimals: [Address: Int] = [:]

    /// What one round of reading may spend, per scan: about thirty seconds at the gate's pace.
    static let roundBudget = LogsBudget(requests: 40, seconds: 30)
    /// What a pull to refresh spends: the new blocks first, within a few seconds; the rounds read on after it.
    static let pullBudget = LogsBudget(requests: 12, seconds: 8)
    /// Between rounds once the history is complete: new blocks only, a request or two a scan.
    static let topUpPause: Duration = .seconds(90)
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
        self.wallet = wallet
        snapshot = .empty
        version += 1
        guard let wallet else { return }
        run(env: env, wallet: wallet, fromStore: true)
    }

    /// One round now (a pull to refresh, a Retry), waited for: the round already reading when there is one, else a
    /// short one for the new blocks (`pullBudget`). A round that read something cuts a stall's wait short; one that
    /// read nothing leaves the rounds to their wait.
    func refresh(env: AppEnvironment) async {
        guard let wallet else { return }
        let (round, joined) = await round(env: env, wallet: wallet, budget: Self.pullBudget)
        guard self.wallet == wallet else { return }
        if !joined { took(round) }
        publish(round, wallet: wallet)
        if stalls == 0 { resume(env: env) }
    }

    /// Rounds that ended, or are waiting out a stall, go on at once (a return to the app, a pull that read
    /// something, a Retry); nothing while they read.
    func resume(env: AppEnvironment) {
        guard let wallet, filler == nil || backingOff else { return }
        filler?.cancel()
        backingOff = false
        run(env: env, wallet: wallet, fromStore: false)
    }

    /// The curves whose fills count and the tokens' decimals, once the Portfolio has read them: the snapshot is built
    /// again from the store with them.
    func setReference(env: AppEnvironment, curves: Set<Address>, decimals: [Address: Int]) {
        guard curves != self.curves || decimals != self.decimals else { return }
        self.curves = curves
        self.decimals = decimals
        guard let wallet else { return }
        Task { [weak self] in
            guard let self else { return }
            let rebuilt = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
            guard self.wallet == wallet else { return }
            publish(rebuilt, wallet: wallet)
        }
    }

    /// Publishes `snapshot` for `wallet`, said to be stalled while the last rounds read nothing (`stalls`).
    private func publish(_ snapshot: WalletHistorySnapshot, wallet: Address) {
        guard self.wallet == wallet else { return }
        self.snapshot = stalls >= Self.stalls ? snapshot.stalled() : snapshot
        version += 1
    }

    /// The rounds of reading for `wallet`: first what the store has (`fromStore`), at once, then `fill`.
    private func run(env: AppEnvironment, wallet: Address, fromStore: Bool) {
        generation += 1
        let mine = generation
        filler = Task { [weak self] in
            guard let self else { return }
            if fromStore {
                let cached = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
                guard !Task.isCancelled, self.wallet == wallet else { return }
                publish(cached, wallet: wallet)
            }
            await fill(env: env, wallet: wallet)
            if generation == mine { filler = nil }
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
    /// stalls back; one that couldn't, or got no further, counts one more.
    private func took(_ round: WalletHistorySnapshot) {
        if round.complete {
            stalls = 0
            lastProgress = 1
        } else if round.unreachable || round.progress <= lastProgress {
            stalls += 1
            lastProgress = max(lastProgress, round.progress)
        } else {
            stalls = 0
            lastProgress = round.progress
        }
    }

    /// How long the rounds wait after `round`: a second while the history fills in, `topUpPause` once complete, and
    /// after rounds that read nothing a wait that doubles with each (20 seconds up to `longestPause`).
    private func pause(after round: WalletHistorySnapshot) -> Duration {
        if stalls > 0 { return .seconds(min(10 << min(stalls, 6), Self.longestPause)) }
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
            publish(round, wallet: wallet)
            backingOff = stalls > 0
            try? await Task.sleep(for: pause)
            backingOff = false
        }
    }
}
