import BigInt
import Foundation

/* A wallet's history, kept on the device. Each scan of it (`HistoryScan`: a filter and the oldest block it reads) is
   an entry: the logs read so far and exactly which blocks they cover. A refresh reads the blocks since the newest
   covered one first, then fills the gaps back to the floor while its budget lasts, newest first, and saves after
   every read; the coverage never claims a block that wasn't read, so a refresh cut short resumes where it stopped,
   however many launches later. Screens read the entry first — instantly — and refresh it behind. */

/// One of a wallet's scans: what it asks for, and the oldest block it ever reads.
public struct HistoryScan: Sendable, Hashable {
    /// The oldest block a scan reads: a block (a contract's deployment), or so many blocks back from the head.
    public enum Floor: Sendable, Hashable {
        case block(UInt64)
        case blocks(UInt64)
        /// The earlier of a block and so many blocks back: a wallet's first transaction, or the usual window when
        /// that is nearer than it.
        case earliest(block: UInt64, blocks: UInt64)

        public func block(head: UInt64) -> UInt64 {
            switch self {
            case .block(let block): return min(block, head)
            case .blocks(let count): return head > count ? head - count : 0
            case .earliest(let block, let count): return min(Floor.block(block).block(head: head), Floor.blocks(count).block(head: head))
            }
        }
    }

    public let id: String
    public let query: LogsQuery
    public let floor: Floor

    public init(id: String, query: LogsQuery, floor: Floor) {
        self.id = id
        self.query = query
        self.floor = floor
    }
}

/// What the store holds of one scan for one wallet.
public struct HistoryEntry: Sendable, Equatable {
    /// Every log read, in block order, each once.
    public var logs: [Log]
    /// The blocks read, merged, ascending.
    public var covered: [ClosedRange<UInt64>]
    /// The chain head, its timestamp and the scan's floor at the last refresh that read the head; nil before the first.
    public var head: UInt64?
    public var headTimestamp: Int?
    public var floor: UInt64?
    /// The oldest block whose logs are kept once the cap dropped older ones (`trim`): the floor never goes below it
    /// again, so the entry can be complete without what was dropped.
    public var capFloor: UInt64?
    public var updatedAt: Date?
    /// Whether the last refresh read the head: false says the chain couldn't be reached, so nothing moved.
    public var reachedChain = true

    public init(logs: [Log] = [], covered: [ClosedRange<UInt64>] = [], head: UInt64? = nil, headTimestamp: Int? = nil, floor: UInt64? = nil, capFloor: UInt64? = nil,
                updatedAt: Date? = nil) {
        self.logs = logs
        self.covered = covered
        self.head = head
        self.headTimestamp = headTimestamp
        self.floor = floor
        self.capFloor = capFloor
        self.updatedAt = updatedAt
    }

    /// The head as a block header, for estimating each log's time; nil before the first refresh.
    public var anchor: BlockHeader? {
        guard let head, let headTimestamp else { return nil }
        return BlockHeader(number: head, timestamp: headTimestamp)
    }

    public static let empty = HistoryEntry()

    /// Whether every block from the floor to the head has been read.
    public var complete: Bool {
        guard let head, let floor else { return false }
        return covered.contains { $0.lowerBound <= floor && $0.upperBound >= head }
    }

    /// The blocks of `[floor, head]` not read yet.
    public var unread: UInt64 {
        guard let head, let floor, head >= floor else { return 0 }
        let read = covered.reduce(UInt64(0)) { total, range in
            let low = max(range.lowerBound, floor), high = min(range.upperBound, head)
            return high >= low ? total + (high - low + 1) : total
        }
        return (head - floor + 1) - min(read, head - floor + 1)
    }

    /// How much of `[floor, head]` has been read, 0 to 1.
    public var progress: Double {
        guard let head, let floor, head >= floor else { return complete ? 1 : 0 }
        return 1 - Double(unread) / Double(head - floor + 1)
    }

    /// The newest block read in one piece with the head (nil when the head itself wasn't read).
    public var through: UInt64? {
        guard let head else { return nil }
        return covered.first { $0.contains(head) }?.upperBound
    }

    /// The gaps of `[floor, head]`, newest first.
    func gaps(head: UInt64, floor: UInt64) -> [ClosedRange<UInt64>] {
        guard head >= floor else { return [] }
        var gaps: [ClosedRange<UInt64>] = []
        var cursor = floor
        for range in covered where range.upperBound >= floor && range.lowerBound <= head {
            if range.lowerBound > cursor { gaps.append(cursor...(range.lowerBound - 1)) }
            cursor = max(cursor, range.upperBound == UInt64.max ? range.upperBound : range.upperBound + 1)
            if cursor > head { break }
        }
        if cursor <= head { gaps.append(cursor...head) }
        return gaps.reversed()
    }
}

/// The wallet's history scans, each kept on disk and refreshed incrementally (`HistoryEntry`).
public actor HistoryStore {
    /// Logs kept per entry: past them, the oldest are dropped and the coverage starts where the kept logs do.
    public static let logCap = 20_000
    /// Blocks read again before the newest covered one on every refresh, in case the head came from a node behind.
    static let overlap: UInt64 = 20

    private let router: LogsRouter
    private let directory: URL?
    private var entries: [String: HistoryEntry] = [:]
    private var refreshing: [String: Task<HistoryEntry, Never>] = [:]
    /// Counts erasures (`forget`): a refresh under way when one happens keeps nothing of what it read.
    private var erasures = 0

    /// `directory`: where entries are kept between launches; nil keeps them in memory only (tests).
    public init(router: LogsRouter, directory: URL?) {
        self.router = router
        self.directory = directory
    }

    private static func key(_ scan: HistoryScan, _ wallet: Address) -> String { "\(wallet.hex.lowercased())-\(scan.id)" }

    /// What is held for `scan` and `wallet`, from memory or disk; empty before the first refresh.
    public func cached(_ scan: HistoryScan, wallet: Address) -> HistoryEntry {
        let key = Self.key(scan, wallet)
        if let entry = entries[key] { return entry }
        let loaded = load(scan, wallet) ?? .empty
        entries[key] = loaded
        return loaded
    }

    /// The chain head, from the first endpoint that answers (`LogsRouter.latest`); nil when none does. A round of every
    /// scan reads it once and hands it to each (`refresh(_:wallet:budget:at:)`, `WalletHistoryService.refresh`).
    public func latest() async -> BlockHeader? {
        await router.latest()
    }

    /// Reads what `scan` is missing for `wallet` — the blocks since the newest read, then the gaps back to the floor,
    /// newest first — within `budget`, and returns the entry as it then stands. A refresh already running for the same
    /// scan and wallet is joined, not doubled. The head is read first (`latest`).
    public func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget) async -> HistoryEntry {
        await refresh(scan, wallet: wallet, budget: budget, head: .read)
    }

    /// `refresh` up to `latest`, the head the caller read for a round of every scan (`WalletHistoryService.refresh`): five
    /// scans each reading it were five identical requests to the logs endpoint, outside the gate, beside the scans' own.
    /// Nil: the head couldn't be read, so the chain wasn't reached and nothing moves, as when the refresh reads it itself.
    public func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget, at latest: BlockHeader?) async -> HistoryEntry {
        await refresh(scan, wallet: wallet, budget: budget, head: .given(latest))
    }

    /// Where a refresh's head comes from: read by the refresh, or given by its caller (nil: it couldn't be read).
    private enum Head: Sendable {
        case read
        case given(BlockHeader?)
    }

    private func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget, head: Head) async -> HistoryEntry {
        let key = Self.key(scan, wallet)
        if let running = refreshing[key] { return await running.value }
        let task = Task { await self.read(scan, wallet: wallet, key: key, budget: budget, head: head) }
        refreshing[key] = task
        let entry = await task.value
        refreshing[key] = nil
        return entry
    }

    /// Forgets everything held for `wallet` (an erase of this device's data): memory, disk, and whatever a refresh
    /// under way reads after this.
    public func forget(wallet: Address) {
        erasures += 1
        let prefix = "\(wallet.hex.lowercased())-"
        for key in entries.keys where key.hasPrefix(prefix) { entries[key] = nil }
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(wallet.hex.lowercased())) }
    }

    private func read(_ scan: HistoryScan, wallet: Address, key: String, budget: LogsBudget, head given: Head) async -> HistoryEntry {
        var entry = cached(scan, wallet: wallet)
        let erasure = erasures
        // Keeps the entry, in memory and on disk, unless the wallet was forgotten meanwhile.
        func keep(_ entry: HistoryEntry) {
            guard erasures == erasure else { return }
            entries[key] = entry
            save(entry, scan, wallet)
        }
        // The head: read now, or the one the round read for every scan.
        let header: BlockHeader?
        switch given {
        case .read: header = await router.latest()
        case .given(let read): header = read
        }
        guard let latest = header else {
            entry.reachedChain = false
            if erasures == erasure { entries[key] = entry }
            return entry
        }
        let head = latest.number
        entry.reachedChain = true
        // The scan's floor: never below the logs the cap kept (`capFloor`), nor below a local fork's first block (the
        // fork answers no logs under it, and the endpoint behind it refuses the wide ranges).
        var floor = max(scan.floor.block(head: head), entry.capFloor ?? 0)
        if let fork = await router.localForkBlock() { floor = max(floor, min(fork, head)) }
        let started = ContinuousClock.now
        var requests = 0
        func remaining() -> LogsBudget? {
            let elapsed = (ContinuousClock.now - started).components
            let seconds = budget.seconds - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            let left = budget.requests - requests
            return left > 0 && seconds > 0 ? LogsBudget(requests: left, seconds: seconds) : nil
        }
        // Every read is the history's, at the gate (`LogsGate.Lane.history`): behind the screen the user is looking at, ahead
        // of the background. The blocks since the newest read, with a little overlap, first — unless what was read lies
        // below the window now (the app unopened for longer than it), when the gaps below read down from the head instead.
        if let newest = entry.covered.last, newest.upperBound < head, newest.upperBound >= floor, let budget = remaining() {
            let from = newest.upperBound > Self.overlap ? newest.upperBound - Self.overlap : 0
            let read = await router.read(scan.query, from: max(from, floor), to: head, order: .ascending, budget: budget, lane: .history)
            requests += read.requests
            entry.merge(read)
        }
        // Then the gaps back to the floor, newest first, each read down from its end.
        entry.head = head
        entry.headTimestamp = latest.timestamp
        entry.floor = floor
        for gap in entry.gaps(head: head, floor: floor) {
            guard let budget = remaining(), !Task.isCancelled else { break }
            let read = await router.read(scan.query, from: gap.lowerBound, to: gap.upperBound, order: .descending, budget: budget, lane: .history)
            requests += read.requests
            entry.merge(read)
            keep(entry)
            if read.requests == 0 { break }
        }
        entry.trim(floor: floor)
        entry.updatedAt = Date()
        keep(entry)
        return entry
    }

    // MARK: Disk

    /// One log as kept: `s`, its block's timestamp (`Log.blockTimestamp`), is optional — left out when the endpoint gave
    /// none, and absent from every log kept before the app read it — so the files kept before it load as they are, still
    /// version 2, and the next read of their blocks adds it (`HistoryEntry.merge`).
    private struct StoredLog: Codable {
        let a: String, t: [String], d: String, b: UInt64, h: String, i: Int
        let s: Int?
        init(_ log: Log) {
            a = log.address.hex; t = log.topics.map(\.hexString); d = log.data.hexString; b = log.blockNumber; h = log.transactionHash.hexString; i = log.logIndex
            s = log.blockTimestamp
        }
        var log: Log? {
            guard let address = Address(a), let data = Data(hex: d), let hash = Data(hex: h) else { return nil }
            var topics: [Data] = []
            for topic in t { guard let bytes = Data(hex: topic) else { return nil }; topics.append(bytes) }
            return Log(address: address, topics: topics, data: data, blockNumber: b, transactionHash: hash, logIndex: i, blockTimestamp: s)
        }
    }

    private struct Stored: Codable {
        var version = 2
        /// The filter the logs were read with (`LogsQuery.fingerprint`): a file read with another is started over.
        var query: String
        var covered: [[UInt64]]
        var head: UInt64?
        var headTimestamp: Int?
        var floor: UInt64?
        var capFloor: UInt64?
        var updatedAt: Date?
        var logs: [StoredLog]
    }

    private func file(_ scan: HistoryScan, _ wallet: Address) -> URL? {
        file(named: scan.id, wallet)
    }

    private func file(named name: String, _ wallet: Address) -> URL? {
        directory?.appendingPathComponent(wallet.hex.lowercased()).appendingPathComponent("\(name).json")
    }

    private func load(_ scan: HistoryScan, _ wallet: Address) -> HistoryEntry? {
        guard let file = file(scan, wallet), let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 2, stored.query == scan.query.fingerprint else { return nil }
        var logs: [Log] = []
        for item in stored.logs { guard let log = item.log else { return nil }; logs.append(log) }
        let covered = stored.covered.compactMap { pair -> ClosedRange<UInt64>? in pair.count == 2 && pair[0] <= pair[1] ? pair[0]...pair[1] : nil }
        return HistoryEntry(logs: logs, covered: LogsRead.merge(covered), head: stored.head, headTimestamp: stored.headTimestamp, floor: stored.floor, capFloor: stored.capFloor,
                            updatedAt: stored.updatedAt)
    }

    private func save(_ entry: HistoryEntry, _ scan: HistoryScan, _ wallet: Address) {
        guard let file = file(scan, wallet) else { return }
        let stored = Stored(query: scan.query.fingerprint, covered: entry.covered.map { [$0.lowerBound, $0.upperBound] }, head: entry.head, headTimestamp: entry.headTimestamp,
                            floor: entry.floor, capFloor: entry.capFloor, updatedAt: entry.updatedAt, logs: entry.logs.map(StoredLog.init))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Beside the scans

    /* What is built from a wallet's scans and costs reads to build again — each transaction's facts (`WalletHistoryService`),
       the reference its records were last matched with — is kept in the same folder as the scans, under its own name
       (never a scan's id), so it loads with them, from the device, and `forget` erases it with them. */

    /// Counts the erasures so far (`forget`): what a caller read before one is kept only when none came between
    /// (`keep(_:named:wallet:since:)`).
    public var erasureMark: Int { erasures }

    /// What is kept beside `wallet`'s scans under `name`; nil when nothing is, there is no folder (tests), or it can't be
    /// read as `type`.
    public func kept<T: Decodable & Sendable>(_ type: T.Type, named name: String, wallet: Address) -> T? {
        guard let file = file(named: name, wallet), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Keeps `value` beside `wallet`'s scans under `name` — unless the wallet was forgotten since `mark` (`erasureMark`):
    /// an erase of this device's data keeps nothing read before it.
    public func keep<T: Encodable & Sendable>(_ value: T, named name: String, wallet: Address, since mark: Int) {
        guard erasures == mark, let file = file(named: name, wallet), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension HistoryEntry {
    /// Adds what a read covered and found, each log once. A log held without its block's timestamp (kept before the app
    /// read it) takes the one a new read of it carries — the overlap of every refresh, a gap read again.
    mutating func merge(_ read: LogsRead) {
        guard !read.covered.isEmpty else { return }
        covered = LogsRead.merge(covered + read.covered)
        var held = Dictionary(logs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for log in read.logs {
            if let index = held[log.id] {
                if logs[index].blockTimestamp == nil, log.blockTimestamp != nil { logs[index] = log }
            } else {
                held[log.id] = logs.count
                logs.append(log)
            }
        }
        logs.sort { a, b in a.blockNumber == b.blockNumber ? a.logIndex < b.logIndex : a.blockNumber < b.blockNumber }
    }

    /// Drops what lies below `floor`, and the oldest logs past the cap with the coverage they came from: from then on
    /// the floor is where the kept logs start (`capFloor`), so the entry can be complete without what was dropped.
    mutating func trim(floor: UInt64) {
        var cut = floor
        if logs.count > HistoryStore.logCap {
            let kept = logs[logs.count - HistoryStore.logCap].blockNumber
            if kept > cut {
                cut = kept
                capFloor = max(capFloor ?? 0, kept)
                self.floor = max(self.floor ?? 0, kept)
            }
        }
        guard cut > 0 else { return }
        logs.removeAll { $0.blockNumber < cut }
        covered = covered.compactMap { range in
            guard range.upperBound >= cut else { return nil }
            return max(range.lowerBound, cut)...range.upperBound
        }
    }
}
