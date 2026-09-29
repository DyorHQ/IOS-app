#if os(macOS)
import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The release gate's proof that the retired Moments cohorts are final. `scripts/dev/check-launchpad-addresses.py` reads
/// the pins (`MomentLink.Cohort.finalMomentCount`) and the coin table (`MomentsAddresses.retiredMainnetCoins`) from the
/// Swift sources and, with `--release` (every archive path) or `--chain` (by hand), requires on chain: `momentCount()`
/// equal to the pin, and every Moment's coin in the table, keyed to its (factory, id). A Moment published past a pin
/// would otherwise get no name link (and its name would go to a later Moment) and its coin would be tradable. Cohort 3
/// alone need not be paused: it stays open on chain (owner decision 2026-09-28, retired in the app only), which the gate
/// reports as a note while its count still equals its pin. Cohorts 1 and 2 must stay paused.
///
/// The same reads prove the live stacks once wired: every module in `LaunchpadAddresses.monadMainnet` and
/// `MomentsAddresses.monadMainnet` has code, each factory's getters name those modules and the records' owner,
/// governance and guardian, and each factory was created at its record's `deployBlock`, so a wrong record promoted with
/// Swift that matches it (a simulated or rehearsal deployment, another stack) still refuses.
///
/// A release also reads the public Contracts & Addresses page Get Help opens: it must list every contract in the two
/// tables, with the tables' factories as its current LaunchpadFactory and MomentsFactory rows.
///
/// Here the script runs against canned eth_call and eth_getCode answers and a canned page built from the compiled
/// constants (its `--chain-fixture` mode, which it refuses together with `--release`): the chain and the page as they
/// should be pass, so the script reads the sources the way the app compiles them, and each way a cohort can drift from
/// its pin, a live stack from its table, or the page from this build, refuses.
final class RetiredCohortGateTests: XCTestCase {
    /// The fixture's block, after both v2 deployments.
    static let block: UInt64 = 108_895_597

    /// One retired factory as the chain reports it: `coins[i]` is Moment #(i + 1)'s coin.
    struct ChainCohort {
        let cohort: MomentLink.Cohort
        var paused = true
        var coins: [Address]
        /// Answers left out, as an RPC that cannot serve them.
        var unreadable: Set<String> = []
    }

    /// The chain exactly as the pins say, publishing paused on each.
    static func pinned() -> [ChainCohort] {
        MomentLink.Cohort.allCases.filter(\.isRetired).map { cohort in
            let coins = MomentsAddresses.retiredMainnetCoins.filter { $0.value.factory == cohort.factory }.sorted { $0.value.id < $1.value.id }.map(\.key)
            return ChainCohort(cohort: cohort, coins: coins)
        }
    }

    /// The chain as it is (2026-09-28): the pinned counts, cohorts 1 and 2 paused, cohort 3 open.
    static func current() -> [ChainCohort] {
        pinned().map { c in
            var c = c
            c.paused = c.cohort != .c3
            return c
        }
    }

    /// The live stacks as the chain reports them: each factory getter's ABI-encoded answer, and the code at an address
    /// by block ("0x" for none). `wired()` is the chain as DyorKit's tables and the committed records say. Getters are
    /// keyed by signature and encoded with DyorKit's ABI, so a selector the script pins wrong finds no answer.
    struct LiveChain {
        /// `"<contract>:<signature>"` → the answer; a key left out is a getter the RPC cannot serve.
        var getters: [String: Data] = [:]
        /// `"<address>@<block>"` → the code there.
        var code: [String: String] = [:]

        static func getter(_ contract: Address, _ signature: String) -> String { "\(contract.hex):\(signature)" }
        static func code(_ address: Address, at block: UInt64 = RetiredCohortGateTests.block) -> String { "\(address.hex)@\(block)" }

        static func wired() throws -> LiveChain {
            let l = LaunchpadAddresses.monadMainnet
            let m = MomentsAddresses.monadMainnet
            let launchpadRecord = try LaunchpadDeploymentTests.deploymentRecord("143.json")
            let momentsRecord = try LaunchpadDeploymentTests.deploymentRecord("moments-143.json")
            func recorded(_ record: [String: Any], _ key: String) throws -> Address {
                try XCTUnwrap(Address(try XCTUnwrap(record[key] as? String, "\(key) is missing from the record")), key)
            }
            var chain = LiveChain()
            let addresses: [(Address, String, Address)] = [
                (l.factory, "hook()", l.hook), (l.factory, "escrow()", l.escrow), (l.factory, "holderFeeSharing()", l.holderFeeSharing),
                (l.factory, "router()", l.router), (l.factory, "owner()", try recorded(launchpadRecord, "owner")),
                (m.factory, "collect()", m.collect), (m.factory, "vesting()", m.vesting), (m.factory, "graduation()", m.graduation),
                (m.factory, "locker()", m.locker), (m.factory, "feeHook()", m.hook), (m.factory, "buyback()", m.buyback),
                (m.factory, "governance()", try recorded(momentsRecord, "governance")), (m.factory, MomentsABI.Factory.guardian, try recorded(momentsRecord, "guardian")),
            ]
            for (contract, signature, value) in addresses { chain.getters[getter(contract, signature)] = try ABI.encode([.address(value)], "address") }
            chain.getters[getter(l.factory, "modulesSealed()")] = try ABI.encode([.bool(true)], "bool")
            chain.getters[getter(m.factory, MomentsABI.Factory.policy)] = try ABI.encode(
                [.uint(771_428_571), .uint(100_000), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500), .address(m.platform), .address(m.treasury)],
                MomentsABI.policyFlat)
            chain.getters[getter(m.factory, MomentsABI.Factory.externalBaseURI)] = try ABI.encode([.string(MomentsAddresses.expectedExternalBaseURI)], "string")
            for address in [l.factory, l.router, l.escrow, l.holderFeeSharing, l.hook, m.factory, m.collect, m.vesting, m.graduation, m.locker, m.hook, m.buyback] {
                chain.code[code(address)] = "0x6080"
            }
            let launchpadBlock = UInt64(try XCTUnwrap(launchpadRecord["deployBlock"] as? Int, "143.json has no deployBlock"))
            for (factory, created) in [(l.factory, launchpadBlock), (m.factory, m.deployBlock)] {
                chain.code[code(factory, at: created - 1)] = "0x"
                chain.code[code(factory, at: created)] = "0x6080"
            }
            return chain
        }
    }

    /// The Contracts & Addresses page as the gate reads it (GitBook's Markdown), laid out like the docs update for build
    /// 16: `current` as the current release, then the retired launchpad and cohort 3 under previous releases.
    static func docsPage(current: [(String, Address)]? = nil, previousFirst: Bool = false) -> String {
        let l = LaunchpadAddresses.monadMainnet
        let m = MomentsAddresses.monadMainnet
        let current = current ?? [
            ("LaunchpadFactory", l.factory), ("LaunchAndBuyRouter", l.router), ("FeeEscrow", l.escrow), ("HolderFeeSharing", l.holderFeeSharing),
            ("MemeHook (Uniswap v4 hook)", l.hook), ("MomentsFactory", m.factory), ("MomentCollect", m.collect), ("MomentVesting", m.vesting),
            ("MomentGraduation", m.graduation), ("MomentLocker", m.locker), ("MomentFeeHook (Uniswap v4 hook)", m.hook), ("MomentBuyback", m.buyback),
        ]
        let previous = [("LaunchpadFactory", V2WiringTests.relaunchFactory), ("MomentsFactory", V2WiringTests.cohort3Factory)]
        func table(_ title: String, _ rows: [(String, Address)]) -> String {
            "## \(title)\n\n| Contract | Address |\n| --- | --- |\n" + rows.map { "| \($0.0) | `\($0.1.hex)` |" }.joined(separator: "\n") + "\n"
        }
        let sections = [table("Current release", current), table("Previous releases", previous)]
        return "# Contracts & Addresses\n\n" + (previousFirst ? sections.reversed() : sections).joined(separator: "\n")
    }

    static func fixture(_ cohorts: [ChainCohort], live: LiveChain? = nil, docs: String? = docsPage()) throws -> Data {
        let live = try live ?? LiveChain.wired()
        var calls: [String: String] = [:]
        for c in cohorts {
            let factory = c.cohort.factory
            func put(_ signature: String, _ args: [ABIValue], _ answer: Data) {
                guard !c.unreadable.contains(signature) else { return }
                calls["\(factory.hex):\(MomentsABI.calldata(signature, args).hexString)"] = answer.hexString
            }
            put(MomentsABI.Factory.publishingPaused, [], try ABI.encode([.bool(c.paused)], "bool"))
            put(MomentsABI.Factory.momentCount, [], try ABI.encode([.uint(BigUInt(c.coins.count))], "uint256"))
            for (i, coin) in c.coins.enumerated() {
                let creator = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")
                let moment: [ABIValue] = [.address(creator), .address(.zero), .address(.zero), .address(coin), .address(coin),
                                          .uint(100_000), .uint(1), .uint(1), .uint(1), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500), .uint(1), .uint(2)]
                put(MomentsABI.Factory.getMoment, [.uint(BigUInt(i + 1))], try ABI.encode([.tuple(moment)], MomentsABI.momentTuple))
            }
        }
        for (key, answer) in live.getters {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            calls["\(parts[0]):\(MomentsABI.calldata(parts[1]).hexString)"] = answer.hexString
        }
        var fixture: [String: Any] = ["block": Self.block, "calls": calls, "code": live.code]
        fixture["docs"] = docs
        return try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
    }

    /// The checker at the repo root, or a skip when this checkout has no scripts.
    private func script() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → repo root
        url.appendPathComponent("scripts/dev/check-launchpad-addresses.py")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("scripts/dev/check-launchpad-addresses.py is not in this checkout") }
        return url
    }

    /// Runs the checker (never against a network: every mode used here exits before any RPC).
    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", try script().path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 127 { throw XCTSkip("python3 is not installed") }
        return (process.terminationStatus, output)
    }

    private func check(_ cohorts: [ChainCohort], live: LiveChain? = nil, docs: String? = docsPage()) throws -> (status: Int32, output: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retired-cohorts-\(UUID().uuidString).json")
        try Self.fixture(cohorts, live: live, docs: docs).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try run(["--chain-fixture", file.path])
    }

    private func replacing(_ cohort: MomentLink.Cohort, _ change: (inout ChainCohort) -> Void) -> [ChainCohort] {
        Self.current().map { c in
            var c = c
            if c.cohort == cohort { change(&c) }
            return c
        }
    }

    func testThePinnedStateIsProvenFinal() throws {
        XCTAssertEqual(Self.pinned().map(\.cohort), [.c1, .c2, .c3])
        XCTAssertEqual(Self.pinned().map(\.coins.count), [3, 2, 1])
        let (status, output) = try check(Self.pinned())
        XCTAssertEqual(status, 0, output)
        // The pins it read from the sources are the compiled ones.
        let pins = MomentLink.Cohort.allCases.compactMap { c in c.finalMomentCount.map { "\(c) \($0)" } }.joined(separator: ", ")
        XCTAssertTrue(output.contains("OK: retired Moments cohorts at their pins at fixture block \(Self.block) (\(pins)); live stacks as wired; docs page lists them\n"), output)
        XCTAssertFalse(output.contains("note:"), output)
    }

    /// Cohort 3 as the owner left it (2026-09-28): publishing open on chain, its count at its pin. The archive passes, and
    /// the open cohort is named in a note, not a problem.
    func testAnUnpausedRetiredCohortAtItsPinPasses() throws {
        let (status, output) = try check(Self.current())
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("note: Moments cohort c3 (\(MomentLink.Cohort.c3.factory.hex)): publishing is open on chain"), output)
        XCTAssertTrue(output.contains("; publishing open on c3; live stacks as wired; docs page lists them\n"), output)
        XCTAssertFalse(output.contains("cohort c1"), output)
        XCTAssertFalse(output.contains("check failed"), output)
    }

    /// The owner's decision leaves only cohort 3 open. Cohorts 1 and 2 pay the retired wallets (the leaked treasury among
    /// them), so either one open on chain refuses, and no note calls it the owner's decision.
    func testAnUnpausedCohortOtherThanCohortThreeRefuses() throws {
        for cohort in [MomentLink.Cohort.c1, .c2] {
            let (status, output) = try check(replacing(cohort) { $0.paused = false })
            XCTAssertEqual(status, 1, output)
            XCTAssertTrue(output.contains("Moments cohort \(cohort) (\(cohort.factory.hex)): publishing is not paused on chain"), output)
            XCTAssertFalse(output.contains("Moments cohort \(cohort) (\(cohort.factory.hex)): publishing is open on chain"), output)
            XCTAssertFalse(output.contains("publishing open on \(cohort)"), output)
        }
    }

    /// A Moment published on the open cohort 3 after its pin: the pin and the coin table must both grow before a release.
    func testAMomentPastThePinRefuses() throws {
        let late = Address(literal: "0x00000000000000000000000000000000000c0102")
        let (status, output) = try check(replacing(.c3) { $0.coins.append(late) })
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("momentCount() is 2 on chain but MomentLink.Cohort.c3.finalMomentCount pins 1"), output)
        XCTAssertTrue(output.contains("Moment #2's coin \(late.hex) is not in MomentsAddresses.retiredMainnetCoins"), output)
    }

    func testACoinTheTableGetsWrongRefuses() throws {
        let other = Address(literal: "0x00000000000000000000000000000000000c0201")
        let pinned = try XCTUnwrap(MomentsAddresses.retiredMainnetCoins.first { $0.value == MomentKey(factory: MomentLink.Cohort.c2.factory, id: 1) }?.key)
        let (status, output) = try check(replacing(.c2) { $0.coins[0] = other })
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("Moment #1's coin \(other.hex) is not in MomentsAddresses.retiredMainnetCoins"), output)
        XCTAssertTrue(output.contains("retiredMainnetCoins names \(pinned.hex) as #1, which the chain does not"), output)
    }

    /// A cohort that cannot be read is not proven final.
    func testAnUnreadableCohortRefuses() throws {
        let (status, output) = try check(replacing(.c1) { $0.unreadable = [MomentsABI.Factory.momentCount] })
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("Moments cohort c1 (\(MomentLink.Cohort.c1.factory.hex)) could not be read on chain"), output)
    }

    // MARK: The live stacks

    private func checkLive(_ change: (inout LiveChain) throws -> Void) throws -> (status: Int32, output: String) {
        var live = try LiveChain.wired()
        try change(&live)
        return try check(Self.current(), live: live)
    }

    /// A promoted record (with Swift that matches it) whose factory has no code on Monad, like the simulated
    /// `dryrun-143.json`: refused, once, without reading its getters.
    func testALiveFactoryWithoutCodeRefuses() throws {
        let l = LaunchpadAddresses.monadMainnet
        let (status, output) = try checkLive { $0.code[LiveChain.code(l.factory)] = "0x" }
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("LaunchpadAddresses.monadMainnet.factory \(l.factory.hex) has no code on chain"), output)
        XCTAssertFalse(output.contains("hook() could not be read"), output)
    }

    /// A module the table names that is not the factory's (another stack's collect), and an owner other than the record's.
    func testAGetterNamingAnotherContractRefuses() throws {
        let m = MomentsAddresses.monadMainnet
        let l = LaunchpadAddresses.monadMainnet
        let other = MomentsAddresses.retiredMainnet[0].collect
        let stranger = Address(literal: "0x00000000000000000000000000000000000c0301")
        let (status, output) = try checkLive {
            $0.getters[LiveChain.getter(m.factory, "collect()")] = try ABI.encode([.address(other)], "address")
            $0.getters[LiveChain.getter(l.factory, "owner()")] = try ABI.encode([.address(stranger)], "address")
        }
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("live Moments factory \(m.factory.hex): collect() is \(other.hex) on chain, but MomentsAddresses.monadMainnet says \(m.collect.hex)"), output)
        XCTAssertTrue(output.contains("live launchpad factory \(l.factory.hex): owner() is \(stranger.hex) on chain, but 143.json says"), output)
    }

    /// Unsealed modules, a policy paying another platform, and a link base other than c4's each refuse.
    func testTheFactoriesTermsMustMatchTheTables() throws {
        let m = MomentsAddresses.monadMainnet
        let l = LaunchpadAddresses.monadMainnet
        let (status, output) = try checkLive {
            $0.getters[LiveChain.getter(l.factory, "modulesSealed()")] = try ABI.encode([.bool(false)], "bool")
            $0.getters[LiveChain.getter(m.factory, MomentsABI.Factory.policy)] = try ABI.encode(
                [.uint(771_428_571), .uint(100_000), .uint(2_000), .uint(500), .uint(7_500), .uint(1_000), .uint(7_000), .uint(500), .address(m.treasury), .address(m.treasury)],
                MomentsABI.policyFlat)
            $0.getters[LiveChain.getter(m.factory, MomentsABI.Factory.externalBaseURI)] = try ABI.encode([.string("https://dyorhq.fun/moments/")], "string")
        }
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("modulesSealed() is not true on chain"), output)
        XCTAssertTrue(output.contains("policy() pays platform \(m.treasury.hex), but MomentsAddresses.monadMainnet says \(m.platform.hex)"), output)
        XCTAssertTrue(output.contains("externalBaseURI() is 'https://dyorhq.fun/moments/' on chain, but the c4 link base is '\(MomentsAddresses.expectedExternalBaseURI)'"), output)
    }

    /// A deployBlock that is not the factory's creation block (code already one block before it) refuses, and so does a
    /// getter the RPC cannot serve.
    func testTheDeployBlockAndEveryReadAreProven() throws {
        let m = MomentsAddresses.monadMainnet
        let (status, output) = try checkLive {
            $0.code[LiveChain.code(m.factory, at: m.deployBlock - 1)] = "0x6080"
            $0.getters[LiveChain.getter(m.factory, "buyback()")] = nil
        }
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("moments-143.json's deployBlock \(m.deployBlock) is not the block that created it (code at \(m.deployBlock - 1): yes; at \(m.deployBlock): yes)"), output)
        XCTAssertTrue(output.contains("live Moments factory \(m.factory.hex): buyback() could not be read on chain"), output)
    }

    // MARK: The docs page

    /// The page as published on 2026-09-29: the retired 0x6B1C and cohort 3 as the current factories, none of v2's
    /// contracts. Refused, naming each missing contract and each retired factory it presents as current.
    func testAPageListingTheRetiredStacksRefuses() throws {
        let l = LaunchpadAddresses.monadMainnet
        let m = MomentsAddresses.monadMainnet
        let page = Self.docsPage(current: [("LaunchpadFactory", V2WiringTests.relaunchFactory), ("MomentsFactory", V2WiringTests.cohort3Factory)])
        let (status, output) = try check(Self.current(), docs: page)
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("does not list: LaunchpadAddresses.monadMainnet.factory \(l.factory.hex), LaunchpadAddresses.monadMainnet.router \(l.router.hex)"), output)
        XCTAssertTrue(output.contains("MomentsAddresses.monadMainnet.buyback \(m.buyback.hex). Publish the docs update"), output)
        XCTAssertTrue(output.contains("presents \(V2WiringTests.relaunchFactory.hex) (a retired one) as the current LaunchpadFactory, not LaunchpadAddresses.monadMainnet's \(l.factory.hex)"), output)
        XCTAssertTrue(output.contains("presents \(V2WiringTests.cohort3Factory.hex) (a retired one) as the current MomentsFactory, not MomentsAddresses.monadMainnet's \(m.factory.hex)"), output)
    }

    /// Every contract listed is not enough: a page whose first factory rows are the retired ones still refuses, and so
    /// does a page that cannot be read.
    func testThePagesCurrentFactoriesMustBeThisBuilds() throws {
        let reordered = try check(Self.current(), docs: Self.docsPage(previousFirst: true))
        XCTAssertEqual(reordered.status, 1, reordered.output)
        XCTAssertFalse(reordered.output.contains("does not list"), reordered.output)
        XCTAssertTrue(reordered.output.contains("presents \(V2WiringTests.relaunchFactory.hex) (a retired one) as the current LaunchpadFactory"), reordered.output)
        let unread = try check(Self.current(), docs: nil)
        XCTAssertEqual(unread.status, 1, unread.output)
        XCTAssertTrue(unread.output.contains("the docs page \(DocsLinks.contractsAndAddresses.url.absoluteString) could not be read"), unread.output)
    }

    /// The gate reads the page Get Help's Contracts & Addresses row opens.
    func testTheGateReadsThePageGetHelpOpens() throws {
        let script = try String(contentsOf: try script(), encoding: .utf8)
        XCTAssertTrue(script.contains("DOCS_CONTRACTS_PAGE = \"\(DocsLinks.contractsAndAddresses.url.absoluteString)\"\n"))
    }

    /// Canned answers never stand in for the chain in a release, and a mistyped flag never runs a lesser check.
    func testAReleaseReadsTheChainItself() throws {
        let refused = try run(["--release", "--chain-fixture", "/dev/null"])
        XCTAssertEqual(refused.status, 1, refused.output)
        XCTAssertTrue(refused.output.contains("REFUSING"), refused.output)
        let typo = try run(["--relase"])
        XCTAssertEqual(typo.status, 1, typo.output)
        XCTAssertTrue(typo.output.contains("unknown: --relase"), typo.output)
    }
}
#endif
