import BigInt
import Foundation

/// Every DyorHQ coin (`DyorCoin`), read from the factories themselves: each launchpad stack — the live one and every
/// retired one, 0x6B1C included, which is still open on chain — and each Moments cohort, c1–c4 (cohort 3 is still open on
/// chain too). One source for "is this a DyorHQ coin, and what is its picture" for the icons, the badges, the own-coin
/// rule and prices; it reveals nothing about the wallet, since it reads every coin, not the ones held.
///
/// - **Enumeration** (`refresh`), the primary path: each factory's `launchCount()` / `momentCount()`, then the launches
///   (`getLaunches`) or Moments (`getMoment`) not read before, then each new coin's record in its factory, name, symbol
///   and picture — three Multicall3 reads in all today (7 launches, 6 Moments). How far each factory's list has been
///   read is kept (`DyorCoinStore`), so a later refresh reads only the counts and what is new.
/// - **Point proof** (`prove`), for a held address not seen yet: every launchpad's `getLaunchedToken(coin)` and every
///   cohort's `momentIdByCoin(coin)`; a launch counts when a record exists and names this coin, a Moment when
///   `getMoment(id).coin` is this coin. An answer that is missing makes it unknown — shown as today — never "not DyorHQ";
///   "not DyorHQ" is kept for this session only, and only after every factory answered.
/// - **Ingest** of launches and Moments other screens already read from a known factory (Home, Portfolio, Send, a launch
///   or publish that just settled), at no cost.
///
/// Membership never comes from anything a token says about itself: no call ever goes to a candidate token until a
/// factory has named it. A coin's name, symbol and picture are its creator's strings, which anyone launching for 5 MON
/// can make too costly to read: each coin's calls are read as one group, a group that fails is read again on its own, so
/// one such coin never keeps the others from being read, and a coin whose own calls fail however they are read is
/// passed over, unlabelled, rather than read again at every refresh. Reads go one after another on the client given (the
/// app's failover RPC), each a single Multicall3 `eth_call`. When to refresh is the app's (at start, every 5 minutes in
/// the foreground, after a launch or publish settles); no view triggers a read.
public actor DyorCoinRegistry {
    /// What the registry can say of an address.
    public enum Membership: Hashable, Sendable {
        /// A DyorHQ coin, as its factory recorded it.
        case dyor(DyorCoin)
        /// Not one: MON, a curated token, or an address every factory answered for without naming it (this session).
        case notDyor
        /// Not known yet: not read, a read that failed, or a DyorHQ coin whose own calls can't be read. Shown as today.
        case unknown
    }

    /// The launchpad stacks read, live first (`launchpads(live:)`).
    public nonisolated let launchpads: [LaunchpadAddresses]
    /// The Moments cohorts read, live first (`cohorts(live:)`).
    public nonisolated let cohorts: [MomentsAddresses]
    /// The live launchpad's and cohort's factories (zero while one isn't deployed): every other one is retired.
    nonisolated let liveLaunchpad: Address
    nonisolated let liveCohort: Address
    let multicall: Multicall
    private let store: DyorCoinStore?

    private var coins: [Address: DyorCoin]
    /// How many of each factory's launches or Moments have been read, in the order the factory lists them.
    private(set) var checkpoints: [Address: Int]
    /// Addresses every factory answered for without naming them, this session.
    private var notDyor: Set<Address> = []
    /// Coins a factory names whose own calls fail however they are read (their strings cost more gas than a read has),
    /// this session: unknown, and not asked again.
    private var unreadable: Set<Address> = []
    private var running: Task<Bool, Never>?
    private var lastCompleteRefresh: Date?
    /// Bumped by `erase`, so a read that started before it never writes its results back.
    private var epoch = 0
    private var subscribers: [UUID: AsyncStream<[Address: DyorCoin]>.Continuation] = [:]

    /// Sub-calls in one Multicall3 read: 200 launch records measured at about 3.2M gas on mainnet (2026-09-30), well inside
    /// a public RPC's `eth_call` cap.
    static let maxCallsPerRead = 200
    /// New launches or Moments read per factory in one refresh; the rest follow in the next.
    static let maxNewPerRefresh = 500
    /// Launch addresses asked for in one `getLaunches` call.
    static let launchPage = 250
    /// Coins read again on their own in one pass, at most (`readGroups`): what is left past them is read by a later one.
    static let maxRereads = 64

    /// Reads the live launchpad `live` and cohort `liveMoments` (zero while not deployed) plus every retired one, from
    /// what `store` kept, if anything.
    public init(rpc: RPCClient, live: LaunchpadAddresses = .monadMainnet, liveMoments: MomentsAddresses = .monadMainnet, store: DyorCoinStore? = nil) {
        let launchpads = Self.launchpads(live: live)
        let cohorts = Self.cohorts(live: liveMoments)
        let liveLaunchpad = live.isDeployed ? live.factory : .zero
        let liveCohort = liveMoments.isDeployed ? liveMoments.factory : .zero
        self.launchpads = launchpads
        self.cohorts = cohorts
        self.liveLaunchpad = liveLaunchpad
        self.liveCohort = liveCohort
        multicall = Multicall(rpc: rpc)
        self.store = store
        let kept = store?.load().map { Self.restored($0, launchpads: launchpads, cohorts: cohorts, liveLaunchpad: liveLaunchpad, liveCohort: liveCohort) }
        coins = kept?.coins ?? [:]
        checkpoints = kept?.checkpoints ?? [:]
    }

    /// The live launchpad once it is deployed, then every retired one (`LaunchpadAddresses.retiredStacks`).
    public static func launchpads(live: LaunchpadAddresses) -> [LaunchpadAddresses] {
        (live.isDeployed ? [live] : []) + LaunchpadAddresses.retiredStacks.filter { $0.factory != live.factory }
    }

    /// The live cohort once it is deployed, then every retired one (`MomentsAddresses.retiredMainnet`).
    public static func cohorts(live: MomentsAddresses) -> [MomentsAddresses] {
        (live.isDeployed ? [live] : []) + MomentsAddresses.retiredMainnet.filter { $0.factory != live.factory }
    }

    // MARK: Lookups

    /// The DyorHQ coin at `address`, if known.
    public func coin(_ address: Address) -> DyorCoin? { coins[address] }

    /// Every DyorHQ coin known, by address.
    public var all: [Address: DyorCoin] { coins }

    /// The coins `owner` made: launches its factory records it as deployer of, Moments it created.
    public func coins(createdBy owner: Address) -> [DyorCoin] {
        coins.values.filter { $0.creator == owner }.sorted { $0.address.hex < $1.address.hex }
    }

    /// What is known of `address` now, without a read.
    public func membership(_ address: Address) -> Membership {
        if address.isZero || Token.core(address) != nil { return .notDyor }
        if let coin = coins[address] { return .dyor(coin) }
        return notDyor.contains(address) ? .notDyor : .unknown
    }

    /// The whole list now, then again after every change, for a screen model to follow. The stream ends when its task is
    /// cancelled.
    public func updates() -> AsyncStream<[Address: DyorCoin]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Address: DyorCoin].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        continuation.yield(coins)
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: Enumeration

    /// Reads what every factory recorded since the last refresh (at most `maxNewPerRefresh` per factory). True when the
    /// registry then holds every coin the factories had recorded; false when a read failed or more is left for next time
    /// (what was read is kept either way). A refresh already running is joined, not repeated.
    @discardableResult
    public func refresh() async -> Bool {
        if let running { return await running.value }
        let task = Task { await self.enumerate() }
        running = task
        let complete = await task.value
        running = nil
        if complete { lastCompleteRefresh = Date() }
        return complete
    }

    /// `refresh`, unless a complete one finished less than `maxAge` seconds before `now`.
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 300, now: Date = Date()) async -> Bool {
        if let lastCompleteRefresh, now.timeIntervalSince(lastCompleteRefresh) < maxAge { return true }
        return await refresh()
    }

    /// A launchpad stack or a Moments cohort, as the enumeration reads it.
    private enum Source {
        case launchpad(LaunchpadAddresses)
        case cohort(MomentsAddresses)

        var factory: Address {
            switch self {
            case .launchpad(let stack): return stack.factory
            case .cohort(let cohort): return cohort.factory
            }
        }

        var countCall: ContractCall {
            switch self {
            case .launchpad(let stack): return LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.launchCount, returns: "uint256")
            case .cohort(let cohort): return MomentsABI.call(cohort.factory, MomentsABI.Factory.momentCount, returns: "uint256")
            }
        }
    }

    /// The new coins of one factory, in its list order, and how far its list had been read before.
    private struct Job {
        let source: Source
        let from: Int
        let to: Int
    }

    private func enumerate() async -> Bool {
        let epoch = self.epoch
        let sources = launchpads.map(Source.launchpad) + cohorts.map(Source.cohort)
        // 1. How many each factory has recorded. A count below what was read before is another chain's (a fork restarted
        //    under the same file) or a node behind the others: that factory's list is read again from the start.
        let counts = await read(sources.map(\.countCall))
        var complete = true
        var jobs: [Job] = []
        var reached = checkpoints
        for (source, result) in zip(sources, counts) {
            guard case .success(let values) = result, let value = values.first else { complete = false; continue }
            let count = LaunchpadABI.int(value)
            let stored = checkpoints[source.factory] ?? 0
            let done = stored > count ? 0 : stored
            reached[source.factory] = done
            guard count > done else { continue }
            let to = min(count, done + Self.maxNewPerRefresh)
            if to < count { complete = false }
            jobs.append(Job(source: source, from: done, to: to))
        }
        // 2. Which coins: the new launches' addresses, a page at a time, and the new Moments. These answers are the
        //    factories' own, of a fixed size.
        var listCalls: [ContractCall] = []
        for job in jobs {
            switch job.source {
            case .launchpad(let stack):
                for offset in stride(from: job.from, to: job.to, by: Self.launchPage) {
                    let size = min(Self.launchPage, job.to - offset)
                    listCalls.append(LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.getLaunches, [.uint(BigUInt(offset)), .uint(BigUInt(size))], returns: "address[]"))
                }
            case .cohort(let cohort):
                for id in (job.from + 1)...job.to { listCalls.append(MomentsABI.call(cohort.factory, MomentsABI.Factory.getMoment, [.uint(BigUInt(id))], returns: MomentsABI.momentTuple)) }
            }
        }
        let lists = await read(listCalls)
        var cursor = 0
        func next() -> Result<[ABIValue], Error> {
            defer { cursor += 1 }
            return lists[cursor]
        }
        // Each job's items in list order, cut at the first page or Moment that couldn't be read.
        var items: [[Item]] = []
        for job in jobs {
            var list: [Item] = []
            var whole = true
            switch job.source {
            case .launchpad(let stack):
                for offset in stride(from: job.from, to: job.to, by: Self.launchPage) {
                    let size = min(Self.launchPage, job.to - offset)
                    let page = next()
                    guard whole, case .success(let values) = page, let tokens = values.first?.elements.map(\.address) else { whole = false; continue }
                    list += tokens.prefix(size).map { Item.launch($0, stack) }
                    if tokens.count < size { whole = false }
                }
            case .cohort(let cohort):
                for id in (job.from + 1)...job.to {
                    let answer = next()
                    guard whole, case .success(let values) = answer, let tuple = values.first else { whole = false; continue }
                    list.append(.moment(MomentsABI.moment(id: BigUInt(id), tuple, factory: cohort.factory), cohort))
                }
            }
            items.append(list)
        }
        // 3. Each new coin's record in its factory, name, symbol and picture: one group of calls per coin.
        let outcomes = await readGroups(items.flatMap { $0.map(\.reads) })
        // 4. Admit them in list order (`verdict`). A factory's checkpoint moves past each coin admitted, and past one whose
        //    own calls fail however they are read (it is left unlabelled); it stops at the first coin whose read got no
        //    answer, or an answer these contracts never give, or whose record doesn't agree with the list — a node behind
        //    the chain answers a coin it hasn't reached that way — so that one is read again next time.
        var found: [DyorCoin] = []
        var skipped: [Address] = []
        var at = 0
        for (job, list) in zip(jobs, items) {
            var passed = job.from
            var reading = true
            for item in list {
                let outcome = outcomes[at]
                at += 1
                guard reading else { continue }
                switch Self.verdict(outcome, decide: { item.coin($0, retired: item.factory != (item.isLaunch ? self.liveLaunchpad : self.liveCohort)) }) {
                case .admit(let coin): found.append(coin); passed += 1
                case .unreadable: skipped.append(item.address); passed += 1
                case .later: reading = false
                }
            }
            reached[job.source.factory] = passed
            if passed < job.to { complete = false }
        }
        guard epoch == self.epoch else { return false }
        unreadable.formUnion(skipped)
        let checkpointsMoved = reached != checkpoints
        checkpoints = reached
        commit(found, persistAnyway: checkpointsMoved)
        return complete
    }

    /// One coin a factory listed, with the factory's stack or cohort.
    private enum Item {
        case launch(Address, LaunchpadAddresses)
        case moment(Moment, MomentsAddresses)

        var address: Address {
            switch self {
            case .launch(let token, _): return token
            case .moment(let moment, _): return moment.coin
            }
        }

        var factory: Address {
            switch self {
            case .launch(_, let stack): return stack.factory
            case .moment(_, let cohort): return cohort.factory
            }
        }

        var isLaunch: Bool { if case .launch = self { return true } else { return false } }

        var reads: [ContractCall] {
            switch self {
            case .launch(let token, let stack): return DyorCoinRegistry.launchReads(token, stack: stack)
            case .moment(let moment, let cohort): return DyorCoinRegistry.momentReads(moment, cohort: cohort)
            }
        }

        func coin(_ answers: [Result<[ABIValue], Error>], retired: Bool) -> DyorCoin? {
            switch self {
            case .launch(let token, let stack): return DyorCoinRegistry.launchCoin(token, stack: stack, retired: retired, answers: answers)
            case .moment(let moment, let cohort): return DyorCoinRegistry.momentCoin(moment, cohort: cohort, retired: retired, answers: answers)
            }
        }
    }

    /// `stack`'s record of `token` in its own layout (first, so nothing the token's own calls cost can starve it), then the
    /// token's `name`, `symbol` and `getTokenInfo`.
    static func launchReads(_ token: Address, stack: LaunchpadAddresses) -> [ContractCall] {
        typealias T = LaunchpadABI.Token
        return [
            LaunchpadABI.call(stack.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(token)], returns: LaunchpadABI.launchedTokenReturns(legacy: stack.generation.legacyRecord)),
            LaunchpadABI.call(token, T.name, returns: "string"),
            LaunchpadABI.call(token, T.symbol, returns: "string"),
            LaunchpadABI.call(token, T.getTokenInfo, returns: "address,string,string,\(LaunchpadABI.socialsTuple)"),
        ]
    }

    /// `cohort`'s `momentIdByCoin` of `moment`'s coin (first), then the coin's `name` and `symbol` and its NFT's
    /// `provenance`.
    static func momentReads(_ moment: Moment, cohort: MomentsAddresses) -> [ContractCall] {
        [
            MomentsABI.call(cohort.factory, MomentsABI.Factory.momentIdByCoin, [.address(moment.coin)], returns: "uint256"),
            MomentsABI.call(moment.coin, MomentsABI.Coin.name, returns: "string"),
            MomentsABI.call(moment.coin, MomentsABI.Coin.symbol, returns: "string"),
            MomentsABI.call(moment.nft, MomentsABI.NFT.provenance, returns: MomentsABI.provenanceTuple),
        ]
    }

    /// Pure: the coin `token` is on `stack`, from `launchReads`' answers — only when the stack's record of it exists, names
    /// this very token and a curve. Nil otherwise, or when an answer is missing.
    static func launchCoin(_ token: Address, stack: LaunchpadAddresses, retired: Bool, answers: [Result<[ABIValue], Error>]) -> DyorCoin? {
        guard answers.count == 4, case .success(let record) = answers[0], let tuple = record.first, case .success(let name) = answers[1],
              case .success(let symbol) = answers[2], case .success(let info) = answers[3], info.count == 4 else { return nil }
        let launch = LaunchpadABI.LaunchRecord(tuple, legacy: stack.generation.legacyRecord)
        guard launch.exists, launch.token == token, !launch.curve.isZero, !token.isZero else { return nil }
        return DyorCoin(address: token, origin: .launch(factory: stack.factory, generation: stack.generation, retired: retired),
                        symbol: symbol.first?.string ?? "", name: name.first?.string ?? "", creator: launch.deployer,
                        logo: LaunchpadABI.TokenInfo(info).logo, pair: launch.pairToken)
    }

    /// Pure: `moment`'s coin on `cohort`, from `momentReads`' answers — only when the cohort maps the coin back to this
    /// Moment's id. Nil otherwise, or when an answer is missing.
    static func momentCoin(_ moment: Moment, cohort: MomentsAddresses, retired: Bool, answers: [Result<[ABIValue], Error>]) -> DyorCoin? {
        guard answers.count == 4, case .success(let idValues) = answers[0], let id = idValues.first?.uint, case .success(let name) = answers[1],
              case .success(let symbol) = answers[2], case .success(let provenanceValues) = answers[3], let tuple = provenanceValues.first,
              moment.id > 0, id == moment.id, !moment.coin.isZero, moment.factory == cohort.factory else { return nil }
        let provenance = MomentsABI.provenance(tuple)
        return DyorCoin(address: moment.coin, origin: .moment(factory: cohort.factory, id: moment.id, retired: retired),
                        symbol: symbol.first?.string ?? "", name: name.first?.string ?? "", creator: moment.creator,
                        logo: provenance.mediaURI, mediaHash: provenance.mediaHash, mediaIsVideo: !provenance.animationURI.isEmpty, pair: cohort.usdc)
    }

    /// What one coin's read comes to.
    enum Verdict: Equatable {
        /// A DyorHQ coin: every call answered, and its factory's record names it.
        case admit(DyorCoin)
        /// Its own calls fail however they are read (they revert or run out of gas, read on their own): passed over,
        /// unlabelled.
        case unreadable
        /// Read it again later: no answer, an answer that isn't what these contracts return (a node that hasn't reached
        /// the coin answers as an account with no code), or a record that doesn't name it.
        case later
    }

    /// Pure: what `outcome` (one coin's `readGroups` answer) comes to, `decide` making the coin from a full answer.
    static func verdict(_ outcome: GroupRead, decide: ([Result<[ABIValue], Error>]) -> DyorCoin?) -> Verdict {
        guard case .answered(let answers) = outcome else { return .later }
        if answers.allSatisfy(\.succeeded) { return decide(answers).map(Verdict.admit) ?? .later }
        return answers.contains(where: \.isCallFailure) ? .unreadable : .later
    }

    // MARK: Point proof

    /// What each of `addresses` is, reading the factories for those not known yet (MON and the curated tokens are never
    /// asked): see `Membership`. A coin proven here is kept like one enumerated.
    public func prove(_ addresses: [Address]) async -> [Address: Membership] {
        var out: [Address: Membership] = [:]
        var candidates: [Address] = []
        for address in addresses where out[address] == nil {
            let known = membership(address)
            out[address] = known
            if known == .unknown, !unreadable.contains(address) { candidates.append(address) }
        }
        guard !candidates.isEmpty, !launchpads.isEmpty || !cohorts.isEmpty else { return out }
        let epoch = self.epoch
        // 1. Every launchpad's record of each candidate, in its own layout, and every cohort's Moment id for it: the
        //    factories' own answers, of a fixed size.
        let perCandidate = launchpads.count + cohorts.count
        let records = await read(candidates.flatMap { candidate in
            launchpads.map { LaunchpadABI.call($0.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(candidate)], returns: LaunchpadABI.launchedTokenReturns(legacy: $0.generation.legacyRecord)) }
                + cohorts.map { MomentsABI.call($0.factory, MomentsABI.Factory.momentIdByCoin, [.address(candidate)], returns: "uint256") }
        })
        let claims = candidates.enumerated().map { i, candidate in
            Self.claims(candidate, launchpads: launchpads, cohorts: cohorts, answers: Array(records[i * perCandidate..<(i + 1) * perCandidate]))
        }
        // 2. In one pass: each launch a factory named, its name, symbol and picture; each Moment id a cohort gave, the
        //    Moment, to see whether it is this coin's. One group a coin.
        let launchClaims = claims.compactMap { claim in claim.launch.map { (claim: claim, stack: $0) } }
        let momentClaims = claims.filter { $0.launch == nil && !$0.moments.isEmpty }
        let second = await readGroups(launchClaims.map { Array(Self.launchReads($0.claim.address, stack: $0.stack).dropFirst()) }
            + momentClaims.map { claim in claim.moments.map { MomentsABI.call($0.0.factory, MomentsABI.Factory.getMoment, [.uint($0.1)], returns: MomentsABI.momentTuple) } })
        let launchReads = second.prefix(launchClaims.count)
        var confirmed: [(cohort: MomentsAddresses, moment: Moment)] = []
        var settled = Set(claims.filter { $0.launch == nil && $0.moments.isEmpty }.map(\.address))
        for (claim, outcome) in zip(momentClaims, second.dropFirst(launchClaims.count)) {
            guard case .answered(let answers) = outcome else { continue }
            var answered = true
            var match: (MomentsAddresses, Moment)?
            for ((cohort, id), answer) in zip(claim.moments, answers) {
                guard case .success(let values) = answer, let tuple = values.first else { answered = false; continue }
                let moment = MomentsABI.moment(id: id, tuple, factory: cohort.factory)
                if moment.coin == claim.address, match == nil { match = (cohort, moment) }
            }
            if let match { confirmed.append(match) } else if answered { settled.insert(claim.address) }
        }
        // 3. Each Moment that is this coin's: its coin's name and symbol and its NFT's provenance, one group a coin.
        let momentReads = await readGroups(confirmed.map { Array(Self.momentReads($0.moment, cohort: $0.cohort).dropFirst()) })
        // Decide. A coin is DyorHQ's only on its factory's word and every answer read; "not DyorHQ" only when every
        // factory answered and none named it.
        var found: [DyorCoin] = []
        var skipped: [Address] = []
        for ((claim, stack), outcome) in zip(launchClaims, launchReads) {
            guard let record = claim.record else { continue }
            let full = outcome.prepending(.success([record]))
            switch Self.verdict(full, decide: { Self.launchCoin(claim.address, stack: stack, retired: stack.factory != self.liveLaunchpad, answers: $0) }) {
            case .admit(let coin): found.append(coin)
            case .unreadable: skipped.append(claim.address)
            case .later: break
            }
        }
        for (entry, outcome) in zip(confirmed, momentReads) {
            let full = outcome.prepending(.success([.uint(entry.moment.id)]))
            switch Self.verdict(full, decide: { Self.momentCoin(entry.moment, cohort: entry.cohort, retired: entry.cohort.factory != self.liveCohort, answers: $0) }) {
            case .admit(let coin): found.append(coin)
            case .unreadable: skipped.append(entry.moment.coin)
            case .later: break
            }
        }
        let negatives = claims.filter { $0.launch == nil && $0.complete && settled.contains($0.address) }.map(\.address)
        guard epoch == self.epoch else { return out }
        notDyor.formUnion(negatives)
        unreadable.formUnion(skipped)
        commit(found)
        for address in candidates { out[address] = membership(address) }
        return out
    }

    /// What the factories' first answers say of one candidate.
    struct Claims {
        let address: Address
        /// The first launchpad (live first) whose record of it exists and names it and a curve, with that record.
        let launch: LaunchpadAddresses?
        let record: ABIValue?
        /// Each cohort that maps it to a Moment id, with the id.
        let moments: [(MomentsAddresses, BigUInt)]
        /// Every factory answered.
        let complete: Bool
    }

    /// Pure: `answers` holds each launchpad's `getLaunchedToken(candidate)` then each cohort's `momentIdByCoin(candidate)`.
    static func claims(_ candidate: Address, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses], answers: [Result<[ABIValue], Error>]) -> Claims {
        var launch: (LaunchpadAddresses, ABIValue)?
        var complete = answers.count == launchpads.count + cohorts.count
        for (stack, answer) in zip(launchpads, answers) {
            guard case .success(let values) = answer, let tuple = values.first else { complete = false; continue }
            let record = LaunchpadABI.LaunchRecord(tuple, legacy: stack.generation.legacyRecord)
            if launch == nil, record.exists, record.token == candidate, !record.curve.isZero { launch = (stack, tuple) }
        }
        var moments: [(MomentsAddresses, BigUInt)] = []
        for (cohort, answer) in zip(cohorts, answers.dropFirst(launchpads.count)) {
            guard case .success(let values) = answer, let id = values.first?.uint else { complete = false; continue }
            if id > 0 { moments.append((cohort, id)) }
        }
        return Claims(address: candidate, launch: launch?.0, record: launch?.1, moments: moments, complete: complete)
    }

    // MARK: Ingest

    /// Launches another screen read from a known launchpad (`LaunchpadService`: the board, Home's holdings, a launch that
    /// just settled). A launch whose factory the registry doesn't read is ignored. Only a `Launch` the service built from
    /// its factory's record belongs here: its token is the record's.
    public func ingest(_ launches: [Launch]) {
        var found: [DyorCoin] = []
        for launch in launches where !launch.token.isZero {
            let factory = launch.factory.isZero ? liveLaunchpad : launch.factory
            guard !factory.isZero, let stack = launchpads.first(where: { $0.factory == factory }) else { continue }
            found.append(DyorCoin(address: launch.token, origin: .launch(factory: factory, generation: stack.generation, retired: factory != liveLaunchpad),
                                  symbol: launch.symbol, name: launch.name, creator: launch.deployer, logo: launch.logo, pair: launch.pairToken))
        }
        commit(found)
    }

    /// Moments another screen read from a known cohort (`MomentsService`, `RetiredMoments`: the Moments tab, holdings, a
    /// publish that just settled). A Moment of a cohort the registry doesn't read is ignored. Only a `MomentInfo` the
    /// service built from its cohort's `getMoment` belongs here.
    public func ingest(_ moments: [MomentInfo]) {
        var found: [DyorCoin] = []
        for info in moments where !info.moment.coin.isZero && info.moment.id > 0 {
            let factory = info.moment.factory
            guard !factory.isZero, let cohort = cohorts.first(where: { $0.factory == factory }) else { continue }
            found.append(DyorCoin(address: info.moment.coin, origin: .moment(factory: factory, id: info.moment.id, retired: factory != liveCohort),
                                  symbol: info.symbol, name: info.name, creator: info.moment.creator, logo: info.provenance.mediaURI,
                                  mediaHash: info.provenance.mediaHash, mediaIsVideo: !info.provenance.animationURI.isEmpty, pair: cohort.usdc))
        }
        commit(found)
    }

    // MARK: Erase

    /// Forgets everything and deletes the file (account deletion). A read already under way writes nothing back.
    public func erase() {
        epoch += 1
        coins = [:]
        checkpoints = [:]
        notDyor = []
        unreadable = []
        lastCompleteRefresh = nil
        store?.erase()
        publish()
    }

    // MARK: Keeping

    /// Keeps `found` (an entry that differs replaces the old one; MON and the curated tokens never are one), then saves and
    /// tells the subscribers when anything changed.
    private func commit(_ found: [DyorCoin], persistAnyway: Bool = false) {
        var changed = false
        for coin in found where !coin.address.isZero && Token.core(coin.address) == nil && coins[coin.address] != coin {
            coins[coin.address] = coin
            notDyor.remove(coin.address)
            unreadable.remove(coin.address)
            changed = true
        }
        if changed || persistAnyway {
            try? store?.save(DyorCoinStore.Snapshot(coins: Array(coins.values), checkpoints: checkpoints.map { DyorCoinStore.Checkpoint(factory: $0.key, count: $0.value) }))
        }
        if changed { publish() }
    }

    private func publish() {
        for subscriber in subscribers.values { subscriber.yield(coins) }
    }

    /// Pure: what of `snapshot` the registry keeps — the coins and counts of the factories it reads, each coin's generation
    /// and retired flag as this build's tables say (a stack or cohort retired since the file was written reads as retired).
    static func restored(_ snapshot: DyorCoinStore.Snapshot, launchpads: [LaunchpadAddresses], cohorts: [MomentsAddresses],
                         liveLaunchpad: Address, liveCohort: Address) -> (coins: [Address: DyorCoin], checkpoints: [Address: Int]) {
        var coins: [Address: DyorCoin] = [:]
        for coin in snapshot.coins where !coin.address.isZero && Token.core(coin.address) == nil {
            switch coin.origin {
            case .launch(let factory, _, _):
                guard let stack = launchpads.first(where: { $0.factory == factory }) else { continue }
                coins[coin.address] = DyorCoin(address: coin.address, origin: .launch(factory: factory, generation: stack.generation, retired: factory != liveLaunchpad),
                                               symbol: coin.symbol, name: coin.name, creator: coin.creator, logo: coin.logo, pair: coin.pair)
            case .moment(let factory, let id, _):
                guard cohorts.contains(where: { $0.factory == factory }) else { continue }
                coins[coin.address] = DyorCoin(address: coin.address, origin: .moment(factory: factory, id: id, retired: factory != liveCohort),
                                               symbol: coin.symbol, name: coin.name, creator: coin.creator, logo: coin.logo,
                                               mediaHash: coin.mediaHash, mediaIsVideo: coin.mediaIsVideo, pair: coin.pair)
            }
        }
        let factories = Set(launchpads.map(\.factory) + cohorts.map(\.factory))
        var checkpoints: [Address: Int] = [:]
        for checkpoint in snapshot.checkpoints where factories.contains(checkpoint.factory) && checkpoint.count > 0 { checkpoints[checkpoint.factory] = checkpoint.count }
        return (coins, checkpoints)
    }

    // MARK: Reading

    /// `calls` in Multicall3 reads of at most `maxCallsPerRead`, one after another; every call of a read that failed as a
    /// whole comes back as a failure. For the factories' own answers, which are of a fixed size.
    private func read(_ calls: [ContractCall]) async -> [Result<[ABIValue], Error>] {
        var out: [Result<[ABIValue], Error>] = []
        out.reserveCapacity(calls.count)
        var start = 0
        while start < calls.count {
            let chunk = Array(calls[start..<min(calls.count, start + Self.maxCallsPerRead)])
            do {
                let results = try await multicall.read(chunk)
                out += results.count == chunk.count ? results : chunk.map { _ in .failure(NetworkError.malformedResponse) }
            } catch {
                out += chunk.map { _ in .failure(error) }
            }
            start += chunk.count
        }
        return out
    }

    /// What one group of calls (one coin's) came back as.
    enum GroupRead {
        /// Each call's answer. A group with a failed call has been read on its own, so the failure is its own: none of
        /// its calls was starved of gas by another coin's.
        case answered([Result<[ABIValue], Error>])
        /// No answer: the connection, a throttle, or past the pass's budget of reads on their own.
        case unanswered

        /// The group with `result` answered before its first call.
        func prepending(_ result: Result<[ABIValue], Error>) -> GroupRead {
            if case .answered(let answers) = self { return .answered([result] + answers) }
            return self
        }
    }

    /// `groups` in Multicall3 reads of at most `maxCallsPerRead` calls (a group is never split), one after another, so
    /// that no one coin can keep the others from being read, as `ERC20.metadataReport` reads symbols. A group with a failed
    /// call — a revert, a call starved of gas by a coin before it (Multicall3 reports that the same way), an answer that
    /// doesn't decode — and every group of a read the node refused as a whole on a call error (one coin's strings ran the
    /// aggregate out of gas) is read again: the first of them on its own (a coin that starves the rest fails first), the
    /// others together once, and what fails again each on its own, `maxRereads` reads again at most in all. A read with no
    /// answer at all is not retried here.
    func readGroups(_ groups: [[ContractCall]]) async -> [GroupRead] {
        var out = [GroupRead](repeating: .unanswered, count: groups.count)
        var budget = Self.maxRereads
        var start = 0
        while start < groups.count {
            var end = start
            var size = 0
            while end < groups.count, end == start || size + groups[end].count <= Self.maxCallsPerRead {
                size += groups[end].count
                end += 1
            }
            var failing = await readTogether(Array(start..<end), groups, into: &out)
            start = end
            guard !failing.isEmpty, budget > 0 else { continue }
            budget -= 1
            _ = await readTogether([failing.removeFirst()], groups, into: &out)
            guard !failing.isEmpty, budget > 0 else { continue }
            budget -= 1
            failing = await readTogether(failing, groups, into: &out)
            for index in failing where budget > 0 {
                budget -= 1
                _ = await readTogether([index], groups, into: &out)
            }
        }
        return out
    }

    /// `members`' groups in one read, their answers put in `out`: every group of a read of one, and every group whose
    /// calls all answered. Returns the others, to read again; a read with no answer leaves them all unanswered.
    private func readTogether(_ members: [Int], _ groups: [[ContractCall]], into out: inout [GroupRead]) async -> [Int] {
        let calls = members.flatMap { groups[$0] }
        switch await ERC20.captured({ try await self.multicall.read(calls) }) {
        case .success(let results) where results.count == calls.count:
            var failing: [Int] = []
            var at = 0
            for index in members {
                let answers = Array(results[at..<at + groups[index].count])
                at += groups[index].count
                if members.count == 1 || answers.allSatisfy(\.succeeded) { out[index] = .answered(answers) } else { failing.append(index) }
            }
            return failing
        case .failure(let error) where ERC20.isCallError(error):
            guard members.count > 1 else {
                out[members[0]] = .answered(groups[members[0]].map { _ in .failure(error) })
                return []
            }
            return members
        default:
            return []
        }
    }
}

extension Result where Success == [ABIValue], Failure == Error {
    /// The call answered.
    var succeeded: Bool { if case .success = self { return true } else { return false } }
    /// The call itself failed — it reverted or ran out of gas (Multicall3's report of a sub-call, or the node's of a read
    /// refused as a whole) — as opposed to an answer that doesn't decode or none at all.
    var isCallFailure: Bool {
        guard case .failure(let error) = self else { return false }
        return ERC20.isCallError(error)
    }
}
