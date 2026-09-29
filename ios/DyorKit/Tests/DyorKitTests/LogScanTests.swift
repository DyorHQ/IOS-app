import BigInt
import XCTest
@testable import DyorKit

/// How a window of logs is read in ranges (`RPCClient.chunkedLogsReport`), as the wallet's history is: a range refused
/// for its size is read in smaller parts; a range refused for any other reason is asked once more, then left as a gap and
/// said; and an endpoint that answers the chain head but no range ends the scan in a few requests. It used to split every
/// failed range down to 100 blocks, one request at a time: about 3.3 million requests for the whole history, hours
/// during which the Send sheet read "Reading your wallet…".
final class LogScanTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    /// A transfer of `token` into the wallet at `block`.
    private func transfer(at block: UInt64) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: Int(block % 7))
    }

    /// The finding: rpc1 answers the chain head (108.8M blocks) but fails every getLogs, with an internal error or no
    /// answer at all. The scan ends at once, incomplete: the whole window asked three times, then two rounds of six ranges,
    /// each asked twice, and no range split.
    func testAnEndpointThatAnswersNoRangeEndsTheScanInAFewRequests() async {
        for failure in [LogsStub.Failure.error(code: -32603, message: "Internal error"), .noAnswer] {
            LogsStub.install(head: 108_800_000) { _ in failure }
            let discovery = WalletTokenDiscovery(logsRPC: LogsStub.rpc(), multicall: Multicall(rpc: LogsStub.rpc()))
            let started = Date()
            let scan = await discovery.scan(wallet: wallet, wholeHistory: true)
            XCTAssertEqual(scan, WalletTokenDiscovery.Scan(tokens: [], complete: false), "\(failure)")
            let asked = LogsStub.queries()
            XCTAssertEqual(asked.count, 27, "\(failure): 3 for the whole window, then 2 rounds of 6 ranges, each asked twice")
            XCTAssertEqual(asked.prefix(3).map(\.span), [108_800_001, 108_800_001, 108_800_001])
            XCTAssertTrue(asked.dropFirst(3).allSatisfy { $0.span == 100_000 }, "\(failure): no range split for a failure a smaller range wouldn't fix")
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }

    /// A range refused for its size is read in halves, each refused half halved again, and every log comes back in block
    /// order.
    func testARangeRefusedForItsSizeIsReadInHalves() async {
        let blocks: [UInt64] = [5, 40_000, 99_999, 100_000, 180_000, 250_000]
        LogsStub.install(head: 300_000, logs: blocks.map(transfer)) { range in
            range.span > 30_000 ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 299_999)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), blocks)
        XCTAssertTrue(LogsStub.queries().allSatisfy { $0.span >= 25_000 }, "halved only until the endpoint answers")
    }

    /// A range refused for another reason is asked once more, then left as a gap and said, never split; the rest of the
    /// window is read.
    func testARangeRefusedForAnotherReasonIsAskedOnceMoreThenLeftAsAGap() async {
        LogsStub.install(head: 300_000, logs: [5, 150_000, 250_000].map(transfer)) { range in
            range.contains(150_000) ? .error(code: -32603, message: "Internal error") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 260_000)
        XCTAssertFalse(report.complete, "a gap is said")
        XCTAssertEqual(report.logs.map(\.blockNumber), [5, 250_000])
        let failing = LogsStub.queries().filter { $0.contains(150_000) }
        XCTAssertEqual(failing, [LogsStub.Range(from: 100_000, to: 199_999), LogsStub.Range(from: 100_000, to: 199_999)])
    }

    /// rpc1 refuses a wallet's whole history when it holds more than 10K logs: that refusal is not sent again, as it used
    /// to be three times over, and the window is read in ranges.
    func testAWholeHistoryRefusedForItsSizeIsNotSentAgain() async {
        let blocks: [UInt64] = [7, 120_000, 399_999]
        LogsStub.install(head: 400_000, logs: blocks.map(transfer)) { range in
            range.span > 150_000 ? .error(code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 1,000 block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response.") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 400_000)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), blocks)
        XCTAssertEqual(LogsStub.queries().filter { $0.span > 150_000 }.count, 1, "the whole window asked once")
    }

    /// The size refusals of Monad's endpoints, read live on 2026-09-29, and errors a smaller range doesn't fix.
    func testWhichRefusalsASmallerRangeFixes() {
        let size = [
            RPCError(code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 1,000 block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response. Based on your parameters and the response size limit, this block range should work: [0x6000000, 0x6000b41]"),
            RPCError(code: -32614, message: "eth_getLogs is limited to a 100 range"),
            RPCError(code: -32062, message: "Block range is too large"),
            RPCError(code: -32005, message: "query returned more than 10000 results"),
        ]
        for error in size { XCTAssertTrue(RPCClient.refusesSize(error), error.message) }
        let other = [
            RPCError(code: -32603, message: "Internal error"),
            RPCError(code: -32000, message: "header not found"),
            RPCError(code: 429, message: "Too Many Requests"),
            RPCError(code: -32005, message: "rate limit exceeded"),
            RPCError(code: -32602, message: "Invalid params"),
            RPCError(code: -1, message: "Malformed log response"),
        ]
        for error in other { XCTAssertFalse(RPCClient.refusesSize(error), error.message) }
    }
}

/// An `eth_getLogs` endpoint answered from memory, named like rpc1 so ranges are 100,000 blocks: the chain head is
/// `head`, every range asked is recorded (`queries()`), and `rule` refuses a range (an error, or no answer to the whole
/// request) or lets it be answered from `logs`.
final class LogsStub: URLProtocol {
    struct Range: Hashable, Sendable {
        let from: UInt64
        let to: UInt64
        var span: UInt64 { to - from + 1 }
        func contains(_ block: UInt64) -> Bool { (from...to).contains(block) }
    }

    enum Failure: Sendable, CustomStringConvertible {
        case error(code: Int, message: String)
        /// No answer to the request that asked it: the connection fails.
        case noAnswer
        var description: String {
            switch self {
            case .error(let code, let message): return "\(code) \(message)"
            case .noAnswer: return "no answer"
            }
        }
    }

    typealias Rule = @Sendable (Range) -> Failure?

    static let url = URL(string: "https://rpc1.logs-stub.invalid")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var head: UInt64 = 0
    nonisolated(unsafe) private static var chainLogs: [Log] = []
    nonisolated(unsafe) private static var rule: Rule = { _ in nil }
    nonisolated(unsafe) private static var asked: [Range] = []

    static func install(head: UInt64, logs: [Log] = [], rule: @escaping Rule) {
        lock.lock(); defer { lock.unlock() }
        self.head = head
        chainLogs = logs
        self.rule = rule
        asked = []
    }

    /// Every range asked, in order.
    static func queries() -> [Range] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    static func rpc() -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return RPCClient(url: url, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let decoded = (try? JSONDecoder().decode(JSON.self, from: Self.body(request))) ?? .null
        let calls = decoded.array ?? [decoded]
        // Every call is recorded, even in a request that is to get no answer.
        let answers = calls.map(Self.reply)
        let replies = answers.compactMap { $0 }
        guard replies.count == answers.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The answer to one call; nil when the request is to get no answer at all.
    private static func reply(_ call: JSON) -> JSON? {
        let id = call["id"]
        func result(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        func error(_ code: Int, _ message: String) -> JSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
        }
        lock.lock(); let head = self.head; let logs = chainLogs; let rule = self.rule; lock.unlock()
        switch call["method"].string {
        case "eth_getBlockByNumber":
            return result(.object(["number": .string(BigUInt(head).hexQuantity), "timestamp": .string(BigUInt(1_790_000_000).hexQuantity)]))
        case "eth_getLogs":
            let filter = call["params"][0]
            let from = filter["fromBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? 0
            let to = filter["toBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? head
            let range = Range(from: from, to: to)
            lock.lock(); asked.append(range); lock.unlock()
            switch rule(range) {
            case .error(let code, let message)?: return error(code, message)
            case .noAnswer?: return nil
            case nil: break
            }
            let address = filter["address"].string.flatMap(Address.init)
            let topics = (filter["topics"].array ?? []).map { $0.string.flatMap { Data(hex: $0) } }
            let matching = logs.filter { log in
                (address == nil || address == log.address) && range.contains(log.blockNumber)
                    && topics.enumerated().allSatisfy { i, topic in topic == nil || (log.topics.indices.contains(i) && log.topics[i] == topic) }
            }
            return result(.array(matching.map(json)))
        default:
            return error(-32601, "Method not found")
        }
    }

    private static func json(_ log: Log) -> JSON {
        .object(["address": .string(log.address.hex), "topics": .array(log.topics.map { .string($0.hexString) }), "data": .string(log.data.hexString),
                 "blockNumber": .string(BigUInt(log.blockNumber).hexQuantity), "transactionHash": .string(log.transactionHash.hexString),
                 "logIndex": .string(BigUInt(log.logIndex).hexQuantity)])
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
