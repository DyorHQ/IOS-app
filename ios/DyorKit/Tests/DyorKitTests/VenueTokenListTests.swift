import BigInt
import XCTest
@testable import DyorKit

/// The venue list as the app holds it (`VenueTokenList`): read from the store once and kept in memory, so the swap
/// picker's search never decodes 1.8 MB of JSON on the main thread (four times a render, 0.1–0.15 s each); saved only
/// past a segment read in full, in the format build 16 reads.
@MainActor
final class VenueTokenListTests: XCTestCase {
    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    func testTheListIsReadOnceKeptInMemoryAndSavedOnlyPastASegmentReadInFull() async throws {
        VenueFixture.installMetadata()
        // Build 16's list, and no checkpoint of build 17's: the history is read once more.
        let store = MemoryStore(list: [VenueFixture.token(50, symbol: "T50")], checkpoint: 0)
        let gap = Flag(true)
        // T3 on Uniswap v3 is read in the second segment; its range past block 8,000,000 isn't answered, a gap.
        LogsStub.install(head: 12_000_000, logs: [VenueFixture.pool(1, at: 1_000_000), VenueFixture.pool(3, at: 7_000_000), VenueFixture.pool(4, at: 11_000_000)]) { range in
            gap.on && range.contains(8_000_000) ? .error(code: -32062, message: "Block range is too large") : nil
        }
        let list = store.list()
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.tokens.map(\.symbol), ["T50", "T1", "T3"], "what the segment read in part found is shown")
        XCTAssertEqual(list.checkpoint, 4_999_999)
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999], "saved past the first segment only")
        XCTAssertEqual(store.writes.last?.symbols, ["T50", "T1"])
        XCTAssertEqual(store.reads, 1)

        gap.set(false)
        list.refresh()
        await list.finished()
        XCTAssertEqual(list.tokens.map(\.symbol), ["T50", "T1", "T3", "T4"])
        XCTAssertEqual(store.writes.map(\.checkpoint), [4_999_999, 9_999_999, 12_000_000])
        XCTAssertEqual(store.reads, 1, "the store is read once")
        // Build 16 reads what is saved: a JSON array of `Token`.
        let saved = try JSONDecoder().decode([Token].self, from: try XCTUnwrap(store.data))
        XCTAssertEqual(saved, list.tokens)
    }

    func testOneRunAtATime() async {
        VenueFixture.installMetadata()
        let store = MemoryStore(list: [], checkpoint: 0)
        LogsStub.install(head: 1_000, logs: [VenueFixture.pool(1, at: 10)], latency: 0.01) { _ in nil }
        let list = store.list()
        list.refresh()
        list.refresh()
        XCTAssertTrue(list.isRefreshing)
        list.refresh()
        await list.finished()
        XCTAssertFalse(list.isRefreshing)
        XCTAssertEqual(LogsStub.queries().count, 3, "one range for each venue, once")
        XCTAssertEqual(list.tokens.map(\.symbol), ["T1"])
    }
}

/// Pools and token metadata on the stubs, as `VenueTokensTests` has them.
enum VenueFixture {
    static let created = ABI.eventTopic("PoolCreated(address,address,uint24,int24,address)")
    static let initialized = ABI.eventTopic("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")

    static func address(_ n: UInt8) -> Address { Address(data: Data(repeating: 0, count: 19) + Data([n]))! }

    static func token(_ n: UInt8, symbol: String) -> Token { Token(address: address(n), symbol: symbol, name: symbol, decimals: 18) }

    /// A pool for token `n` against WMON at `block`: on Uniswap v3, Monday Trade or Uniswap v4 by `n % 3`.
    static func pool(_ n: UInt8, at block: UInt64) -> Log {
        let word = { (address: Address) in address.data.leftPadded(to: 32) }
        let hash = Data(repeating: n, count: 32)
        switch n % 3 {
        case 0: return Log(address: Uniswap.v3Factory, topics: [created, word(address(n)), word(Monad.wmon), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        case 1: return Log(address: MondayTrade.factory, topics: [created, word(Monad.wmon), word(address(n)), BigUInt(3000).word], data: Data(count: 64),
                           blockNumber: block, transactionHash: hash, logIndex: 0)
        default: return Log(address: Uniswap.poolManager, topics: [initialized, hash, word(Monad.native), word(address(n))], data: Data(count: 160),
                            blockNumber: block, transactionHash: hash, logIndex: 0)
        }
    }

    /// Every token answers its symbol and name ("T" and its number) and 18 decimals.
    static func installMetadata() {
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            if selector == ABI.selector("symbol()") || selector == ABI.selector("name()") { return try! ABI.encode([.string("T\(to.data.last ?? 0)")], "string") }
            if selector == ABI.selector("decimals()") { return try! ABI.encode([.uint(18)], "uint8") }
            return nil
        }
    }
}

/// A store in memory: what it holds, how often it was read, and every write, decoded.
final class MemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VenueTokenList.Stored
    private var readCount = 0
    private var written: [(symbols: [String], checkpoint: UInt64)] = []

    init(list: [Token]?, checkpoint: UInt64) {
        stored = VenueTokenList.Stored(list: list.flatMap { try? JSONEncoder().encode($0) }, checkpoint: checkpoint)
    }

    init(data: Data?, checkpoint: UInt64) {
        stored = VenueTokenList.Stored(list: data, checkpoint: checkpoint)
    }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var writes: [(symbols: [String], checkpoint: UInt64)] { lock.lock(); defer { lock.unlock() }; return written }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return stored.list }

    func read() -> VenueTokenList.Stored {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return stored
    }

    func write(_ list: Data, _ checkpoint: UInt64) {
        let symbols = ((try? JSONDecoder().decode([Token].self, from: list)) ?? []).map(\.symbol)
        lock.lock(); defer { lock.unlock() }
        stored = VenueTokenList.Stored(list: list, checkpoint: checkpoint)
        written.append((symbols, checkpoint))
    }

    /// A list on the stubs (`LogsStub`, named like rpc1, and `MomentsChainStub`) kept in this store.
    @MainActor
    func list() -> VenueTokenList {
        VenueTokenList(service: VenueTokensService(logsRPC: LogsStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc())), logos: { [:] },
                       read: { self.read() }, write: { self.write($0, $1) })
    }
}

/// A switch a stub's rule reads while a test flips it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var on: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}
