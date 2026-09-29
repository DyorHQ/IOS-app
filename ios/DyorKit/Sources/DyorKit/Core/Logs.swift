import BigInt
import Foundation

/// An `eth_getLogs` query. Topics are positional: `nil` matches anything at that position, and the array may be
/// shorter than the log's topic list.
public struct LogFilter: Sendable, Equatable {
    public var address: Address?
    public var topics: [Data?]
    public var fromBlock: UInt64
    public var toBlock: UInt64

    public init(address: Address? = nil, topics: [Data?] = [], fromBlock: UInt64, toBlock: UInt64) {
        self.address = address
        self.topics = topics
        self.fromBlock = fromBlock
        self.toBlock = toBlock
    }

    var json: JSON {
        var object: [String: JSON] = [
            "fromBlock": .string(BigUInt(fromBlock).hexQuantity),
            "toBlock": .string(BigUInt(toBlock).hexQuantity),
        ]
        if let address { object["address"] = .string(address.hex) }
        if !topics.isEmpty { object["topics"] = .array(topics.map { topic in topic.map { .string($0.hexString) } ?? .null }) }
        return .object(object)
    }
}

/// What an endpoint answered for one `eth_getLogs` range.
enum LogsAnswer: Sendable {
    case logs([Log])
    /// Refused for its size: its block span, or how many logs it would return, is over the endpoint's cap
    /// (`RPCClient.refusesSize`). A smaller range is answered: `cut`, when the endpoint names one, is the last block of a
    /// range from the same start it can answer (`RPCClient.suggestedEnd`).
    case tooLarge(cut: UInt64?)
    /// Anything else: an internal error, a throttle that outlasted the client's retries, no answer. A smaller range
    /// may not be answered either.
    case failed
}

/// How a scan (`RPCClient.chunkedLogsReport`) meets a range the endpoint doesn't answer for a reason other than its size:
/// an internal error, a throttle that outlasted the client's retries, no answer. In either mode a range refused for its
/// size is read in the parts the endpoint names, or in halves.
public enum LogScanMode: Sendable, Equatable {
    /// Every scan but the wallet's history on Send and the Portfolio, whose callers take what it read: such a range is read
    /// again in halves, each part that fails halved again down to the smallest range, as build 15 read it, with a pause
    /// that grows while nothing is answered, so an outage of a few seconds doesn't cut a history short. Bounded
    /// (`LogScanLimits`): once no range has been answered for 45 s the endpoint is down, and the scan stops there,
    /// incomplete; and it halves failed ranges at most 256 times.
    case patient
    /// The wallet's history on Send and the Portfolio, which say what they couldn't read and offer Retry: such a range is
    /// asked once more, then left as a gap, and two rounds in a row with no range answered end the scan, in about 27
    /// requests.
    case failFast
}

/// What a scan may spend (`LogScanMode`), so no endpoint can keep one going for hours. Tests make them smaller.
struct LogScanLimits: Sendable, Equatable {
    /// Splits a scan may make in all, whatever refused the range: past them, a part refused again is left as a gap.
    var splits = 4_096
    /// Patient: splits of ranges that failed for a reason other than their size.
    var failedSplits = 256
    /// Patient: the endpoint is down once no range has been answered for this long, in seconds…
    var outage: TimeInterval = 45
    /// …and while nothing is answered, a part waits `pause` seconds for each request in a row that got no answer, at most
    /// `maxPause`.
    var pause: TimeInterval = 0.25
    var maxPause: TimeInterval = 2
}

/// A scan's running account (`RPCClient.chunkedLogsReport`): what it may still split, and whether the endpoint is
/// answering.
struct LogScan {
    let mode: LogScanMode
    let limits: LogScanLimits
    private(set) var splits: Int
    private(set) var failedSplits: Int
    /// Requests in a row that got no range answered.
    private(set) var failedInARow = 0
    /// When a range was last answered — with its logs, or a refusal of its size — or the scan started.
    private var answeredAt = Date()
    /// Patient: no range has been answered for `limits.outage`. The endpoint is down; the scan stops there, incomplete.
    private(set) var down = false

    init(mode: LogScanMode, limits: LogScanLimits) {
        self.mode = mode
        self.limits = limits
        splits = limits.splits
        failedSplits = limits.failedSplits
    }

    /// One request's answers. A range answered with its logs, or refused for its size, is the endpoint answering.
    mutating func record(_ answers: [LogsAnswer]) {
        if answers.contains(where: { if case .failed = $0 { return false }; return true }) {
            failedInARow = 0
            answeredAt = Date()
            return
        }
        failedInARow += 1
        if mode == .patient, Date().timeIntervalSince(answeredAt) >= limits.outage { down = true }
    }

    /// Patient, while the endpoint isn't answering: how long the next part waits. 0 otherwise.
    var pause: TimeInterval {
        mode == .patient && failedInARow > 0 ? min(limits.pause * Double(failedInARow), limits.maxPause) : 0
    }

    /// Whether `part` would be read in halves if it failed for a reason other than its size: patient, while the scan's
    /// splits last, and when it is wider than `floor` blocks.
    func halvesFailures(_ part: LogFilter, floor: UInt64) -> Bool {
        mode == .patient && splits > 0 && failedSplits > 0 && part.toBlock >= part.fromBlock && part.toBlock - part.fromBlock + 1 > floor
    }

    /// `part` in two after `answer`. Refused for its size: where the refusal says a range the endpoint can answer ends,
    /// while `cuts` lasts, else in halves. Failed for another reason: in halves when `halvesFailures`. Nil — the part is a
    /// gap — when it was answered, is no wider than `floor` blocks, or the scan's splits are spent.
    mutating func divide(_ part: LogFilter, after answer: LogsAnswer, cuts: inout Int, floor: UInt64) -> [LogFilter]? {
        guard splits > 0 else { return nil }
        let parts: [LogFilter]?
        switch answer {
        case .logs:
            return nil
        case .tooLarge(let cut):
            let named = cuts > 0 ? cut : nil
            if named != nil { cuts -= 1 }
            parts = RPCClient.split(part, at: named, floor: floor)
        case .failed:
            guard halvesFailures(part, floor: floor) else { return nil }
            parts = RPCClient.split(part, floor: floor)
            if parts != nil { failedSplits -= 1 }
        }
        if parts != nil { splits -= 1 }
        return parts
    }
}

/// One event emitted by a contract, as `eth_getLogs` and transaction receipts report it.
public struct Log: Sendable, Hashable, Identifiable {
    public let address: Address
    public let topics: [Data]
    public let data: Data
    public let blockNumber: UInt64
    public let transactionHash: Data
    public let logIndex: Int

    /// `txHash-logIndex`, unique across the chain.
    public var id: String { "\(transactionHash.hexString)-\(logIndex)" }

    public init(address: Address, topics: [Data], data: Data, blockNumber: UInt64, transactionHash: Data, logIndex: Int) {
        self.address = address
        self.topics = topics
        self.data = data
        self.blockNumber = blockNumber
        self.transactionHash = transactionHash
        self.logIndex = logIndex
    }

    /// Parses one log object from a JSON-RPC response. Returns nil when a required field is missing or malformed.
    public init?(json: JSON) {
        guard let addressHex = json["address"].string, let address = Address(addressHex),
              let topicList = json["topics"].array,
              let dataHex = json["data"].string, let data = Data(hex: dataHex),
              let blockHex = json["blockNumber"].string, let block = BigUInt(hexQuantity: blockHex),
              let hashHex = json["transactionHash"].string, let hash = Data(hex: hashHex),
              let indexHex = json["logIndex"].string, let index = BigUInt(hexQuantity: indexHex)
        else { return nil }
        var topics: [Data] = []
        for topic in topicList {
            guard let hex = topic.string, let bytes = Data(hex: hex) else { return nil }
            topics.append(bytes)
        }
        self.init(address: address, topics: topics, data: data, blockNumber: UInt64(clamping: block), transactionHash: hash, logIndex: Int(clamping: index))
    }

    /// The `index`th indexed parameter as an address (topic 0 is the event signature).
    public func indexedAddress(_ index: Int) -> Address? {
        guard topics.indices.contains(index + 1), topics[index + 1].count == 32 else { return nil }
        return Address(data: topics[index + 1].suffix(20))
    }
}

/// The two block fields the app needs: the number and the timestamp that anchors event times.
public struct BlockHeader: Sendable, Equatable {
    public let number: UInt64
    public let timestamp: Int

    public init(number: UInt64, timestamp: Int) {
        self.number = number
        self.timestamp = timestamp
    }
}

public extension ABI {
    /// keccak256 of a canonical event signature such as `Transfer(address,address,uint256)`: the first topic
    /// of every log the event emits.
    static func eventTopic(_ signature: String) -> Data { Keccak.hash256(signature) }
}

public extension RPCClient {
    /// keccak256 of a canonical event signature; see `ABI.eventTopic`.
    static func eventTopic(_ signature: String) -> Data { ABI.eventTopic(signature) }

    /// The widest block range each of Monad's public endpoints answers per `eth_getLogs` request, measured read-only on
    /// 2026-09-29: rpc1 has no range cap (it answered 10M blocks in a second; its cap is 10K logs an answer, and it names
    /// a range that fits); rpc3 answers 1,000 blocks, `fromBlock` and `toBlock` both counted, and refuses 1,001 ("Block
    /// range is too large", -32062), counting every range in a request together (`logBatchSpan`); rpc4 is served by
    /// nodes that answer 100,000 and nodes that refuse 1,001 ("limited to a 1,000 range", -32614 in an HTTP 413), so 1,000
    /// is what every one of them answers; rpc.monad.xyz answers 100 and refuses 500. A local fork has no cap; 50,000 keeps
    /// its answers quick. A range sized over the cap is refused and split (`chunkedLogsReport`), one request a split, and
    /// a scan may split only so often (`LogScanLimits`): rpc3 sized at 100,000, as build 16 sized it, needs about 6,350
    /// splits for 5M blocks, so a wide scan spent them all and left the rest as gaps. Every caller here filters by a
    /// specific address or the viewer's own wallet, so a wide range returns a small result set. Matches on the URL text
    /// rather than the host, like the web app's `CHUNK`.
    static func logChunkSize(for url: URL) -> UInt64 {
        let text = url.absoluteString
        if text.contains("127.0.0.1") || text.contains("localhost") { return 50_000 }
        if text.contains("rpc1") { return 100_000 }
        if text.contains("rpc3") || text.contains("rpc4") { return 1_000 }
        return 100
    }

    /// The chunk size for this endpoint; see `logChunkSize(for:)`.
    nonisolated var logChunkSize: UInt64 { Self.logChunkSize(for: url) }

    /// The most blocks one request may ask across all its `eth_getLogs` ranges, where an endpoint counts them together:
    /// rpc3 answers a batch's ranges while they add up to 1,000 blocks and refuses every range past that (-32062), however
    /// small, so there a round trip asks one 1,000-block range (`chunkedLogsReport`). Nil where each range counts on its
    /// own, as on rpc1, rpc4 and rpc.monad.xyz (measured 2026-09-29).
    static func logBatchSpan(for url: URL) -> UInt64? {
        url.absoluteString.contains("rpc3") ? 1_000 : nil
    }

    /// This endpoint's budget for one request; see `logBatchSpan(for:)`.
    nonisolated var logBatchSpan: UInt64? { Self.logBatchSpan(for: url) }

    nonisolated var isLocal: Bool {
        let host = url.host() ?? ""
        return host == "127.0.0.1" || host == "localhost"
    }

    /// The block a local Anvil fork started from (`anvil_metadata`), cached for the process; nil when the local node
    /// is not Anvil or is not a fork.
    func localForkBlock() async -> UInt64? {
        if let cached = await LocalForkInfo.shared.block(for: url) { return cached }
        let block: UInt64?
        if let json = try? await call("anvil_metadata"), let raw = json["forkedNetwork"]["forkBlockNumber"].number {
            block = UInt64(raw)
        } else {
            block = nil
        }
        await LocalForkInfo.shared.set(block, for: url)
        return block
    }

    /// One `eth_getLogs` request. The range must respect the endpoint's cap; use `chunkedLogs` for wider windows.
    func logs(_ filter: LogFilter) async throws -> [Log] {
        try Self.parseLogs(await call("eth_getLogs", [filter.json]))
    }

    /// Several `eth_getLogs` requests in one HTTP round trip. Each result fails on its own, so one rejected
    /// range never hides the others.
    func logs(_ filters: [LogFilter]) async throws -> [Result<[Log], RPCError>] {
        try await batch(filters.map { ("eth_getLogs", [$0.json]) }).map { result in
            result.flatMap { json in
                do { return .success(try Self.parseLogs(json)) } catch { return .failure(RPCError(code: -1, message: "Malformed log response")) }
            }
        }
    }

    /// Fetches logs over `[fromBlock, toBlock]` by splitting the window into ranges the endpoint accepts and
    /// sending `concurrency` ranges per round trip (fewer where the endpoint counts a request's ranges together,
    /// `logBatchSpan`). A range that fails is read again in smaller parts, as build 15 read it
    /// (`LogScanMode.patient`); what still can't be read leaves a gap rather than failing the whole window, exactly as the
    /// web app's `chunkedLogs` does, and the caller gets everything that could be read.
    func chunkedLogs(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6) async -> [Log] {
        await chunkedLogsReport(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunkSize, concurrency: concurrency).logs
    }

    /// `chunkedLogs`, saying whether the whole window was read: `complete` is false when a range was left as a gap, or the
    /// scan was cancelled or stopped part-way, so a caller can tell "nothing there" from "couldn't read it". A range the
    /// endpoint refuses for its size is read in smaller parts (`narrowedLogs`). A range refused for any other reason — an
    /// internal error, a throttle that outlasted the client's retries, no answer — is asked once more, then read as `mode`
    /// says (`LogScanMode`): patient, the default, in halves, as build 15 read it, until the endpoint has answered nothing
    /// for 45 s; fail-fast, for the wallet's history on Send and the Portfolio, left as a gap, and two rounds in a row with
    /// no range answered end the scan. Either way no endpoint can keep a scan going for hours (`LogScanLimits`).
    func chunkedLogsReport(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6,
                           mode: LogScanMode = .patient) async -> (logs: [Log], complete: Bool) {
        await chunkedLogsReport(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunkSize, concurrency: concurrency,
                                mode: mode, limits: LogScanLimits())
    }

    /// `chunkedLogsReport` within `limits`.
    internal func chunkedLogsReport(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6,
                                    mode: LogScanMode, limits: LogScanLimits) async -> (logs: [Log], complete: Bool) {
        // A local Anvil fork only holds logs from its fork block on (older ranges are forwarded upstream, where the
        // default RPC caps them at 100 blocks), so a development build scans the fork's own blocks only.
        var fromBlock = fromBlock
        if isLocal, let forkBlock = await localForkBlock() { fromBlock = max(fromBlock, forkBlock) }
        guard fromBlock <= toBlock else { return ([], true) }
        let chunk = max(1, chunkSize ?? logChunkSize)
        var ranges: [LogFilter] = []
        var start = fromBlock
        while start <= toBlock {
            let end = start + chunk - 1 > toBlock ? toBlock : start + chunk - 1
            ranges.append(LogFilter(address: address, topics: topics, fromBlock: start, toBlock: end))
            if end == UInt64.max { break }
            start = end + 1
        }
        var scan = LogScan(mode: mode, limits: limits)
        // A wallet-scoped filter (a topic beyond the event signature) is cheap for the wide-range endpoints however
        // far back it reaches: rpc1 answers one wallet's whole transfer history in about a second. Ask for the whole
        // window first, up to three times, and fall back to ranges only when the endpoint refuses it. A refusal for its
        // size is never sent again: the answer would be the same. rpc1 refuses a history of more than 10K logs (an active
        // trader's, or one an airdrop campaign spammed) and names the range from the same start it can answer: the
        // history is then read in such ranges, a request or two for each 10K logs, where 100,000-block ranges took more
        // than a thousand requests, minutes.
        if ranges.count > 1, chunk >= 100_000, topics.dropFirst().contains(where: { $0 != nil }) {
            let whole = LogFilter(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock)
            let answer = await logsAnswer(whole, tries: 3, scan: &scan)
            switch answer {
            case .logs(let found): return (found, true)
            case .tooLarge(_?): return await narrowedLogs(whole, after: answer, scan: &scan)
            case .tooLarge(nil), .failed: if Task.isCancelled || scan.down { return ([], false) }
            }
        }
        var out: [Log] = []
        var complete = true
        var next = 0
        var unanswered = 0
        // Ranges a round trip asks: `concurrency`, or as many as fit the endpoint's budget for one request.
        let perTrip = max(1, logBatchSpan.map { min(concurrency, Int(clamping: $0 / chunk)) } ?? concurrency)
        while next < ranges.count, !Task.isCancelled, !scan.down {
            let slice = Array(ranges[next..<min(next + perTrip, ranges.count)])
            next += slice.count
            var answered = false
            let answers = await rangeAnswers(slice, scan: &scan)
            for (filter, answer) in zip(slice, answers) {
                switch answer {
                case .logs(let logs):
                    out.append(contentsOf: logs)
                    answered = true
                case .tooLarge:
                    answered = true
                    let narrowed = await narrowedLogs(filter, after: answer, scan: &scan)
                    out.append(contentsOf: narrowed.logs)
                    complete = complete && narrowed.complete
                case .failed where mode == .patient:
                    // As build 15 read it: in halves, which a moment's outage, or a range too heavy for the endpoint to
                    // answer in time, lets through.
                    let narrowed = await narrowedLogs(filter, after: answer, scan: &scan)
                    out.append(contentsOf: narrowed.logs)
                    complete = complete && narrowed.complete
                case .failed:
                    complete = false
                }
            }
            guard mode == .failFast else { continue }
            unanswered = answered ? 0 : unanswered + 1
            if unanswered >= 2 { return (out, false) }
        }
        return (out, complete && next == ranges.count && !scan.down)
    }

    /// What the endpoint answered each of `filters`, in one round trip: those that failed for a reason other than their
    /// size are asked once more, together, 400 ms later.
    private func rangeAnswers(_ filters: [LogFilter], scan: inout LogScan) async -> [LogsAnswer] {
        var answers = await batchAnswers(filters, scan: &scan)
        let failed = answers.indices.filter { if case .failed = answers[$0] { return true }; return false }
        guard !failed.isEmpty, !Task.isCancelled, !scan.down else { return answers }
        try? await Task.sleep(for: .milliseconds(400))
        let again = await batchAnswers(failed.map { filters[$0] }, scan: &scan)
        for (k, i) in failed.enumerated() { answers[i] = again[k] }
        return answers
    }

    /// One range, asked again while it fails for a reason other than its size: `tries` times in all, 400 ms apart, then
    /// 800 ms.
    private func logsAnswer(_ filter: LogFilter, tries: Int = 2, scan: inout LogScan) async -> LogsAnswer {
        var answer = LogsAnswer.failed
        for attempt in 0..<max(1, tries) {
            if attempt > 0 {
                if Task.isCancelled || scan.down { break }
                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
            answer = await batchAnswers([filter], scan: &scan)[0]
            guard case .failed = answer else { break }
        }
        return answer
    }

    /// Each of `filters` asked once, in one round trip, and recorded in `scan`; every one failed when the request as a
    /// whole got no answer.
    private func batchAnswers(_ filters: [LogFilter], scan: inout LogScan) async -> [LogsAnswer] {
        let answers: [LogsAnswer]
        if let results = try? await logs(filters), results.count == filters.count {
            answers = zip(filters, results).map { filter, result in
                switch result {
                case .success(let logs): return .logs(logs)
                case .failure(let error):
                    return Self.refusesSize(error) ? .tooLarge(cut: Self.suggestedEnd(error, from: filter.fromBlock, to: filter.toBlock)) : .failed
                }
            }
        } else {
            answers = filters.map { _ in .failed }
        }
        scan.record(answers)
        return answers
    }

    /// Whether an `eth_getLogs` error refuses the range for its size — its block span, or how many logs it would return —
    /// which a smaller range fixes: rpc1's "Log response size exceeded" (-32602, its cap of 10K logs an answer),
    /// rpc.monad.xyz's "eth_getLogs is limited to a 100 range" (-32614), rpc3's "Block range is too large" (-32062), and
    /// the same said in other words. Never a throttle, an internal error or a node that can't serve the method: a smaller
    /// range doesn't reliably fix those, so only a patient scan splits a range for them, and within its limits
    /// (`LogScanLimits`): splitting every one sends thousands of requests that fail the same way.
    internal static func refusesSize(_ error: RPCError) -> Bool {
        let message = error.message.lowercased()
        let sizes = ["response size", "block range", "too large", "limited to a", "returned more than", "too many logs", "too many results"]
        if sizes.contains(where: message.contains) { return true }
        if isRateLimited(error) { return false }
        return error.code == -32614 || error.code == -32062
    }

    /// A range refused — for its size, or, patient, for any reason (`answer`) — read in parts down to 100 blocks (the cap
    /// of the default Monad RPC; 5 000 on a local node), each part refused again split again (`LogScan.divide`): where a
    /// size refusal says a range the endpoint can answer ends, else in halves. The endpoint's word is taken up to 200
    /// times a range (about 2M logs on rpc1), then halves only, so no endpoint can keep it splitting off a block at a time.
    /// Patient, a part that would be halved if it failed is asked once, after a pause while the endpoint isn't answering;
    /// every other part is asked twice. A part refused at the smallest size, or once the scan's splits are spent, is left
    /// as a gap, and the range is reported incomplete, as it is when the scan stops part-way.
    private func narrowedLogs(_ filter: LogFilter, after answer: LogsAnswer, scan: inout LogScan) async -> (logs: [Log], complete: Bool) {
        let floor: UInt64 = isLocal ? 5_000 : 100
        var cuts = 200
        guard !scan.down, let parts = scan.divide(filter, after: answer, cuts: &cuts, floor: floor) else { return ([], false) }
        var out: [Log] = []
        var complete = true
        // The parts still to read, the next one last, so the logs come out in block order.
        var pending = Array(parts.reversed())
        while let part = pending.popLast() {
            if Task.isCancelled || scan.down { return (out, false) }
            if scan.pause > 0 {
                try? await Task.sleep(for: .seconds(scan.pause))
                if Task.isCancelled { return (out, false) }
            }
            let reply = await logsAnswer(part, tries: scan.halvesFailures(part, floor: floor) ? 1 : 2, scan: &scan)
            switch reply {
            case .logs(let logs): out.append(contentsOf: logs)
            case .tooLarge, .failed:
                if let smaller = scan.divide(part, after: reply, cuts: &cuts, floor: floor) { pending += smaller.reversed() } else { complete = false }
            }
        }
        return (out, complete)
    }

    /// `filter`'s window in two: the first part ending at `cut` when that falls inside the window, else halves. Nil when
    /// the window is no wider than `floor` blocks.
    internal static func split(_ filter: LogFilter, at cut: UInt64? = nil, floor: UInt64) -> [LogFilter]? {
        guard filter.toBlock >= filter.fromBlock, filter.toBlock - filter.fromBlock + 1 > floor else { return nil }
        let half = filter.fromBlock + (filter.toBlock - filter.fromBlock + 1) / 2 - 1
        let end = cut.flatMap { (filter.fromBlock..<filter.toBlock).contains($0) ? $0 : nil } ?? half
        return [LogFilter(address: filter.address, topics: filter.topics, fromBlock: filter.fromBlock, toBlock: end),
                LogFilter(address: filter.address, topics: filter.topics, fromBlock: end + 1, toBlock: filter.toBlock)]
    }

    /// The last block of the range a size refusal says the endpoint can answer, when that range starts at `from` and ends
    /// before `to`: rpc1's refusal ends "this block range should work: [0x6000000, 0x6000b41]". Nil when it names none,
    /// or one that doesn't fit.
    internal static func suggestedEnd(_ error: RPCError, from: UInt64, to: UInt64) -> UInt64? {
        let message = error.message
        guard let open = message.lastIndex(of: "["), let close = message[open...].firstIndex(of: "]") else { return nil }
        let bounds = message[message.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, bounds.allSatisfy({ $0.count > 2 && $0.lowercased().hasPrefix("0x") }),
              let start = BigUInt(hexQuantity: bounds[0]), let end = BigUInt(hexQuantity: bounds[1]),
              start == BigUInt(from), end >= start, end < BigUInt(to), let cut = UInt64(exactly: end) else { return nil }
        return cut
    }

    /// Block number and timestamp, for anchoring event times without one `eth_getBlockByNumber` per log.
    func block(_ tag: BlockTag = .latest) async throws -> BlockHeader {
        let json = try await call("eth_getBlockByNumber", [tag.json, .bool(false)])
        guard let numberHex = json["number"].string, let number = BigUInt(hexQuantity: numberHex),
              let timestampHex = json["timestamp"].string, let timestamp = BigUInt(hexQuantity: timestampHex)
        else { throw NetworkError.malformedResponse }
        return BlockHeader(number: UInt64(clamping: number), timestamp: Int(clamping: timestamp))
    }

    /// The logs of a mined transaction, or nil while it is pending. Lets callers read events such as
    /// `TokenLaunched` out of their own receipts.
    func transactionLogs(_ hash: Data) async throws -> [Log]? {
        let json = try await call("eth_getTransactionReceipt", [.string(hash.hexString)])
        if json.isNull { return nil }
        return try Self.parseLogs(json["logs"])
    }

    private static func parseLogs(_ json: JSON) throws -> [Log] {
        guard let items = json.array else { throw NetworkError.malformedResponse }
        return try items.map { item in
            guard let log = Log(json: item) else { throw NetworkError.malformedResponse }
            return log
        }
    }
}


/// Process-wide cache of local fork blocks, keyed by endpoint (so every RPC client pointed at the fork shares one lookup).
actor LocalForkInfo {
    static let shared = LocalForkInfo()
    private var blocks: [URL: UInt64?] = [:]
    func block(for url: URL) -> UInt64?? { blocks[url] }
    func set(_ block: UInt64?, for url: URL) { blocks[url] = .some(block) }
}
