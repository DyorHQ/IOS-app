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
    /// (`RPCClient.refusesSize`). A smaller range is answered.
    case tooLarge
    /// Anything else: an internal error, a throttle that outlasted the client's retries, no answer. A smaller range
    /// wouldn't be answered either.
    case failed
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

    /// The block-range cap Monad's public endpoints enforce per `eth_getLogs` request: 100 blocks on
    /// rpc.monad.xyz, effectively unlimited on rpc1/rpc3 (they answer a full day's range in one ~2 s call, so the
    /// web app's cautious 1 000 was leaving ~50× the round trips on the table), and unlimited on a local fork.
    /// Every caller here filters by a specific address or the viewer's own wallet, so a wide range returns a small,
    /// un-truncated result set. Matches on the URL text rather than the host, like the web app's `CHUNK`.
    static func logChunkSize(for url: URL) -> UInt64 {
        let text = url.absoluteString
        if text.contains("127.0.0.1") || text.contains("localhost") { return 50_000 }
        if text.contains("rpc1") || text.contains("rpc3") { return 100_000 }
        return 100
    }

    /// The chunk size for this endpoint; see `logChunkSize(for:)`.
    nonisolated var logChunkSize: UInt64 { Self.logChunkSize(for: url) }

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
    /// sending `concurrency` ranges per round trip. A range that fails leaves a gap rather than failing the whole
    /// window, exactly as the web app's `chunkedLogs` does; the caller gets everything that could be read.
    func chunkedLogs(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6) async -> [Log] {
        await chunkedLogsReport(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunkSize, concurrency: concurrency).logs
    }

    /// `chunkedLogs`, saying whether the whole window was read: `complete` is false when a range was left as a gap, or the
    /// scan was cancelled or stopped part-way, so a caller can tell "nothing there" from "couldn't read it". A range the
    /// endpoint refuses for its size is read in smaller parts (`narrowedLogs`); a range refused for any other reason — an
    /// internal error, a throttle that outlasted the client's retries, no answer — is asked once more, then left as a gap,
    /// since a smaller range wouldn't fix it. Once two rounds in a row get no range answered, the endpoint is failing and
    /// the scan stops there, incomplete, rather than asking the rest of the window range by range.
    func chunkedLogsReport(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6) async -> (logs: [Log], complete: Bool) {
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
        // A wallet-scoped filter (a topic beyond the event signature) is cheap for the wide-range endpoints however
        // far back it reaches: rpc1 answers one wallet's whole transfer history in about a second. Ask for the whole
        // window first, up to three times, and fall back to ranges only when the endpoint refuses it. A refusal for its
        // size is never sent again: the answer would be the same.
        if ranges.count > 1, chunk >= 100_000, topics.dropFirst().contains(where: { $0 != nil }) {
            let whole = LogFilter(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock)
            if case .logs(let found) = await logsAnswer(whole, tries: 3) { return (found, true) }
            if Task.isCancelled { return ([], false) }
        }
        var out: [Log] = []
        var complete = true
        var next = 0
        var unanswered = 0
        while next < ranges.count, !Task.isCancelled {
            let slice = Array(ranges[next..<min(next + max(1, concurrency), ranges.count)])
            next += slice.count
            var answered = false
            for (filter, answer) in zip(slice, await rangeAnswers(slice)) {
                switch answer {
                case .logs(let logs):
                    out.append(contentsOf: logs)
                    answered = true
                case .tooLarge:
                    answered = true
                    let narrowed = await narrowedLogs(filter)
                    out.append(contentsOf: narrowed.logs)
                    complete = complete && narrowed.complete
                case .failed:
                    complete = false
                }
            }
            unanswered = answered ? 0 : unanswered + 1
            if unanswered >= 2 { return (out, false) }
        }
        return (out, complete && next == ranges.count)
    }

    /// What the endpoint answered each of `filters`, in one round trip: those that failed for a reason other than their
    /// size are asked once more, together, 400 ms later.
    private func rangeAnswers(_ filters: [LogFilter]) async -> [LogsAnswer] {
        var answers = await batchAnswers(filters)
        let failed = answers.indices.filter { if case .failed = answers[$0] { return true }; return false }
        guard !failed.isEmpty, !Task.isCancelled else { return answers }
        try? await Task.sleep(for: .milliseconds(400))
        let again = await batchAnswers(failed.map { filters[$0] })
        for (k, i) in failed.enumerated() { answers[i] = again[k] }
        return answers
    }

    /// One range, asked again while it fails for a reason other than its size: `tries` times in all, 400 ms apart, then
    /// 800 ms.
    private func logsAnswer(_ filter: LogFilter, tries: Int = 2) async -> LogsAnswer {
        var answer = LogsAnswer.failed
        for attempt in 0..<max(1, tries) {
            if attempt > 0 {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
            answer = await batchAnswers([filter])[0]
            guard case .failed = answer else { break }
        }
        return answer
    }

    /// Each of `filters` asked once, in one round trip; every one failed when the request as a whole got no answer.
    private func batchAnswers(_ filters: [LogFilter]) async -> [LogsAnswer] {
        guard let results = try? await logs(filters), results.count == filters.count else { return filters.map { _ in .failed } }
        return results.map { result in
            switch result {
            case .success(let logs): return .logs(logs)
            case .failure(let error): return Self.refusesSize(error) ? .tooLarge : .failed
            }
        }
    }

    /// Whether an `eth_getLogs` error refuses the range for its size — its block span, or how many logs it would return —
    /// which a smaller range fixes: rpc1's "Log response size exceeded" (-32602, its cap of 10K logs an answer),
    /// rpc.monad.xyz's "eth_getLogs is limited to a 100 range" (-32614), rpc3's "Block range is too large" (-32062), and
    /// the same said in other words. Never a throttle, an internal error or a node that can't serve the method: a smaller
    /// range doesn't fix those, and splitting a range for them sends thousands of requests that fail the same way.
    internal static func refusesSize(_ error: RPCError) -> Bool {
        let message = error.message.lowercased()
        let sizes = ["response size", "block range", "too large", "limited to a", "returned more than", "too many logs", "too many results"]
        if sizes.contains(where: message.contains) { return true }
        if isRateLimited(error) { return false }
        return error.code == -32614 || error.code == -32062
    }

    /// A range the endpoint refused for its size, retried in halves down to 100 blocks (the cap of the default Monad
    /// RPC; 5 000 on a local node), each half refused for its size split again. A part still refused at that size, or
    /// refused for another reason after one more try, is left as a gap, and the range is reported incomplete.
    private func narrowedLogs(_ filter: LogFilter) async -> (logs: [Log], complete: Bool) {
        let floor: UInt64 = isLocal ? 5_000 : 100
        guard let halves = Self.halves(filter, floor: floor) else { return ([], false) }
        var out: [Log] = []
        var complete = true
        // The parts still to read, the next one last, so the logs come out in block order.
        var pending = Array(halves.reversed())
        while let part = pending.popLast() {
            if Task.isCancelled { return (out, false) }
            switch await logsAnswer(part) {
            case .logs(let logs): out.append(contentsOf: logs)
            case .failed: complete = false
            case .tooLarge:
                if let split = Self.halves(part, floor: floor) { pending += split.reversed() } else { complete = false }
            }
        }
        return (out, complete)
    }

    /// `filter`'s window in two halves; nil when it is no wider than `floor` blocks.
    internal static func halves(_ filter: LogFilter, floor: UInt64) -> [LogFilter]? {
        guard filter.toBlock >= filter.fromBlock, filter.toBlock - filter.fromBlock + 1 > floor else { return nil }
        let mid = filter.fromBlock + (filter.toBlock - filter.fromBlock + 1) / 2
        return [LogFilter(address: filter.address, topics: filter.topics, fromBlock: filter.fromBlock, toBlock: mid - 1),
                LogFilter(address: filter.address, topics: filter.topics, fromBlock: mid, toBlock: filter.toBlock)]
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
