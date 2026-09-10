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
        guard fromBlock <= toBlock else { return [] }
        let chunk = max(1, chunkSize ?? logChunkSize)
        var ranges: [LogFilter] = []
        var start = fromBlock
        while start <= toBlock {
            let end = start + chunk - 1 > toBlock ? toBlock : start + chunk - 1
            ranges.append(LogFilter(address: address, topics: topics, fromBlock: start, toBlock: end))
            if end == UInt64.max { break }
            start = end + 1
        }
        var out: [Log] = []
        var next = 0
        while next < ranges.count, !Task.isCancelled {
            let slice = Array(ranges[next..<min(next + max(1, concurrency), ranges.count)])
            next += slice.count
            guard let results = try? await logs(slice) else { continue }
            for case .success(let logs) in results { out.append(contentsOf: logs) }
        }
        return out
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
