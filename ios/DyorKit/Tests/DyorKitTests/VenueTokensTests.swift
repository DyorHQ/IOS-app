import BigInt
import XCTest
@testable import DyorKit

/// The swap picker's venue list (`VenueTokensService`): every token that gained a pool on Uniswap v3, Monday Trade or
/// Uniswap v4, read from genesis in segments. Build 16 read it on rpc3 in ranges rpc3 refuses, and moved its checkpoint
/// past every segment, gaps and all, so tokens a gap hid never reached the list.
final class VenueTokensTests: XCTestCase {
    private let created = ABI.eventTopic("PoolCreated(address,address,uint24,int24,address)")
    private let initialized = ABI.eventTopic("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func token(_ n: UInt8) -> Address { Address(data: Data(repeating: 0, count: 19) + Data([n]))! }

    /// A pool for token `n` against WMON at `block`: on Uniswap v3, Monday Trade or Uniswap v4 by `n % 3`.
    private func pool(_ n: UInt8, at block: UInt64) -> Log {
        let word = { (address: Address) in address.data.leftPadded(to: 32) }
        let hash = Data(repeating: n, count: 32)
        switch n % 3 {
        case 0: return Log(address: Uniswap.v3Factory, topics: [created, word(token(n)), word(Monad.wmon), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        case 1: return Log(address: MondayTrade.factory, topics: [created, word(Monad.wmon), word(token(n)), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        default: return Log(address: Uniswap.poolManager, topics: [initialized, hash, word(Monad.native), word(token(n))], data: Data(count: 160),
                            blockNumber: block, transactionHash: hash, logIndex: 0)
        }
    }

    /// Every token answers its symbol ("T" and its number), name and 18 decimals; `breaking` tokens take down any
    /// metadata read that reaches them (`MomentsChainStub`).
    private func installMetadata(breaking: Set<Address> = []) {
        MomentsChainStub.install({ to, data in
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(18)], "uint8") }
            return nil
        }, breaking: breaking)
    }

    /// The service on the stubs. `concurrency` only makes a test quicker: it changes how many ranges share a round trip,
    /// never which ranges are asked.
    private func service(_ url: URL = LogsStub.url, concurrency: Int = 2) -> VenueTokensService {
        VenueTokensService(logsRPC: LogsStub.rpc(url: url), multicall: Multicall(rpc: MomentsChainStub.rpc()), concurrency: concurrency)
    }

    /// Every save a refresh made, in order.
    private actor Saves {
        private(set) var all: [(symbols: [String], checkpoint: UInt64, complete: Bool)] = []
        func record(_ progress: VenueTokensService.Progress) { all.append((progress.tokens.map(\.symbol), progress.checkpoint, progress.complete)) }
    }

    /// A segment read in part keeps what it found, but not its checkpoint: the refresh ends there, and the next one reads
    /// the segment again and finds what the gap hid, then reads on to the head.
    func testASegmentReadInPartKeepsItsCheckpointAndIsReadAgain() async throws {
        installMetadata()
        let pools = [pool(1, at: 1_000_000), pool(2, at: 6_000_000), pool(3, at: 7_000_000), pool(4, at: 11_000_000)]
        // An endpoint that refuses, at every size, any range holding block 7,000,000: a gap in the second segment.
        LogsStub.install(head: 12_000_000, logs: pools) { range in
            range.contains(7_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let saves = Saves()
        let firstRead = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let first = try XCTUnwrap(firstRead)
        let firstSaves = await saves.all
        XCTAssertEqual(firstSaves.map(\.checkpoint), [4_999_999, 4_999_999], "the first segment in full; the second in part, which moves nothing")
        XCTAssertEqual(firstSaves.map(\.complete), [false, false])
        XCTAssertEqual(firstSaves.last?.symbols, ["T1", "T2"], "what the second segment found is kept")
        XCTAssertEqual(first.checkpoint, 4_999_999)
        XCTAssertEqual(first.head, 12_000_000)
        XCTAssertFalse(first.complete)
        XCTAssertFalse(LogsStub.queries().contains { $0.to >= 10_000_000 }, "the refresh ends at the segment read in part")

        LogsStub.install(head: 12_000_000, logs: pools) { _ in nil }
        let secondRead = await service().refresh(tokens: first.tokens, checkpoint: first.checkpoint, logos: { [:] }) { await saves.record($0) }
        let second = try XCTUnwrap(secondRead)
        XCTAssertEqual(second.tokens.map(\.symbol), ["T1", "T2", "T3", "T4"], "the gap's token found, none twice")
        XCTAssertEqual(second.checkpoint, 12_000_000)
        XCTAssertTrue(second.complete)
        XCTAssertEqual(LogsStub.queries().map(\.from).min(), 5_000_000, "read again from the segment read in part")
        let secondSaves = await saves.all.dropFirst(firstSaves.count)
        XCTAssertEqual(secondSaves.map(\.checkpoint), [9_999_999, 12_000_000])
        XCTAssertEqual(secondSaves.map(\.complete), [false, true])
    }

    /// On an endpoint that answers 1,000 blocks a range, as rpc3 does, every venue is read in full and says so (a 5M-block
    /// segment: `LogScanTests.testAnEndpointThatAnswers1000BlocksReadsA5MBlockSegmentWithNoGap`).
    func testAnEndpointThatAnswers1000BlocksReadsEveryVenueInFull() async {
        installMetadata()
        let pools = [pool(3, at: 100_000_500), pool(4, at: 100_070_000), pool(5, at: 100_130_001), pool(6, at: 100_199_999)]
        LogsStub.install(head: 105_000_000, logs: pools) { range in
            range.span > 1_000 ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let scan = await service(LogsStub.rpc3, concurrency: 100).tokens(fromBlock: 100_000_000, toBlock: 100_199_999)
        XCTAssertTrue(scan.complete)
        XCTAssertFalse(scan.capped)
        XCTAssertEqual(Set(scan.tokens.map(\.symbol)), ["T3", "T4", "T5", "T6"])
        XCTAssertEqual(LogsStub.queries().count, 600, "three venues, 200 ranges each, none refused")
    }

    /// More tokens than a read keeps: the newest are kept and the read says so; a read of the same window that excludes
    /// them brings the rest, and a refresh makes that read at once, moving the checkpoint only once every one is in.
    func testMoreTokensThanAReadKeepsAreReadAgainAtOnce() async throws {
        installMetadata()
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(3, at: 20), pool(4, at: 30)]) { _ in nil }
        let first = await service().tokens(fromBlock: 0, toBlock: 1_000, limit: 2)
        XCTAssertTrue(first.complete)
        XCTAssertTrue(first.capped)
        XCTAssertEqual(first.tokens.map(\.symbol), ["T4", "T3"], "the newest first")
        let second = await service().tokens(fromBlock: 0, toBlock: 1_000, exclude: Set(first.tokens.map(\.address)), limit: 2)
        XCTAssertTrue(second.complete)
        XCTAssertFalse(second.capped)
        XCTAssertEqual(second.tokens.map(\.symbol), ["T1"])

        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }, limit: 2) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.tokens.map(\.symbol), ["T4", "T3", "T1"])
        XCTAssertEqual(read.checkpoint, 1_000)
        let saved = await saves.all
        XCTAssertEqual(saved.map(\.symbols), [["T4", "T3"], ["T4", "T3", "T1"]])
        XCTAssertEqual(saved.map(\.checkpoint), [0, 1_000], "the checkpoint waits for the second read")
    }

    /// A segment whose newest tokens have no readable symbol still reads the rest: the re-read leaves out what the read
    /// dropped, as it leaves out what it kept, so a segment full of such tokens can't hold the checkpoint for good.
    func testTokensWithNoSymbolDontHoldASegmentThatIsReadAgain() async throws {
        let (newest, next) = (token(4), token(3))
        MomentsChainStub.install { to, data in
            guard to != newest, to != next, data.prefix(4) == ABI.selector("symbol()") else { return nil }
            return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string")
        }
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(3, at: 20), pool(4, at: 30)]) { _ in nil }
        let first = await service().tokens(fromBlock: 0, toBlock: 1_000, limit: 2)
        XCTAssertTrue(first.complete)
        XCTAssertTrue(first.capped)
        XCTAssertTrue(first.tokens.isEmpty)
        XCTAssertEqual(first.dropped, [newest, next])
        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }, limit: 2) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.tokens.map(\.symbol), ["T1"])
        XCTAssertEqual(read.checkpoint, 1_000)
        let checkpoints = await saves.all.map(\.checkpoint)
        XCTAssertEqual(checkpoints, [0, 1_000], "the checkpoint waits for the read that leaves the dropped out")
    }

    /// A token whose metadata read got no answer isn't dropped for good: the read is incomplete, so the checkpoint stays
    /// and the segment is read again next time. One with no readable symbol is dropped, as it always was.
    func testAMetadataReadWithNoAnswerLeavesTheSegmentToBeReadAgain() async throws {
        installMetadata(breaking: [token(2)])
        LogsStub.install(head: 1_000, logs: [pool(1, at: 10), pool(2, at: 20)]) { _ in nil }
        let scan = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertFalse(scan.complete, "T2 took the read down")
        XCTAssertTrue(scan.tokens.isEmpty)
        let saves = Saves()
        let refreshed = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let read = try XCTUnwrap(refreshed)
        XCTAssertEqual(read.checkpoint, 0)
        XCTAssertFalse(read.complete)
        let checkpoints = await saves.all.map(\.checkpoint)
        XCTAssertEqual(checkpoints, [0])

        let unreadable = token(2)
        MomentsChainStub.install { to, data in
            guard to != unreadable, data.prefix(4) == ABI.selector("symbol()") else { return nil }
            return try! ABI.encode([.string("T1")], "string")
        }
        let readable = await service().tokens(fromBlock: 0, toBlock: 1_000)
        XCTAssertTrue(readable.complete, "a token with no symbol is dropped, not unread")
        XCTAssertEqual(readable.tokens.map(\.symbol), ["T1"])
    }

    /// A head that couldn't be read reads nothing and says so; a list already at the head reads nothing and is complete.
    func testNothingIsReadWithoutAHead() async throws {
        installMetadata()
        LogsStub.install(head: 0) { _ in nil }
        let none = await service().refresh(tokens: [], checkpoint: 0, logos: { [:] }) { _ in XCTFail("nothing to save") }
        XCTAssertNil(none)
        LogsStub.install(head: 500) { _ in nil }
        let atHeadRead = await service().refresh(tokens: [], checkpoint: 500, logos: { [:] }) { _ in XCTFail("nothing to save") }
        let atHead = try XCTUnwrap(atHeadRead)
        XCTAssertTrue(atHead.complete)
        XCTAssertTrue(LogsStub.queries().isEmpty)
    }

    /// The app reads the venues on rpc1, two ranges at a time for each, and reads the whole history once more: the list
    /// is kept, and the checkpoint is a new one, since build 16's moved past gaps, under a key that can't mark the install
    /// as earlier than App Lock's default (`AppSettings`, security audit 2026-09-26, IOSK-4). The swap picker says while
    /// the list is short.
    func testTheAppReadsTheVenuesOnRpc1AndReadsTheirHistoryOnceMore() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let environment = try String(contentsOf: app.appendingPathComponent("App/AppEnvironment.swift"), encoding: .utf8)
        XCTAssertTrue(environment.contains("venueTokens = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC), multicall: multicall)"))
        XCTAssertFalse(environment.contains("rpc3.monad.xyz"), "no scan on rpc3")
        XCTAssertTrue(environment.contains("let read = await venueTokens.refresh(tokens: VenueTokenStore.all(), checkpoint: checkpoint,"),
                      "the checkpoint moves only past a segment read in full")
        XCTAssertTrue(environment.contains("VenueTokenStore.save(progress.tokens, lastBlock: progress.checkpoint)"))
        XCTAssertTrue(environment.contains("venueListCatchingUp = checkpoint == 0"))
        XCTAssertTrue(environment.contains("await MainActor.run { self.venueListCatchingUp = !progress.complete }"))
        XCTAssertTrue(environment.contains("if let read { venueListCatchingUp = !read.complete }"))
        XCTAssertEqual(LaunchpadService.defaultLogsRPC.absoluteString, "https://rpc1.monad.xyz")
        let service = try String(contentsOf: ios.appendingPathComponent("DyorKit/Sources/DyorKit/Services/VenueTokensService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("public init(logsRPC: RPCClient, multicall: Multicall, concurrency: Int = 2)"))

        let store = try String(contentsOf: app.appendingPathComponent("Wallet/VenueTokenStore.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("private static let key = \"venueTokens.v1\""), "the list is kept")
        XCTAssertTrue(store.contains("private static let blockKey = \"venueScan.v2.lastBlock\""), "a new checkpoint: the history read once more")
        XCTAssertFalse(store.contains("\"venueTokens.v1.lastBlock\""), "build 16's checkpoint is never read, nor written")
        // R4: every key the store names, beyond build 16's list and stamp, is outside the prefixes that mark an earlier
        // install.
        let theme = try String(contentsOf: app.appendingPathComponent("Design/Theme.swift"), encoding: .utf8)
        let earlierRun = try XCTUnwrap(theme.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = theme[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("venueTokens."), "\(prefixes)")
        let keys = store.components(separatedBy: "\n").filter { $0.contains("Key = \"") || $0.contains("key = \"") }
            .compactMap { line in line.split(separator: "\"").dropFirst().first.map(String.init) }
        XCTAssertEqual(keys, ["venueTokens.v1", "venueTokens.v1.updatedAt", "venueScan.v2.lastBlock"])
        for key in keys.dropFirst(2) { XCTAssertFalse(prefixes.contains { key.hasPrefix($0) }, "\(key) would mark a fresh install as earlier (R4)") }

        let swap = try String(contentsOf: app.appendingPathComponent("Swap/SwapView.swift"), encoding: .utf8)
        XCTAssertTrue(swap.contains("private var venueListCatchingUp: Bool { !query.isEmpty && env.venueListCatchingUp }"), "said only while searching")
        XCTAssertTrue(swap.contains("if venueListCatchingUp { Text(\"Monad's token list is still loading, so a token may be missing for now.\") }"))
    }

    /// A fresh install's first read, live on Monad (read-only): every venue from genesis on rpc1, and the metadata on the
    /// app's endpoints, as the app reads them. Prints the time and every request sent, by host and method. Runs only when
    /// DYOR_LIVE_VENUES=1 (network, several minutes).
    func testAFreshInstallReadsEveryVenueInFullLive() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_VENUES"] == "1" else { throw XCTSkip("set DYOR_LIVE_VENUES=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingForwarder.self]
        let session = URLSession(configuration: configuration)
        let service = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC, session: session),
                                         multicall: Multicall(rpc: RPCClient(urls: Monad.publicRPCs, session: session, maxBatch: 40)))
        CountingForwarder.reset()
        let started = Date()
        let saves = Saves()
        let live = await service.refresh(tokens: [], checkpoint: 0, logos: { [:] }) { await saves.record($0) }
        let result = try XCTUnwrap(live)
        let seconds = Int(Date().timeIntervalSince(started))
        let saved = await saves.all
        print("VENUES \(result.tokens.count) tokens, checkpoint \(result.checkpoint) of head \(result.head), \(saved.count) saves, \(seconds) s")
        let counts = CountingForwarder.counts()
        for name in counts.keys.sorted() { print("VENUES \(name): \(counts[name] ?? 0)") }
        XCTAssertTrue(result.complete, "read to the head in full")
        XCTAssertTrue(result.tokens.contains { $0.symbol == "QT" }, "QT, on its Monday Trade pool")
    }
}

/// Real requests, passed through and counted (`VenueTokensTests`' live read): each HTTP request as "<host> http", and
/// each JSON-RPC call in it as "<host> <method>".
final class CountingForwarder: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tally: [String: Int] = [:]
    private static let forward = URLSession(configuration: .ephemeral)
    private var forwarding: URLSessionDataTask?

    static func reset() { lock.lock(); tally = [:]; lock.unlock() }
    static func counts() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return tally }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var forwarded = request
        let body = Self.body(request)
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body
        forwarded.setValue(nil, forHTTPHeaderField: "Content-Length")
        let decoded = (try? JSONDecoder().decode(JSON.self, from: body)) ?? .null
        let host = request.url?.host() ?? "?"
        Self.lock.lock()
        Self.tally["\(host) http", default: 0] += 1
        for call in decoded.array ?? [decoded] { Self.tally["\(host) \(call["method"].string ?? "?")", default: 0] += 1 }
        Self.lock.unlock()
        forwarding = Self.forward.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            if let error { self.client?.urlProtocol(self, didFailWithError: error) } else { self.client?.urlProtocolDidFinishLoading(self) }
        }
        forwarding?.resume()
    }

    override func stopLoading() { forwarding?.cancel() }

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
