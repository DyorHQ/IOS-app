import BigInt
import XCTest
@testable import DyorKit

/// The DyorHQ coin registry: which addresses are DyorHQ coins — every launchpad's and every cohort's, live or retired —
/// read only from the factories' own records; what a failed read means (unknown, never "not DyorHQ"); reading only
/// what's new; and keeping it in a file, not UserDefaults. Contract reads come from `MomentsChainStub` (`DyorCoinChain`).
final class DyorCoinRegistryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dyor-coins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MomentsChainStub.install { _, _ in nil }
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: DyorCoinStore { DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName())) }

    private func registry(_ chain: DyorCoinChain, store: DyorCoinStore? = nil) -> DyorCoinRegistry {
        chain.install()
        return DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
    }

    private func launch(_ token: String, _ symbol: String, deployer: Address = DyorCoinChain.creator) -> DyorCoinChain.LaunchCoin {
        let address = Address(literal: token)
        return DyorCoinChain.LaunchCoin(token: address, name: symbol + " Coin", symbol: symbol, logo: DyorCoinChain.media(deployer, "\(symbol).jpg"), deployer: deployer,
                                        curve: Address(data: Data(address.data.reversed()))!)
    }

    private func moment(_ coin: String, _ symbol: String) -> DyorCoinChain.MomentCoin {
        let address = Address(literal: coin)
        return DyorCoinChain.MomentCoin(coin: address, nft: Address(data: Data(address.data.reversed()))!, creator: DyorCoinChain.creator, name: symbol, symbol: symbol,
                                        mediaURI: "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe", mediaHash: Data(repeating: 0xab, count: 32))
    }

    // MARK: Mainnet

    /// The chain as it is today: the 7 launches of the four retired launchpads (none on v2 or 0x6B1C yet) and the 6
    /// Moments of cohorts 1–3 (none on c4 yet), each as its factory recorded it, read in three Multicall3 reads.
    func testTheMainnetCoinsAreReadInThreeReads() async throws {
        let registry = registry(.mainnet)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertEqual(coins.count, 13)
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "counts, then lists, then every new coin's details")

        let qt = try XCTUnwrap(coins[DyorCoinChain.qt])
        XCTAssertEqual(qt.origin, .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), "read in the 16-field layout")
        XCTAssertEqual([qt.symbol, qt.name], ["QT", "Quet"])
        XCTAssertEqual(qt.creator, DyorCoinChain.owner)
        XCTAssertEqual(qt.logo, DyorCoinChain.media(DyorCoinChain.owner, "0136f3f3-24cf-45e5-b4d8-1f68423c36cf.jpg"))
        XCTAssertEqual(qt.pair, .zero, "MON")
        XCTAssertTrue(qt.isLaunch && qt.retired)
        XCTAssertEqual(coins[Address(literal: "0xCD83D45F985BB42b7d6ABB1f2cC12860B4610c3D")]?.pair, DyorCoinChain.aBIL, "JUST trades against aBIL")
        XCTAssertEqual(coins[Address(literal: "0xA4D9b2697254292ad30e06Ce968a7e18De6fF884")]?.origin, .launch(factory: DyorCoinChain.audit, generation: .v1, retired: true))
        XCTAssertEqual(coins[Address(literal: "0x74b215C1788A90aAF45A33f83584C1a04ba402b8")]?.origin, .launch(factory: DyorCoinChain.preAudit, generation: .preAudit, retired: true))
        XCTAssertEqual(Set(coins.values.filter(\.isLaunch).map(\.symbol)), ["QT", "JUST", "BB", "BP", "GMGM", "BPP", "LP"])

        // Every Moment coin the retired cohorts minted, each under its (factory, id).
        for (coin, key) in MomentsAddresses.retiredMainnetCoins {
            let entry = try XCTUnwrap(coins[coin], "\(coin) is a DyorHQ Moment")
            XCTAssertEqual(entry.momentKey, key)
            XCTAssertTrue(entry.retired)
            XCTAssertEqual(entry.pair, Monad.usdc)
        }
        let nature = try XCTUnwrap(coins[Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")])
        XCTAssertEqual([nature.symbol, nature.name], ["NAT", "Nature"])
        XCTAssertTrue(nature.mediaIsVideo, "Nature is a video: its picture is the poster")
        XCTAssertEqual(nature.logo, "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe")
        XCTAssertEqual(nature.mediaHash, Data(hex: "0x46a0fa05ecc0fd0f47856df1d8a6fbd69145d1d9df6da9927301719b4a06a6c5"))
        let diva = try XCTUnwrap(coins[Address(literal: "0xd6c17E083b53fa1c46b71120D6959303Ae4B8e1F")])
        XCTAssertTrue(diva.mediaIsVideo)
        XCTAssertEqual(diva.creator, DyorCoinChain.creator)
        XCTAssertFalse(try XCTUnwrap(coins[Address(literal: "0xDc1bC41b7C197DE19f17C7832bec3Bb748D92297")]).mediaIsVideo)
        let proof = await registry.prove([DyorCoinChain.james])
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor, "JAMES, a nad.fun coin, is none of these")
    }

    // MARK: Every factory

    /// A coin on each of the five launchpads — the live v2 one and the four retired ones, 0xad3d's in its 16-field layout —
    /// and each of the four cohorts is proven a DyorHQ coin, retired everywhere but on the live launchpad and cohort.
    func testACoinOnEachLaunchpadAndEachCohortIsProven() async throws {
        var chain = DyorCoinChain()
        let live = LaunchpadAddresses.monadMainnet.factory
        let tokens = [
            live: "0x0000000000000000000000000000000000c0a001", DyorCoinChain.relaunch: "0x0000000000000000000000000000000000c0a002",
            DyorCoinChain.audit: "0x0000000000000000000000000000000000c0a003", DyorCoinChain.preAudit: "0x0000000000000000000000000000000000c0a004",
            DyorCoinChain.legacy: "0x0000000000000000000000000000000000c0a005",
        ]
        for (factory, token) in tokens { chain.launches[factory] = [launch(token, "L\(token.suffix(1))")] }
        let c4 = MomentsAddresses.monadMainnet.factory
        let coins = [c4: "0x0000000000000000000000000000000000c0b004", DyorCoinChain.c3: "0x0000000000000000000000000000000000c0b003",
                     DyorCoinChain.c2: "0x0000000000000000000000000000000000c0b002", DyorCoinChain.c1: "0x0000000000000000000000000000000000c0b001"]
        for (factory, coin) in coins { chain.moments[factory] = [moment(coin, "M\(coin.suffix(1))")] }
        let registry = registry(chain)
        let asked = tokens.values.map { Address(literal: $0) } + coins.values.map { Address(literal: $0) }
        let proof = await registry.prove(asked)
        for (factory, token) in tokens {
            guard case .dyor(let coin)? = proof[Address(literal: token)] else { return XCTFail("\(token) on \(factory) is a DyorHQ launch") }
            let stack = try XCTUnwrap(DyorCoinChain.stacks.first { $0.factory == factory })
            XCTAssertEqual(coin.origin, .launch(factory: factory, generation: stack.generation, retired: factory != live))
        }
        for (factory, token) in coins {
            guard case .dyor(let coin)? = proof[Address(literal: token)] else { return XCTFail("\(token) on \(factory) is a DyorHQ Moment") }
            XCTAssertEqual(coin.origin, .moment(factory: factory, id: 1, retired: factory != c4))
            XCTAssertEqual(coin.pair, Monad.usdc)
        }
        XCTAssertEqual(MomentsChainStub.batches().count, 3, "every factory's record, then details or the Moment, then the Moments' details")
        let known = await registry.all
        XCTAssertEqual(known.count, 9, "a coin proven is kept")
    }

    /// 0x6B1C was retired in the app only (owner decision 2026-09-28): builds before 16 can still launch there, and such a
    /// coin is a DyorHQ launch like any other — on a retired launchpad.
    func testACoinLaunchedOnTheRetired0x6B1CIsADyorHQLaunchOnARetiredLaunchpad() async throws {
        var chain = DyorCoinChain.mainnet
        let late = launch("0x0000000000000000000000000000000000006b1c", "LATE")
        chain.launches[DyorCoinChain.relaunch] = [late]
        let registry = registry(chain)
        await registry.refresh()
        let found = await registry.coin(late.token)
        let coin = try XCTUnwrap(found)
        XCTAssertEqual(coin.origin, .launch(factory: DyorCoinChain.relaunch, generation: .v1, retired: true))
        XCTAssertEqual(coin.creator, late.deployer)
    }

    // MARK: Only the factories say

    /// A factory record that names another token proves nothing about the one asked: not when a factory lists it — it
    /// stays out, and that factory's list is read from there again next time, as when a node behind the chain answers —
    /// and not when it is asked about directly. Nor does a Moment id whose Moment is another coin's.
    func testARecordNamingAnotherTokenIsRefused() async throws {
        var chain = DyorCoinChain()
        var listed = launch("0x0000000000000000000000000000000000000b0b", "BOB")
        listed.recordToken = DyorCoinChain.qt
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [listed]
        var other = moment("0x0000000000000000000000000000000000000c0c", "CC")
        other.momentCoin = Address(literal: "0x0000000000000000000000000000000000000d0d")
        chain.moments[DyorCoinChain.c2] = [other]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertFalse(complete, "neither list was read past its coin")
        let coins = await registry.all
        XCTAssertTrue(coins.isEmpty)
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 0)
        XCTAssertEqual(checkpoints[DyorCoinChain.c2], 0)
        let proof = await registry.prove([listed.token, other.coin])
        XCTAssertEqual(proof[listed.token], .notDyor)
        XCTAssertEqual(proof[other.coin], .notDyor)
        // Pure half: the record must exist, name this very token and a curve.
        let stack = LaunchpadAddresses.monadMainnet
        let answers: [Result<[ABIValue], Error>] = [.success([.tuple(DyorCoinChain.record(listed, legacy: false))]), .success([.string("Bob")]), .success([.string("BOB")]),
                                                    .success([.address(.zero), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))])]
        XCTAssertNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: answers))
        listed.recordToken = nil
        var named = answers
        named[0] = .success([.tuple(DyorCoinChain.record(listed, legacy: false))])
        XCTAssertNotNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: named))
        named[3] = .failure(RPCError(code: 3, message: "reverted"))
        XCTAssertNil(DyorCoinRegistry.launchCoin(listed.token, stack: stack, retired: false, answers: named), "a missing answer admits nothing")
    }

    /// A token that claims a DyorHQ factory (`factory()`), DyorHQ's name, symbol and bucket is none of DyorHQ's: no factory
    /// names it, and nothing is ever asked of the token itself.
    func testATokenClaimingAFactoryIsNotADyorHQCoin() async throws {
        let impostor = Address(literal: "0x000000000000000000000000000000000000beef")
        var chain = DyorCoinChain.mainnet
        chain.impostors = [impostor]
        let registry = registry(chain)
        let proof = await registry.prove([impostor])
        XCTAssertEqual(proof[impostor], .notDyor)
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == impostor }, "membership never comes from the token")
        let coin = await registry.coin(impostor)
        XCTAssertNil(coin)
    }

    /// A factory that doesn't answer leaves a coin unknown — shown as today — never "not DyorHQ", and it is asked again
    /// next time; a coin one factory does name is DyorHQ's whatever another failed to say. The enumeration keeps what it
    /// read and reads the rest once the factory answers.
    func testAFailedReadIsUnknownAndIsAskedAgain() async throws {
        let unseen = Address(literal: "0x0000000000000000000000000000000000000abc")
        var chain = DyorCoinChain.mainnet
        chain.silent = [DyorCoinChain.c2]
        let registry = registry(chain)
        var proof = await registry.prove([unseen, DyorCoinChain.qt])
        XCTAssertEqual(proof[unseen], .unknown)
        guard case .dyor(let qt)? = proof[DyorCoinChain.qt] else { return XCTFail("QT's own factory named it") }
        XCTAssertEqual(qt.symbol, "QT")
        var membership = await registry.membership(unseen)
        XCTAssertEqual(membership, .unknown, "no negative is kept from an incomplete read")

        let complete = await registry.refresh()
        XCTAssertFalse(complete, "cohort 2 didn't answer")
        var coins = await registry.all
        XCTAssertEqual(coins.count, 11, "all but cohort 2's two")

        chain.silent = []
        chain.install()
        proof = await registry.prove([unseen])
        XCTAssertEqual(proof[unseen], .notDyor, "asked again, and every factory answered")
        membership = await registry.membership(unseen)
        XCTAssertEqual(membership, .notDyor)
        let healed = await registry.refresh()
        XCTAssertTrue(healed)
        coins = await registry.all
        XCTAssertEqual(coins.count, 13)
    }

    /// A node behind the chain answers a coin its factory already lists with an empty record, and the coin itself as an
    /// account with no code: the coin stays out and its factory's list is read from it again next time, never passed over.
    func testACoinANodeHasNotReachedIsReadAgainNextTime() async throws {
        var chain = DyorCoinChain.mainnet
        let fresh = launch("0x0000000000000000000000000000000000000f10", "NEW")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [fresh]
        chain.lagging = [fresh.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertFalse(complete)
        var coins = await registry.all
        XCTAssertEqual(coins.count, 13, "every other coin is read")
        XCTAssertNil(coins[fresh.token])
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 0, "not passed over")

        chain.lagging = []
        chain.install()
        let caughtUp = await registry.refresh()
        XCTAssertTrue(caughtUp)
        coins = await registry.all
        XCTAssertEqual(coins[fresh.token]?.symbol, "NEW")
    }

    /// Anyone launching for 5 MON can make a coin's strings cost more gas than a read has. That coin's calls fail however
    /// they are read: it is passed over, unlabelled (shown as today), and not read again at every refresh or proof, while
    /// the coins listed after it — whose calls it starved in the shared read — are read again and admitted.
    func testACoinWhoseCallsBurnTheReadsGasIsPassedOverUnlabelled() async throws {
        var chain = DyorCoinChain.mainnet
        let bomb = launch("0x0000000000000000000000000000000000000b0a", "BOMB")
        let after = launch("0x0000000000000000000000000000000000000b0b", "AFTER")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [bomb, after]
        chain.starving = [bomb.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertNil(coins[bomb.token])
        XCTAssertEqual(coins[after.token]?.symbol, "AFTER")
        XCTAssertEqual(coins.count, 14)
        XCTAssertEqual(MomentsChainStub.batches().count, 5, "counts, lists, every coin, the bomb on its own, the others again together")
        let checkpoints = await registry.checkpoints
        XCTAssertEqual(checkpoints[LaunchpadAddresses.monadMainnet.factory], 2, "past it")
        let membership = await registry.membership(bomb.token)
        XCTAssertEqual(membership, .unknown, "never \"not DyorHQ\": its factory named it")

        chain.install()
        let proof = await registry.prove([bomb.token])
        XCTAssertEqual(proof[bomb.token], .unknown)
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "not asked again this session")
        await registry.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "nor at the next refresh: the counts alone")
    }

    /// A coin that makes the node refuse the whole read (out of gas) doesn't take the others down: they are read again, and
    /// it is left unlabelled. The same holds for a held coin being proven.
    func testAReadRefusedAsAWholeIsReadAgainCoinByCoin() async throws {
        var chain = DyorCoinChain.mainnet
        let bomb = launch("0x0000000000000000000000000000000000000b1a", "BOMB")
        chain.launches[DyorCoinChain.relaunch] = [bomb]
        chain.breaking = [bomb.token]
        let registry = registry(chain)
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let coins = await registry.all
        XCTAssertEqual(coins.count, 13)
        XCTAssertNil(coins[bomb.token])

        let fresh = self.registry(chain)
        let proof = await fresh.prove([bomb.token, DyorCoinChain.qt])
        XCTAssertEqual(proof[bomb.token], .unknown)
        guard case .dyor(let qt)? = proof[DyorCoinChain.qt] else { return XCTFail("QT is read though the bomb shared its read") }
        XCTAssertEqual(qt.symbol, "QT")
    }

    /// What one coin's read comes to: admitted on every answer and the factory's word; passed over, unlabelled, when its own
    /// calls revert or run out of gas read on their own; read again later on no answer, an answer that doesn't decode (an
    /// account with no code yet) or a record that doesn't name it.
    func testTheVerdictOnOneCoinsRead() {
        let coin = DyorCoin(address: DyorCoinChain.qt, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: "QT", name: "Quet",
                            creator: DyorCoinChain.owner, logo: "", pair: .zero)
        let ok: Result<[ABIValue], Error> = .success([.string("QT")])
        let reverted: Result<[ABIValue], Error> = .failure(RPCError(code: -32000, message: "Call reverted", data: "0x"))
        let outOfGas: Result<[ABIValue], Error> = .failure(RPCError(code: -32000, message: "out of gas"))
        let undecodable: Result<[ABIValue], Error> = .failure(ABIError.truncated)
        let throttled: Result<[ABIValue], Error> = .failure(RPCError(code: -32005, message: "request limit reached"))
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([ok, ok]), decide: { _ in coin }), .admit(coin))
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([ok, ok]), decide: { _ in nil }), .later, "a record that doesn't name it")
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([ok, reverted]), decide: { _ in coin }), .unreadable)
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([outOfGas, outOfGas]), decide: { _ in coin }), .unreadable)
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([ok, undecodable]), decide: { _ in coin }), .later)
        XCTAssertEqual(DyorCoinRegistry.verdict(.answered([ok, throttled]), decide: { _ in coin }), .later)
        XCTAssertEqual(DyorCoinRegistry.verdict(.unanswered, decide: { _ in coin }), .later)
    }

    /// Answers the pure half gets: a missing one leaves the candidate incomplete; an empty record or a zero id is an
    /// answer.
    func testClaimsNeedEveryFactorysAnswer() {
        let stacks = Array(DyorCoinChain.stacks.prefix(2))
        let cohorts = Array(DyorCoinChain.cohortTable.prefix(1))
        let empty: Result<[ABIValue], Error> = .success([.tuple(DyorCoinChain.record(nil, legacy: false))])
        let zero: Result<[ABIValue], Error> = .success([.uint(0)])
        let candidate = Address(literal: "0x0000000000000000000000000000000000000abc")
        XCTAssertTrue(DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty, zero]).complete)
        let missing = DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, .failure(RPCError(code: 3, message: "reverted")), zero])
        XCTAssertFalse(missing.complete)
        XCTAssertNil(missing.launch)
        XCTAssertFalse(DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty]).complete, "an answer short")
        let claimed = DyorCoinRegistry.claims(candidate, launchpads: stacks, cohorts: cohorts, answers: [empty, empty, .success([.uint(7)])])
        XCTAssertEqual(claimed.moments.map(\.1), [7])
    }

    /// MON and the curated tokens are never DyorHQ coins, and never asked.
    func testMONAndTheCuratedTokensAreNeverAsked() async {
        let registry = registry(.mainnet)
        let proof = await registry.prove([.zero, Monad.usdc, Monad.wmon])
        XCTAssertEqual(Set(proof.values), [.notDyor])
        XCTAssertTrue(MomentsChainStub.batches().isEmpty)
    }

    // MARK: Reading only what's new

    /// A second refresh reads each factory's count, then only the launches and Moments added since.
    func testARefreshReadsOnlyWhatIsNew() async throws {
        var chain = DyorCoinChain.mainnet
        let registry = registry(chain)
        await registry.refresh()
        let fresh = launch("0x0000000000000000000000000000000000000f00", "NEW")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [fresh]
        var late = moment("0x0000000000000000000000000000000000000f01", "LATE")
        late.creator = DyorCoinChain.owner
        chain.moments[DyorCoinChain.c3]?.append(late)
        chain.install()
        let complete = await registry.refresh()
        XCTAssertTrue(complete)
        let batches = MomentsChainStub.batches()
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].count, DyorCoinChain.stacks.count + DyorCoinChain.cohortTable.count, "one count per factory")
        let lists = batches[1]
        XCTAssertEqual(lists.map(\.to), [LaunchpadAddresses.monadMainnet.factory, DyorCoinChain.c3], "v2's new launch, cohort 3's Moment #2 — nothing else")
        XCTAssertEqual(Set(batches[2].map(\.to)), [fresh.token, LaunchpadAddresses.monadMainnet.factory, late.coin, late.nft, DyorCoinChain.c3])
        let coins = await registry.all
        XCTAssertEqual(coins.count, 15)
        XCTAssertEqual(coins[late.coin]?.momentKey, MomentKey(factory: DyorCoinChain.c3, id: 2), "a Moment published on cohort 3 after its pin is read like any other")
        let own = await registry.coins(createdBy: DyorCoinChain.owner).map(\.symbol)
        XCTAssertEqual(Set(own), ["QT", "JUST", "NAT", "LATE"])

        chain.install()
        await registry.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "nothing new: the counts alone")
    }

    /// A factory whose count is below what was read (a fork restarted under the same file, a node behind the others) is
    /// read again from the start.
    func testACountBelowTheCheckpointIsReadAgainFromThere() async throws {
        let v2 = LaunchpadAddresses.monadMainnet.factory
        try store.save(DyorCoinStore.Snapshot(coins: [], checkpoints: [DyorCoinStore.Checkpoint(factory: v2, count: 5)]))
        var chain = DyorCoinChain()
        let first = launch("0x0000000000000000000000000000000000000f02", "ONE")
        chain.launches[v2] = [first]
        let registry = registry(chain, store: store)
        await registry.refresh()
        chain.launches[v2]?.append(launch("0x0000000000000000000000000000000000000f03", "TWO"))
        chain.install()
        await registry.refresh()
        let coins = await registry.all
        XCTAssertEqual(Set(coins.values.map(\.symbol)), ["ONE", "TWO"])
    }

    // MARK: Keeping it

    /// What was read is kept in the file and read back at the next start — before any read, which then asks only the
    /// counts. The file holds chain facts only, stays out of backups, and comes back byte for byte.
    func testTheRegistryIsKeptInItsFileAcrossStarts() async throws {
        let first = registry(.mainnet, store: store)
        await first.refresh()
        let read = await first.all

        MomentsChainStub.install { _, _ in nil }
        let next = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        let kept = await next.all
        XCTAssertEqual(kept, read)
        let qt = await next.coin(DyorCoinChain.qt)
        XCTAssertEqual(qt?.symbol, "QT")
        DyorCoinChain.mainnet.install()
        await next.refresh()
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "every factory's list was read before")

        XCTAssertEqual(store.url.lastPathComponent, "dyor-coins-143.json")
        XCTAssertEqual(DyorCoinStore.fileName(fork: true), "dyor-coins-143-fork.json")
        let values = try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.version, DyorCoinStore.Snapshot.currentVersion)
        XCTAssertEqual(snapshot.coins.count, 13)
        XCTAssertEqual(Set(snapshot.checkpoints.map(\.factory)), Set(DyorCoinChain.stacks.map(\.factory) + DyorCoinChain.cohortTable.map(\.factory)))
        XCTAssertEqual(snapshot.checkpoints.first { $0.factory == DyorCoinChain.legacy }?.count, 4)
        let bytes = try Data(contentsOf: store.url)
        try store.save(try JSONDecoder().decode(DyorCoinStore.Snapshot.self, from: bytes))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes, "the same set always writes the same bytes")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"launch\"") && text.contains("\"generation\":\"legacy\"") && text.contains("\"kind\":\"moment\""))
    }

    /// A file from another build is read against this build's tables: a coin of a factory it doesn't read is dropped, and a
    /// stack or cohort retired since then reads as retired. A damaged file, or one of another version, is ignored.
    func testAKeptFileIsReadAgainstThisBuildsTables() throws {
        let v2 = LaunchpadAddresses.monadMainnet
        let stranger = Address(literal: "0x00000000000000000000000000000000f0f0f0f0")
        let coins = [
            DyorCoin(address: DyorCoinChain.qt, origin: .launch(factory: DyorCoinChain.legacy, generation: .v2, retired: false), symbol: "QT", name: "Quet", creator: DyorCoinChain.owner, logo: "", pair: .zero),
            DyorCoin(address: stranger, origin: .launch(factory: stranger, generation: .v2, retired: false), symbol: "X", name: "X", creator: stranger, logo: "", pair: .zero),
            DyorCoin(address: Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF"), origin: .moment(factory: DyorCoinChain.c3, id: 1, retired: false), symbol: "NAT", name: "Nature",
                     creator: DyorCoinChain.owner, logo: "", mediaHash: Data(count: 32), mediaIsVideo: true, pair: Monad.usdc),
        ]
        let snapshot = DyorCoinStore.Snapshot(coins: coins, checkpoints: [.init(factory: stranger, count: 3), .init(factory: v2.factory, count: 2)])
        let kept = DyorCoinRegistry.restored(snapshot, launchpads: DyorCoinChain.stacks, cohorts: DyorCoinChain.cohortTable,
                                             liveLaunchpad: v2.factory, liveCohort: MomentsAddresses.monadMainnet.factory)
        XCTAssertEqual(Set(kept.coins.keys), [DyorCoinChain.qt, coins[2].address])
        XCTAssertEqual(kept.coins[DyorCoinChain.qt]?.origin, .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true))
        XCTAssertEqual(kept.coins[coins[2].address]?.retired, true)
        XCTAssertEqual(kept.checkpoints, [v2.factory: 2])

        try Data("not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
        var other = snapshot
        other.version = 99
        try JSONEncoder().encode(other).write(to: store.url)
        XCTAssertNil(store.load())
        store.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        store.erase()
    }

    /// Account deletion: everything forgotten and the file deleted; a read already under way writes nothing back.
    func testEraseForgetsEverythingAndDeletesTheFile() async throws {
        let registry = registry(.mainnet, store: store)
        await registry.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        await registry.erase()
        let coins = await registry.all
        XCTAssertTrue(coins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        await registry.refresh()
        let again = await registry.all
        XCTAssertEqual(again.count, 13, "read again from the start")
    }

    // MARK: Ingest

    /// Launches and Moments another screen already read from a known factory are kept at no cost; one from a factory the
    /// registry doesn't read is not.
    func testLaunchesAndMomentsReadElsewhereAreKeptOnlyFromKnownFactories() async throws {
        let registry = registry(DyorCoinChain())
        func launchValue(_ token: Address, factory: Address) -> Launch {
            Launch(token: token, curve: Address(literal: "0x00000000000000000000000000000000000c02c0"), deployer: DyorCoinChain.owner, creatorFeeRecipient: DyorCoinChain.owner,
                   pairToken: Monad.usdc, graduationThreshold: 1, creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .uniswapV4,
                   phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32), name: "Doge", symbol: "狗狗",
                   logo: DyorCoinChain.media(DyorCoinChain.owner, "d.jpg"), description: "", socials: .none, pair: .mon, price: 0, realQuoteReserve: 0,
                   completed: false, rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
        }
        let live = Address(literal: "0x0000000000000000000000000000000000000d01")
        let retired = Address(literal: "0x0000000000000000000000000000000000000d02")
        let stranger = Address(literal: "0x0000000000000000000000000000000000000d03")
        await registry.ingest([launchValue(live, factory: .zero), launchValue(retired, factory: DyorCoinChain.audit), launchValue(stranger, factory: stranger),
                               launchValue(Monad.usdc, factory: .zero)])
        let first = await registry.all
        XCTAssertEqual(first[live]?.origin, .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false), "the zero factory is the live one")
        XCTAssertEqual(first[live]?.symbol, "狗狗")
        XCTAssertEqual(first[live]?.pair, Monad.usdc)
        XCTAssertEqual(first[retired]?.origin, .launch(factory: DyorCoinChain.audit, generation: .v1, retired: true))
        XCTAssertNil(first[stranger])
        XCTAssertNil(first[Monad.usdc], "a curated token is never a DyorHQ coin")

        let provenance = MomentProvenance(mediaURI: "ipfs://bafkreihhphi3iebkxbt76qhcwhz3e4nobtn6756len366po7tic6n7rxhe", mediaHash: Data(repeating: 1, count: 32), place: "", date: 0,
                                          animationURI: "ipfs://bafybeie4rh73i7kfugowp4jyjdjpnng3a7z4suslievdbulqfjb6ywzvuy")
        func info(_ coin: Address, factory: Address) -> MomentInfo {
            let moment = Moment(id: 4, creator: DyorCoinChain.creator, platform: .zero, treasury: .zero, coin: coin, nft: coin, price: 1, threshold: 1, rateNum: 1, rateDen: 1,
                                creatorBps: 0, platformBps: 0, reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0, deadline: 0, factory: factory)
            return MomentInfo(moment: moment, name: "Sea", symbol: "SEA", provenance: provenance,
                              ledger: MomentLedger(state: .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: 0, platformClaimable: 0,
                                                   treasuryClaimable: 0, totalGross: 0, collects: 0),
                              editions: 0, closed: false, entitlements: 0, graduated: false, progressBps: 0, pool: nil)
        }
        let sea = Address(literal: "0x0000000000000000000000000000000000000e01")
        let strangerMoment = Address(literal: "0x0000000000000000000000000000000000000e02")
        await registry.ingest([info(sea, factory: DyorCoinChain.c2), info(strangerMoment, factory: stranger)])
        let second = await registry.all
        XCTAssertEqual(second[sea]?.origin, .moment(factory: DyorCoinChain.c2, id: 4, retired: true))
        XCTAssertEqual(second[sea]?.mediaIsVideo, true)
        XCTAssertEqual(second[sea]?.mediaHash, provenance.mediaHash)
        XCTAssertNil(second[strangerMoment])
        XCTAssertTrue(MomentsChainStub.batches().isEmpty, "ingest reads nothing")
    }

    /// A screen model following the registry gets the list at once, then again when a coin arrives.
    func testUpdatesFollowEveryChange() async throws {
        let registry = registry(.mainnet)
        let stream = await registry.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 0)
        await registry.refresh()
        let second = await iterator.next()
        XCTAssertEqual(second?.count, 13)
    }

    // MARK: Live (read-only; DYOR_LIVE_COINS=1)

    /// Monad mainnet, read-only, through rpc1 with a User-Agent, one Multicall3 read after another: every coin recorded in
    /// `DyorCoinChain.mainnet` is in the registry exactly as the fixture has it (a launch or Moment added since only adds
    /// to the list), every factory's list is read to its count, QT is proven by point proof too, and JAMES and an address
    /// no factory made are not DyorHQ's. Prints the counts per launchpad and cohort.
    func testLiveMainnetHoldsEveryRecordedCoin() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_COINS"] == "1" else { throw XCTSkip("set DYOR_LIVE_COINS=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "DyorHQ-build17-C2-readonly/1.0"]
        let rpc = RPCClient(url: URL(string: "https://rpc1.monad.xyz")!, session: URLSession(configuration: configuration))
        let registry = DyorCoinRegistry(rpc: rpc, store: store)
        let complete = await registry.refresh()
        let coins = await registry.all
        let checkpoints = await registry.checkpoints
        XCTAssertTrue(complete, "Monad RPC incomplete: \(coins.count) coins read")
        let names: [Address: String] = [LaunchpadAddresses.monadMainnet.factory: "launchpad v2 0x3B1f (live)", DyorCoinChain.relaunch: "launchpad 0x6B1C (retired, open)",
                                        DyorCoinChain.audit: "launchpad 0x10F3 (retired)", DyorCoinChain.preAudit: "launchpad 0x2F02 (retired)",
                                        DyorCoinChain.legacy: "launchpad 0xad3d (retired, legacy)", MomentsAddresses.monadMainnet.factory: "Moments c4 0x95eb (live)",
                                        DyorCoinChain.c3: "Moments c3 0x0FD4 (retired, open)", DyorCoinChain.c2: "Moments c2 0xc12B (retired)", DyorCoinChain.c1: "Moments c1 0x6469 (retired)"]
        for factory in DyorCoinChain.stacks.map(\.factory) + DyorCoinChain.cohortTable.map(\.factory) {
            let found = coins.values.filter { $0.factory == factory }.sorted { $0.symbol < $1.symbol }
            print("DYOR_LIVE \(names[factory] ?? factory.hex): count \(checkpoints[factory] ?? 0), registry \(found.count): \(found.map(\.symbol).joined(separator: ", "))")
            XCTAssertEqual(found.count, checkpoints[factory] ?? 0, "every coin \(names[factory] ?? factory.hex) lists is a DyorHQ coin")
        }
        let chain = DyorCoinChain.mainnet
        for (factory, launches) in chain.launches {
            for expected in launches {
                let coin = try XCTUnwrap(coins[expected.token], expected.symbol)
                XCTAssertEqual(coin.factory, factory)
                XCTAssertEqual([coin.symbol, coin.name, coin.logo], [expected.symbol, expected.name, expected.logo])
                XCTAssertEqual(coin.creator, expected.deployer)
                XCTAssertEqual(coin.pair, expected.pair)
                XCTAssertTrue(coin.retired)
            }
        }
        for (factory, moments) in chain.moments {
            for (index, expected) in moments.enumerated() {
                let coin = try XCTUnwrap(coins[expected.coin], expected.symbol)
                XCTAssertEqual(coin.origin, .moment(factory: factory, id: BigUInt(index + 1), retired: true))
                XCTAssertEqual([coin.symbol, coin.name, coin.logo], [expected.symbol, expected.name, expected.mediaURI])
                XCTAssertEqual(coin.creator, expected.creator)
                XCTAssertEqual(coin.mediaHash, expected.mediaHash)
                XCTAssertEqual(coin.mediaIsVideo, !expected.animationURI.isEmpty)
            }
        }
        let proving = DyorCoinRegistry(rpc: rpc)
        let nobody = Address(literal: "0x000000000000000000000000000000000000dEaD")
        let proof = await proving.prove([nobody, DyorCoinChain.james, DyorCoinChain.qt, Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")])
        XCTAssertEqual(proof[nobody], .notDyor)
        XCTAssertEqual(proof[DyorCoinChain.james], .notDyor, "JAMES is a nad.fun coin")
        XCTAssertEqual(proof[DyorCoinChain.qt], coins[DyorCoinChain.qt].map(DyorCoinRegistry.Membership.dyor))
        guard case .dyor(let nature)? = proof[Address(literal: "0x43682FA268A98a87C946d0b933203a8834b391BF")] else { return XCTFail("Nature, cohort 3's Moment, by point proof") }
        XCTAssertEqual(nature.momentKey, MomentKey(factory: DyorCoinChain.c3, id: 1))
        print("DYOR_LIVE total \(coins.count) coins; point proof: QT \(proof[DyorCoinChain.qt].map { "\($0)" } ?? "?"), JAMES \(proof[DyorCoinChain.james].map { "\($0)" } ?? "?"), 0x…dEaD \(proof[nobody].map { "\($0)" } ?? "?")")
    }

    /// Nothing is kept in UserDefaults: a key there with an earlier-install prefix turns App Lock off on a new install
    /// (`AppSettings.appLockDefault`, rule R4).
    func testTheRegistryKeepsNothingInUserDefaults() throws {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit
        folder.append(path: "Sources/DyorKit/Services/DyorCoins")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "DyorCoinStore.swift" })
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for use in ["UserDefaults.standard", "UserDefaults(", "@AppStorage", "NSUbiquitousKeyValueStore"] {
                XCTAssertFalse(source.contains(use), "\(file.lastPathComponent) uses \(use)")
            }
        }
    }
}
