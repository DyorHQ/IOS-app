import BigInt
import XCTest
@testable import DyorKit

/// How a window of logs is read across the public endpoints (`LogsRouter`): in ranges of what each answers, learning a
/// lower cap from a refusal, resting an endpoint that throttles and moving to the next, within a budget, and saying
/// exactly which blocks were read.
final class LogsRouterTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }

    private static let wide = URL(string: "https://wide.logs-stub.invalid")!
    private static let narrow = URL(string: "https://narrow.logs-stub.invalid")!
    private static let last = URL(string: "https://last.logs-stub.invalid")!

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    /// A transfer of `token` into the wallet at `block`.
    private func transfer(at block: UInt64) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: Int(block % 7))
    }

    private var query: LogsQuery { LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]) }

    /// A router over three stub endpoints: one answering 10,000 blocks in batches of 6, one 1,000 one range a request,
    /// one 100.
    private func router(gate: LogsGate = LogsGate(inFlight: 8, interval: .zero), concurrency: Int = 4, store: (any LogsCapabilityStore)? = nil) -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: Self.wide, span: 10_000), LogsEndpoint(url: Self.narrow, span: 1_000, batch: 1), LogsEndpoint(url: Self.last, span: 100)],
                          session: URLSession(configuration: configuration), gate: gate, store: store, concurrency: concurrency)
    }

    /// A 60,000-block window is read in six 10,000-block ranges, one request, every block covered, the logs in block order.
    func testAWindowIsReadInTheRangesTheEndpointAnswers() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 45_000), transfer(at: 41_000), transfer(at: 99_000)]) { _ in nil }
        let read = await router().read(query, from: 40_001, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertEqual(read.covered, [40_001...100_000])
        XCTAssertTrue(read.covers(40_001, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [41_000, 45_000, 99_000])
        XCTAssertEqual(read.requests, 1)
        XCTAssertEqual(LogsStub.queries().count, 6)
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"])
    }

    /// A range refused for its size, naming what the endpoint answers ("limited to a 1,000 range"), lowers that endpoint's
    /// span for the rest of the scan and is read again in ranges of that size; the span is remembered.
    func testARefusalNamingTheCapLowersTheSpanAndTheRangeIsReadAgain() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.span > 1_000 ? .error(code: -32614, message: "eth_getLogs is limited to a 1,000 range") : nil
        }) { _ in nil }
        let store = MemoryCapabilityStore()
        let router = router(store: store)
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 1_000)
        XCTAssertEqual(store.span(for: Self.wide), 1_000)
        XCTAssertTrue(LogsStub.queries().dropFirst().allSatisfy { $0.span <= 1_000 }, "every range after the refusal fits the cap")
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"], "the same endpoint reads on, smaller")
    }

    /// A refusal that names nothing halves the span, down to the floor; one at the floor rests the endpoint, and the next
    /// endpoint reads the range.
    func testARefusalAtTheFloorMovesToTheNextEndpoint() async {
        LogsStub.install(head: 2_000, logs: [transfer(at: 1_500)], hostRule: { host, _ in
            host == "wide.logs-stub.invalid" ? .error(code: -32602, message: "block range too large") : nil
        }) { _ in nil }
        let read = await router().read(query, from: 1_001, to: 2_000, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertTrue(read.covers(1_001, 2_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [1_500])
        XCTAssertTrue(LogsStub.hosts().contains("narrow.logs-stub.invalid"), "the narrow endpoint read it")
    }

    /// A range refused for how many logs it holds ("query returned more than 10000 results") is a dense range, not a
    /// narrow endpoint: it is read again in halves on the same endpoint, whose span is neither lowered nor remembered
    /// lower.
    func testARefusalForTooManyLogsSplitsTheRangeAndKeepsTheSpan() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500), transfer(at: 12_000)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.contains(19_500) && range.span > 2_000 ? .error(code: -32005, message: "query returned more than 10000 results") : nil
        }) { _ in nil }
        let store = MemoryCapabilityStore()
        let router = router(store: store)
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [12_000, 19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 10_000, "a dense range is no lesson about the endpoint")
        XCTAssertNil(store.span(for: Self.wide))
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"], "the same endpoint reads the halves")
    }

    /// A refusal naming an absurd span (a hostile endpoint) names no cut: the range is halved, never an overflow.
    func testARefusalNamingAnAbsurdSpanIsHalved() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.span > 5_000 ? .error(code: -32614, message: "eth_getLogs is limited to a 18446744073709551615 range") : nil
        }) { _ in nil }
        let router = router()
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 5_000)
    }

    /// A scan cancelled (its screen closed) blames no endpoint for the requests cut short: nothing rests, and the next
    /// scan reads on the same endpoint at once.
    func testACancelledScanRestsNoEndpoint() async {
        LogsStub.install(head: 100_000, latency: 0.3) { _ in nil }
        let router = router()
        let cancelled = Task { await router.read(query, from: 1, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10)) }
        try? await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        _ = await cancelled.value
        let stats = await router.stats()
        XCTAssertEqual(stats["wide.logs-stub.invalid"]?.rests ?? 0, 0)
        XCTAssertEqual(stats["wide.logs-stub.invalid"]?.failed ?? 0, 0)
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000)]) { _ in nil }
        let read = await router.read(query, from: 1, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertTrue(read.covers(1, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [50_000])
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"])
    }

    /// An endpoint that throttles (HTTP 429) rests, and the next endpoint reads the window; nothing is left unread.
    func testAThrottledEndpointRestsAndTheNextOneReads() async {
        LogsStub.install(head: 5_000, logs: [transfer(at: 4_500), transfer(at: 1_200)], hostRule: { host, _ in
            host == "wide.logs-stub.invalid" ? .status(429) : nil
        }) { _ in nil }
        let read = await router().read(query, from: 1_001, to: 5_000, budget: LogsBudget(requests: 40, seconds: 30))
        XCTAssertTrue(read.covers(1_001, 5_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [1_200, 4_500])
        let hosts = LogsStub.hosts()
        XCTAssertTrue(hosts.contains("narrow.logs-stub.invalid"))
        XCTAssertLessThanOrEqual(hosts.filter { $0 == "wide.logs-stub.invalid" }.count, 3, "the throttled endpoint is waited for while its rests are short, then left to rest")
    }

    /// Past its budget of requests a scan stops and says exactly what it read: ascending, the blocks from the start;
    /// descending, the blocks down from the end.
    func testTheBudgetBoundsTheScanAndCoverageSaysWhatWasRead() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 10_500), transfer(at: 195_000)]) { _ in nil }
        let up = await router(concurrency: 1).read(query, from: 1, to: 200_000, budget: LogsBudget(requests: 2, seconds: 10))
        XCTAssertEqual(up.requests, 2)
        XCTAssertEqual(up.covered, [1...120_000], "two requests of six 10,000-block ranges")
        XCTAssertEqual(up.through(from: 1), 120_000)
        XCTAssertFalse(up.covers(1, 200_000))
        XCTAssertEqual(up.logs.map(\.blockNumber), [10_500])

        LogsStub.install(head: 200_000, logs: [transfer(at: 10_500), transfer(at: 195_000)]) { _ in nil }
        let down = await router(concurrency: 1).read(query, from: 1, to: 200_000, order: .descending, budget: LogsBudget(requests: 2, seconds: 10))
        XCTAssertEqual(down.covered, [80_001...200_000])
        XCTAssertEqual(down.downTo(200_000), 80_001)
        XCTAssertNil(down.through(from: 1))
        XCTAssertEqual(down.logs.map(\.blockNumber), [195_000])
    }

    /// Batches run in parallel, but never more than the gate allows in flight.
    func testTheGateBoundsRequestsInFlight() async {
        LogsStub.install(head: 600_000, latency: 0.05) { _ in nil }
        let gate = LogsGate(inFlight: 2, interval: .zero)
        let read = await router(gate: gate, concurrency: 4).read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30))
        XCTAssertTrue(read.covers(1, 600_000))
        XCTAssertEqual(read.requests, 10)
        XCTAssertLessThanOrEqual(LogsStub.maxInFlight(), 2)
    }

    /// A range that every endpoint fails is left as a gap after its attempts, and the window is reported as not covered.
    func testARangeNoEndpointAnswersIsAGap() async {
        LogsStub.install(head: 30_000, logs: [transfer(at: 5_000)], hostRule: { _, range in range.contains(15_000) ? .noAnswer : nil }) { _ in nil }
        let read = await router().read(query, from: 1, to: 30_000, budget: LogsBudget(requests: 60, seconds: 30))
        XCTAssertFalse(read.covers(1, 30_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [5_000])
        XCTAssertTrue(read.covered.contains { $0.lowerBound == 1 }, "what was answered is covered")
    }

    /// A client built on the router reads its scans through it, and `complete` is whether the window was covered.
    func testAClientOnTheRouterScansThroughIt() async {
        LogsStub.install(head: 25_000, logs: [transfer(at: 24_000)]) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let client = RPCClient(logsRouter: router(), session: URLSession(configuration: configuration))
        let report = await client.chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 1, toBlock: 25_000, mode: .patient)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [24_000])
        let head = try? await client.blockNumber()
        XCTAssertEqual(head, 25_000, "head reads go to the router's endpoints")
    }

    /// A query's lists: several addresses and several topics at a position go out as the method's arrays, and match as
    /// the endpoint matches them.
    func testAQueryWithListsIsSentAndMatchedAsLists() async throws {
        let other = Address(literal: "0x8888888888888888888888888888888888888888")
        let outgoing = Log(address: other, topics: [transferTopic, walletWord, Data(repeating: 1, count: 32)], data: BigUInt(1).word, blockNumber: 50, transactionHash: Data(repeating: 9, count: 32), logIndex: 0)
        LogsStub.install(head: 100, logs: [transfer(at: 40), outgoing, Log(address: Address(literal: "0x9999999999999999999999999999999999999999"), topics: [transferTopic, walletWord], data: Data(), blockNumber: 60, transactionHash: Data(repeating: 8, count: 32), logIndex: 0)]) { _ in nil }
        let query = LogsQuery(addresses: [token, other], topics: [[transferTopic], [walletWord, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32)]])
        let read = await router().read(query, from: 1, to: 100, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertEqual(read.logs.map(\.blockNumber), [40, 50], "both addresses, either topic; the third log's address isn't listed")
        let json = query.json(from: 1, to: 100)
        XCTAssertEqual(json["address"].array?.count, 2)
        XCTAssertEqual(json["topics"][1].array?.count, 2)
        XCTAssertEqual(json["topics"][0].string, transferTopic.hexString, "a single topic goes out as one, not a list")
        XCTAssertTrue(query.matches(outgoing))
        XCTAssertFalse(query.matches(transfer(at: 1).replacing(address: Address(literal: "0x9999999999999999999999999999999999999999"))))
    }

    func testCoverageMergesTouchingRanges() {
        XCTAssertEqual(LogsRead.merge([50...60, 1...10, 11...20, 30...40, 35...55]), [1...20, 30...60])
        XCTAssertEqual(LogsRead.merge([]), [])
        let read = LogsRead(logs: [], covered: [1...20, 30...60], requests: 0)
        XCTAssertTrue(read.covers(5, 20)); XCTAssertFalse(read.covers(5, 30)); XCTAssertTrue(read.covers(30, 60))
        XCTAssertEqual(read.through(from: 1), 20); XCTAssertNil(read.through(from: 25)); XCTAssertEqual(read.downTo(60), 30)
        XCTAssertEqual(LogsRouter.namedSpan(RPCError(code: -32614, message: "eth_getLogs is limited to a 1,000 range")), 1_000)
        XCTAssertEqual(LogsRouter.namedSpan(RPCError(code: -32614, message: "eth_getLogs is limited to a 100 range")), 100)
        XCTAssertNil(LogsRouter.namedSpan(RPCError(code: -32602, message: "block range too large")))
    }
}

/// A capability store in memory.
final class MemoryCapabilityStore: LogsCapabilityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [URL: UInt64] = [:]
    func span(for url: URL) -> UInt64? { lock.lock(); defer { lock.unlock() }; return spans[url] }
    func set(span: UInt64, for url: URL) { lock.lock(); spans[url] = span; lock.unlock() }
}

private extension Log {
    func replacing(address: Address) -> Log {
        Log(address: address, topics: topics, data: data, blockNumber: blockNumber, transactionHash: transactionHash, logIndex: logIndex)
    }
}
