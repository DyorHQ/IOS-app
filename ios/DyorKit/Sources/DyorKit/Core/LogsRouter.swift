import BigInt
import Foundation

/* Where the app's `eth_getLogs` go, and how a wallet's history is read: the design in full, with `HistoryStore` and the
   app's `HistoryModel`.

   Monad's public endpoints each answer a range of so many blocks per `eth_getLogs`, every one far short of a wallet's
   history (about 111M blocks), measured 2026-10-08 from the owner's network:
   - rpc2.monad.xyz: 10,000 blocks; address lists and topic lists accepted; a batch of 6 ranges in one request; 4
     requests a second sustained without a refusal, about 1 in 5 refused (HTTP 429) at 11 a second.
   - rpc4.monad.xyz: 1,000 (some nodes answer any range, most refuse over 1,000); refuses a batch with -32603.
   - rpc3.monad.xyz: 1,000, a request's ranges counted together.
   - rpc1.monad.xyz: 100 (it answered any wallet-scoped range until 2026-10-08); HTTP 429 after a burst.
   - rpc.monad.xyz: 100; the app's client for everything else.
   Build 21 and earlier asked rpc1 for the whole history on every screen (about 40 scans at once when Home opened),
   split every refusal into smaller ranges and had no time limit, so on today's endpoints every history screen spun
   for minutes and showed 0.

   The design:
   1. One logs router, every endpoint (this file). A scan is a window of blocks; the router cuts it into ranges of
      what the endpoint answers (learned from its refusals and remembered for a day), sends them in batches, and
      moves to the next endpoint when one throttles or fails. Every `eth_getLogs` in the app goes through one gate
      (`LogsGate`): a few in flight, a few a second, so the app never throttles itself. A scan has a budget of
      requests and seconds; past it, the caller gets what was read and exactly which blocks it covers (`LogsRead`),
      never a part passed off as the whole. A range refused for how many logs it holds is split, not taken for the
      endpoint's span.
   2. A history store per wallet (`HistoryStore`): five scans (transfers in and out, launchpad, fee sharing,
      Moments), each kept on disk with the blocks it covers. A refresh reads the blocks since the last one first,
      then the gaps back to the floor while its budget lasts; the cursor never moves past a block that wasn't read.
      The transfer scans read back to the wallet's first transaction (found once by bisection over its nonce at past
      blocks) or 30 days, whichever is earlier; the rest from their contracts' deployment.
   3. Screens publish what they have (`WalletHistoryService`, the app's `HistoryModel`): what the app recorded shows
      at once, chain history fills in behind ("Reading your history… 28%"), and a source that couldn't be read says
      so with Retry, never replacing what the last good read showed. Rounds of up to 40 requests per scan, a second
      apart, every 90 s once complete; rounds that read nothing come further apart (20 s doubling to 10 min), and
      from the third in a row the screens say what is left couldn't be read; a return to the app, a pull or a Retry
      starts a round at once. */

/// A public endpoint for `eth_getLogs`: the widest range it answers per request, as measured, and how many ranges
/// one request may carry.
public struct LogsEndpoint: Sendable, Hashable {
    public let url: URL
    /// The widest block range (inclusive) one `eth_getLogs` of this endpoint answers.
    public let span: UInt64
    /// Ranges one request carries: 1 where the endpoint counts a request's ranges together (rpc3) or refuses a batch
    /// (rpc4 answers a batch of ranges with an internal error).
    public let batch: Int
    /// Whether the endpoint answers state at any past block (a nonce, a balance): rpc1, rpc2 and rpc4 do; rpc3 and
    /// rpc.monad.xyz refuse old blocks ("historical state that is not available", measured 2026-10-08).
    public let archive: Bool

    public init(url: URL, span: UInt64, batch: Int = 6, archive: Bool = false) {
        self.url = url
        self.span = max(1, span)
        self.batch = max(1, batch)
        self.archive = archive
    }
}

public enum LogsEndpoints {
    /// Monad mainnet's public endpoints for logs, the widest first, as measured on 2026-10-08.
    public static let monadMainnet: [LogsEndpoint] = [
        LogsEndpoint(url: URL(string: "https://rpc2.monad.xyz")!, span: 10_000, archive: true),
        LogsEndpoint(url: URL(string: "https://rpc4.monad.xyz")!, span: 1_000, batch: 1, archive: true),
        LogsEndpoint(url: URL(string: "https://rpc3.monad.xyz")!, span: 1_000, batch: 1),
        LogsEndpoint(url: URL(string: "https://rpc1.monad.xyz")!, span: 100, archive: true),
        LogsEndpoint(url: URL(string: "https://rpc.monad.xyz")!, span: 100),
    ]
    /// The endpoints that answer state at past blocks, in order: a client for old nonces and balances fails over
    /// among these only (`RPCClient(urls:)`), never onto one that refuses them.
    public static var archive: [URL] { monadMainnet.filter(\.archive).map(\.url) }
    /// The smallest range any endpoint is asked for: what every one of them answers.
    public static let floorSpan: UInt64 = 100
}

/// An `eth_getLogs` filter with the lists the method allows: any of `addresses` (none: every contract), and at each
/// topic position any of the topics listed there (nil: anything).
public struct LogsQuery: Sendable, Hashable {
    public var addresses: [Address]
    public var topics: [[Data]?]

    public init(addresses: [Address] = [], topics: [[Data]?] = []) {
        self.addresses = addresses
        self.topics = topics
    }

    /// The single-address, single-topic form every older scan uses.
    public init(address: Address?, topics: [Data?]) {
        self.init(addresses: address.map { [$0] } ?? [], topics: topics.map { $0.map { [$0] } })
    }

    /// The filter as text, the same for the same filter: what a stored scan is checked against (`HistoryStore`).
    public var fingerprint: String {
        addresses.map { $0.hex.lowercased() }.joined(separator: ",") + "|"
            + topics.map { $0.map { $0.map(\.hexString).joined(separator: "+") } ?? "*" }.joined(separator: ",")
    }

    func json(from: UInt64, to: UInt64) -> JSON {
        var object: [String: JSON] = ["fromBlock": .string(BigUInt(from).hexQuantity), "toBlock": .string(BigUInt(to).hexQuantity)]
        if addresses.count == 1 { object["address"] = .string(addresses[0].hex) } else if addresses.count > 1 { object["address"] = .array(addresses.map { .string($0.hex) }) }
        if !topics.isEmpty {
            object["topics"] = .array(topics.map { position in
                guard let position else { return .null }
                return position.count == 1 ? .string(position[0].hexString) : .array(position.map { .string($0.hexString) })
            })
        }
        return .object(object)
    }

    /// Whether `log` matches the filter, as the endpoint matches it.
    public func matches(_ log: Log) -> Bool {
        if !addresses.isEmpty, !addresses.contains(log.address) { return false }
        for (i, position) in topics.enumerated() {
            guard let position else { continue }
            guard log.topics.indices.contains(i), position.contains(log.topics[i]) else { return false }
        }
        return true
    }
}

/// What a scan may spend: requests across every endpoint, and seconds.
public struct LogsBudget: Sendable, Equatable {
    public var requests: Int
    public var seconds: TimeInterval

    public init(requests: Int, seconds: TimeInterval) {
        self.requests = requests
        self.seconds = seconds
    }

    /// What a `chunkedLogsReport` of each mode spends: fail-fast, the Send sheet's and the Portfolio holdings' read,
    /// which say what they couldn't read; patient, every screen's scan, which takes what was read; paced, the venue
    /// list's background read.
    public init(mode: LogScanMode) {
        switch mode {
        case .failFast: self.init(requests: 12, seconds: 15)
        case .patient: self.init(requests: 80, seconds: 30)
        case .paced: self.init(requests: 400, seconds: 120)
        }
    }
}

/// What a scan read: the logs, in block order, and exactly which blocks of its window were read (`covered`, merged,
/// ascending). A window is complete when one covered range holds it whole.
public struct LogsRead: Sendable, Equatable {
    public var logs: [Log]
    public var covered: [ClosedRange<UInt64>]
    public var requests: Int

    public init(logs: [Log], covered: [ClosedRange<UInt64>], requests: Int) {
        self.logs = logs
        self.covered = covered
        self.requests = requests
    }

    /// Whether every block from `from` to `to` was read.
    public func covers(_ from: UInt64, _ to: UInt64) -> Bool {
        from > to || covered.contains { $0.lowerBound <= from && $0.upperBound >= to }
    }

    /// The last block read in one piece from `from` (nil when `from` itself wasn't read).
    public func through(from: UInt64) -> UInt64? {
        covered.first { $0.contains(from) }?.upperBound
    }

    /// The first block read in one piece down from `to` (nil when `to` itself wasn't read).
    public func downTo(_ to: UInt64) -> UInt64? {
        covered.first { $0.contains(to) }?.lowerBound
    }

    /// `ranges` merged: sorted, and touching or overlapping ones joined.
    public static func merge(_ ranges: [ClosedRange<UInt64>]) -> [ClosedRange<UInt64>] {
        var out: [ClosedRange<UInt64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, last.upperBound == UInt64.max || range.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}

/// Where a learned cap is kept between launches: an endpoint's refusals lower its span for the day.
public protocol LogsCapabilityStore: Sendable {
    func span(for url: URL) -> UInt64?
    func set(span: UInt64, for url: URL)
}

/// `LogsCapabilityStore` in UserDefaults, each span kept for a day: an endpoint may widen what it answers again.
/// UserDefaults is thread-safe, hence the unchecked conformance.
public struct UserDefaultsLogsCapabilityStore: LogsCapabilityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let ttl: TimeInterval
    public init(defaults: UserDefaults = .standard, ttl: TimeInterval = 86_400) {
        self.defaults = defaults
        self.ttl = ttl
    }
    private func key(_ url: URL) -> String { "logsRouter.v1.span.\(url.host() ?? url.absoluteString)" }
    public func span(for url: URL) -> UInt64? {
        guard let saved = defaults.dictionary(forKey: key(url)), let span = saved["span"] as? String, let at = saved["at"] as? Double,
              Date().timeIntervalSince1970 - at < ttl else { return nil }
        return UInt64(span)
    }
    public func set(span: UInt64, for url: URL) {
        defaults.set(["span": String(span), "at": Date().timeIntervalSince1970], forKey: key(url))
    }
}

/// One gate for every `eth_getLogs` the app sends, whatever started it: a few requests in flight and a space between
/// their starts, so forty scans opening at once never throttle the app on an endpoint that counts requests a second per
/// client. Four a second: rpc2 answered 260 requests of six ranges at that pace with no refusal (measured 2026-10-08),
/// and refused one in five at eleven a second.
public actor LogsGate {
    public static let shared = LogsGate(inFlight: 4, interval: .milliseconds(250))
    private let maxInFlight: Int
    private let interval: Duration
    private var inFlight = 0
    private var lastStart: ContinuousClock.Instant?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(inFlight: Int, interval: Duration) {
        maxInFlight = max(1, inFlight)
        self.interval = interval
    }

    /// Waits for a slot, then for the space after the last start.
    public func enter() async {
        while inFlight >= maxInFlight {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight += 1
        let now = ContinuousClock.now
        let start = max(now, lastStart.map { $0 + interval } ?? now)
        lastStart = start
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    public func leave() {
        inFlight = max(0, inFlight - 1)
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

/// Reads a window of logs across the endpoints (`LogsEndpoint`), in ranges of what each answers, through the gate.
public actor LogsRouter {
    public enum Order: Sendable { case ascending, descending }

    /// What an endpoint has answered this session (diagnostics, and the app's log).
    public struct Stats: Sendable, Equatable {
        public var requests = 0
        public var answered = 0
        public var tooLarge = 0
        public var pastHead = 0
        public var failed = 0
        public var throttled = 0
        public var rests = 0
    }

    /// How long a request may take before it counts as unanswered: the endpoints answer in about a second.
    public static let requestTimeout: TimeInterval = 12
    /// A rest after a throttle, doubling each time in a row, at most `maxThrottleRest`; after a failure, from
    /// `failureRest` to `maxFailureRest`.
    static let throttleRest: TimeInterval = 2, maxThrottleRest: TimeInterval = 16
    static let failureRest: TimeInterval = 1, maxFailureRest: TimeInterval = 8
    /// The widest endpoint is waited for while its rest ends within this long, rather than reading on an endpoint that
    /// answers a fifth of its span or less: a 1,000-block endpoint takes ten requests for one of a 10,000-block one.
    static let waitForWider: TimeInterval = 8

    private let endpoints: [LogsEndpoint]
    private let clients: [URL: RPCClient]
    private let gate: LogsGate
    private let store: (any LogsCapabilityStore)?
    /// Batches in flight at once for one scan.
    private let concurrency: Int
    /// What each endpoint answers now: its measured span, lowered by its refusals.
    private var spans: [URL: UInt64] = [:]
    /// Endpoints resting after a throttle or a failure, and how long their last rest was.
    private var restingUntil: [URL: ContinuousClock.Instant] = [:]
    private var lastRest: [URL: TimeInterval] = [:]
    private var batchLimits: [URL: Int] = [:]
    private var statsByURL: [URL: Stats] = [:]

    public init(endpoints: [LogsEndpoint], session: URLSession = .shared, gate: LogsGate = .shared, store: (any LogsCapabilityStore)? = nil, concurrency: Int = 4) {
        precondition(!endpoints.isEmpty, "LogsRouter needs at least one endpoint")
        self.endpoints = endpoints
        var clients: [URL: RPCClient] = [:]
        // A throttle is answered by resting the endpoint and asking the next, not by the client's own retries.
        for endpoint in endpoints where clients[endpoint.url] == nil {
            clients[endpoint.url] = RPCClient(url: endpoint.url, session: session, retries: 0, timeout: Self.requestTimeout)
        }
        self.clients = clients
        self.gate = gate
        self.store = store
        self.concurrency = max(1, concurrency)
        for endpoint in endpoints {
            if let learned = store?.span(for: endpoint.url) { spans[endpoint.url] = min(learned, endpoint.span) }
        }
    }

    /// The endpoints, in order.
    public nonisolated var urls: [URL] { endpoints.map(\.url) }

    /// What `url` answers now (tests).
    func span(of url: URL) -> UInt64 { spans[url] ?? endpoints.first { $0.url == url }?.span ?? LogsEndpoints.floorSpan }

    /// What each endpoint has answered this session, by its host.
    public func stats() -> [String: Stats] {
        var out: [String: Stats] = [:]
        for (url, stats) in statsByURL { out[url.host() ?? url.absoluteString] = stats }
        return out
    }

    /// The latest block's header from the first endpoint that answers.
    public func latest() async -> BlockHeader? {
        for endpoint in endpoints {
            if let header = try? await clients[endpoint.url]?.block(.latest) { return header }
        }
        return nil
    }

    /// The chain head from the first endpoint that answers.
    public func head() async -> UInt64? { await latest()?.number }

    /// The block a local Anvil fork started from, when the first endpoint is one (`RPCClient.localForkBlock`): the
    /// fork answers no logs below it. Nil on mainnet.
    public func localForkBlock() async -> UInt64? {
        guard let endpoint = endpoints.first, let client = clients[endpoint.url], client.isLocal else { return nil }
        return await client.localForkBlock()
    }

    private struct Piece: Hashable, Sendable { let from: UInt64; let to: UInt64 }
    /// One request's outcome: each piece's answer; whether the request was throttled; whether it got no answer at all
    /// (a transport failure, a timeout, an HTTP error), which is the endpoint's fault, not the pieces'.
    private struct Batch: Sendable { let url: URL; let pieces: [Piece]; let answers: [LogsAnswer]; let throttled: Bool; let unanswered: Bool }

    /// Reads `query` over `[from, to]`, newest ranges first when `order` is descending, within `budget`.
    public func read(_ query: LogsQuery, from: UInt64, to: UInt64, order: Order = .ascending, budget: LogsBudget) async -> LogsRead {
        guard from <= to else { return LogsRead(logs: [], covered: [], requests: 0) }
        let deadline = ContinuousClock.now + .seconds(budget.seconds)
        var logs: [Log] = []
        var seen = Set<String>()
        var covered: [ClosedRange<UInt64>] = []
        var requests = 0
        // Blocks still to ask, as ranges from the window's cursor. A range refused is asked again — in parts an endpoint
        // answers, on another endpoint — and one an endpoint refuses on its own account `maxAttempts` times is left as
        // a gap. A request that got no answer at all counts against the endpoint, not its ranges, unless it carried one.
        var cursor: UInt64? = order == .ascending ? from : to
        var retry: [Piece] = []
        var attempts: [Piece: Int] = [:]
        let maxAttempts = 3

        func requeue(_ piece: Piece, counting: Bool) {
            if counting {
                let n = (attempts[piece] ?? 0) + 1
                attempts[piece] = n
                guard n < maxAttempts else { return }
            }
            retry.append(piece)
        }

        func nextPieces(_ endpoint: LogsEndpoint) -> [Piece] {
            let span = span(of: endpoint.url)
            let limit = batchLimit(endpoint)
            var out: [Piece] = []
            // Ranges to ask again first, cut to this endpoint's span; what doesn't fit the request waits at the front.
            while out.count < limit, let piece = retry.first {
                retry.removeFirst()
                var start = piece.from
                while start <= piece.to {
                    let end = min(piece.to, start + span - 1)
                    if out.count < limit {
                        out.append(Piece(from: start, to: end))
                    } else {
                        retry.insert(Piece(from: start, to: piece.to), at: 0)
                        break
                    }
                    if end == UInt64.max { break }
                    start = end + 1
                }
            }
            while out.count < limit, let at = cursor {
                switch order {
                case .ascending:
                    let end = min(to, at + span - 1)
                    out.append(Piece(from: at, to: end))
                    cursor = end < to ? end + 1 : nil
                case .descending:
                    let start = at - from >= span ? at - span + 1 : from
                    out.append(Piece(from: start, to: at))
                    cursor = start > from ? start - 1 : nil
                }
            }
            return out
        }

        await withTaskGroup(of: Batch.self) { group in
            var inFlight = 0
            while true {
                while inFlight < concurrency, requests < budget.requests, ContinuousClock.now < deadline, !Task.isCancelled,
                      let endpoint = await available(deadline: deadline) {
                    let pieces = nextPieces(endpoint)
                    guard !pieces.isEmpty else { break }
                    requests += 1
                    inFlight += 1
                    let client = clients[endpoint.url]!
                    let url = endpoint.url
                    group.addTask { [gate] in
                        await gate.enter()
                        let answered = await Self.ask(client, query: query, pieces: pieces.map { ($0.from, $0.to) })
                        await gate.leave()
                        return Batch(url: url, pieces: pieces, answers: answered.answers, throttled: answered.throttled, unanswered: answered.unanswered)
                    }
                }
                guard inFlight > 0, let batch = await group.next() else { break }
                inFlight -= 1
                // Cancelled (the screen closed): what came back is dropped, and no endpoint is blamed for the rest.
                if Task.isCancelled { continue }
                var stats = statsByURL[batch.url] ?? Stats()
                stats.requests += 1
                if batch.unanswered {
                    // The endpoint's fault: it rests, and its next request carries fewer ranges. The ranges are asked again,
                    // counted against them only when one was alone in the request.
                    stats.failed += batch.pieces.count
                    if batch.throttled { stats.throttled += 1 }
                    stats.rests += 1
                    rest(batch.url, throttled: batch.throttled)
                    if !batch.throttled { halveBatch(batch.url) }
                    for piece in batch.pieces { requeue(piece, counting: batch.pieces.count == 1 && !batch.throttled) }
                } else {
                    // Whether a range refused at the floor rested the endpoint: the rest then stands, not cleared below.
                    var rested = false
                    for (piece, answer) in zip(batch.pieces, batch.answers) {
                        switch answer {
                        case .logs(let found):
                            stats.answered += 1
                            covered.append(piece.from...piece.to)
                            for log in found where seen.insert(log.id).inserted { logs.append(log) }
                        case .tooLarge(let cut, let dense):
                            stats.tooLarge += 1
                            let width = piece.to - piece.from + 1
                            if dense, width > LogsEndpoints.floorSpan {
                                // Too many logs in the range, not too wide a range: asked again in two — at the cut the endpoint
                                // names, else halves — on whichever endpoint is free; the span stays.
                                let split = cut.flatMap { $0 >= piece.from && $0 < piece.to ? $0 : nil } ?? piece.from + width / 2 - 1
                                requeue(Piece(from: piece.from, to: split), counting: false)
                                requeue(Piece(from: split + 1, to: piece.to), counting: false)
                            } else if !dense, lower(batch.url, refused: width, cut: cut.map { $0 - piece.from + 1 }) {
                                // Too wide: the endpoint's span is lowered, remembered, and the range re-cut at it.
                                requeue(piece, counting: false)
                            } else {
                                // Refused at the floor: the endpoint rests so the next one is asked, and the refusal counts
                                // against the range, a gap after `maxAttempts` (every endpoint refusing it).
                                stats.rests += 1
                                rest(batch.url, throttled: false)
                                rested = true
                                requeue(piece, counting: true)
                            }
                        case .pastHead:
                            stats.pastHead += 1
                            requeue(piece, counting: true)
                        case .failed, .throttled:
                            stats.failed += 1
                            requeue(piece, counting: true)
                        }
                    }
                    if !rested { lastRest[batch.url] = nil }
                    batchLimits[batch.url] = nil
                }
                statsByURL[batch.url] = stats
            }
        }

        return LogsRead(logs: logs.sorted { a, b in a.blockNumber == b.blockNumber ? a.logIndex < b.logIndex : a.blockNumber < b.blockNumber },
                        covered: LogsRead.merge(covered), requests: requests)
    }

    /// The first endpoint not resting — unless a wider one, resting, wakes soon enough to be worth the wait
    /// (`waitForWider`) and hasn't been resting over and over; when every one rests, waits for the first to wake,
    /// within `deadline`.
    private func available(deadline: ContinuousClock.Instant) async -> LogsEndpoint? {
        while true {
            let now = ContinuousClock.now
            if let endpoint = endpoints.first(where: { (restingUntil[$0.url] ?? now) <= now }) {
                // A wider endpoint resting for a moment is worth more than a narrow one answering now.
                let wider = endpoints.prefix { $0.url != endpoint.url }.filter { span(of: $0.url) >= span(of: endpoint.url) * 5 && (lastRest[$0.url] ?? 0) < Self.waitForWider }
                if let wake = wider.compactMap({ restingUntil[$0.url] }).min(), wake - now <= .seconds(Self.waitForWider), wake < deadline, !Task.isCancelled {
                    try? await Task.sleep(until: wake, clock: .continuous)
                    continue
                }
                return endpoint
            }
            guard let wake = endpoints.compactMap({ restingUntil[$0.url] }).min(), wake < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(until: wake, clock: .continuous)
        }
    }

    /// How many ranges a request of `endpoint` carries now: its batch, halved after each request of it that got no
    /// answer (`halveBatch`), back to its batch once one is answered.
    private func batchLimit(_ endpoint: LogsEndpoint) -> Int { min(endpoint.batch, batchLimits[endpoint.url] ?? endpoint.batch) }

    private func halveBatch(_ url: URL) {
        let current = batchLimits[url] ?? endpoints.first { $0.url == url }?.batch ?? 1
        batchLimits[url] = max(1, current / 2)
    }

    /// `url` rests after a throttle or a failure, longer each time in a row (`throttleRest`, `failureRest`).
    private func rest(_ url: URL, throttled: Bool) {
        let floor = throttled ? Self.throttleRest : Self.failureRest
        let cap = throttled ? Self.maxThrottleRest : Self.maxFailureRest
        let next = min(cap, max(floor, (lastRest[url] ?? 0) * 2))
        lastRest[url] = next
        restingUntil[url] = .now + .seconds(next)
    }

    /// `url` refused a range of `refused` blocks as too wide: it answers less. The span the refusal names (`cut`: rpc4
    /// and rpc.monad.xyz name the number), else half, never under the floor. Remembered for the day. False when there
    /// is nothing left to lower: refused at the floor already.
    private func lower(_ url: URL, refused: UInt64, cut: UInt64?) -> Bool {
        let current = span(of: url)
        var next = cut.map { max(1, $0) } ?? current / 2
        if next >= refused { next = refused / 2 }
        next = max(LogsEndpoints.floorSpan, next)
        guard next < current else { return false }
        spans[url] = next
        store?.set(span: next, for: url)
        return true
    }

    /// `pieces` of `query` asked of `client` in one request: each range's answer, whether the request was throttled, and
    /// whether it got no answer at all.
    private static func ask(_ client: RPCClient, query: LogsQuery, pieces: [(from: UInt64, to: UInt64)]) async -> (answers: [LogsAnswer], throttled: Bool, unanswered: Bool) {
        do {
            let results = try await client.batch(pieces.map { ("eth_getLogs", [query.json(from: $0.from, to: $0.to)]) })
            guard results.count == pieces.count else { return (pieces.map { _ in .failed }, false, true) }
            var throttled = false
            let answers = zip(pieces, results).map { piece, result -> LogsAnswer in
                switch result {
                case .success(let json):
                    guard let items = json.array else { return .failed }
                    var logs: [Log] = []
                    for item in items { guard let log = Log(json: item) else { return .failed }; logs.append(log) }
                    return .logs(logs)
                case .failure(let error):
                    if RPCClient.refusesPastHead(error) { return .pastHead }
                    if RPCClient.refusesSize(error) {
                        // A span the endpoint names is its cap, lowered to; a range it suggests from the same start, or a
                        // count it refuses, is this range's density: split, the span kept.
                        if let named = Self.namedSpan(error) {
                            let (end, overflow) = piece.from.addingReportingOverflow(named - 1)
                            return .tooLarge(cut: overflow || end >= piece.to ? nil : end, dense: false)
                        }
                        if let suggested = RPCClient.suggestedEnd(error, from: piece.from, to: piece.to) { return .tooLarge(cut: suggested, dense: true) }
                        return .tooLarge(cut: nil, dense: RPCClient.refusesCount(error))
                    }
                    if RPCClient.isRateLimited(error) { throttled = true }
                    return .failed
                }
            }
            // Every range refused as a throttle, or a batch refused outright (rpc4 answers a batch of ranges with one
            // internal error): no answer about the ranges themselves.
            let allFailed = answers.allSatisfy { if case .failed = $0 { return true }; return false }
            return (answers, throttled, allFailed && (throttled || pieces.count > 1))
        } catch {
            if case NetworkError.badStatus(let status) = error { return (pieces.map { _ in .failed }, RPCClient.isThrottle(status: status), true) }
            if let error = error as? RPCError { return (pieces.map { _ in .failed }, RPCClient.isRateLimited(error), true) }
            return (pieces.map { _ in .failed }, false, true)
        }
    }

    /// The range a refusal names in words — rpc.monad.xyz's and rpc4's "eth_getLogs is limited to a 1,000 range", rpc1's
    /// "requests with up to a 1,000 block range" — as a span; nil when it names none.
    static func namedSpan(_ error: RPCError) -> UInt64? {
        let message = error.message.lowercased()
        // not localized: the endpoints' own English, matched as they send it
        guard let marker = message.range(of: "limited to a ") ?? message.range(of: "up to a ") else { return nil }
        let digits = message[marker.upperBound...].prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        guard let span = UInt64(digits), span > 0 else { return nil }
        return span
    }
}
