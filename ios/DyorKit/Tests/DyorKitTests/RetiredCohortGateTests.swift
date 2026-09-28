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
/// Here the script runs against canned eth_call answers built from the compiled constants (its `--chain-fixture` mode,
/// which it refuses together with `--release`): the chain as it is passes, so the script reads the sources the way the
/// app compiles them, and each way a cohort can drift from its pin refuses.
final class RetiredCohortGateTests: XCTestCase {
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

    static func fixture(_ cohorts: [ChainCohort]) throws -> Data {
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
        return try JSONSerialization.data(withJSONObject: ["block": 108_778_342, "calls": calls], options: [.sortedKeys])
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

    private func check(_ cohorts: [ChainCohort]) throws -> (status: Int32, output: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retired-cohorts-\(UUID().uuidString).json")
        try Self.fixture(cohorts).write(to: file)
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
        XCTAssertTrue(output.contains("OK: retired Moments cohorts at their pins at fixture block 108778342 (\(pins))\n"), output)
        XCTAssertFalse(output.contains("note:"), output)
    }

    /// Cohort 3 as the owner left it (2026-09-28): publishing open on chain, its count at its pin. The archive passes, and
    /// the open cohort is named in a note, not a problem.
    func testAnUnpausedRetiredCohortAtItsPinPasses() throws {
        let (status, output) = try check(Self.current())
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("note: Moments cohort c3 (\(MomentLink.Cohort.c3.factory.hex)): publishing is open on chain"), output)
        XCTAssertTrue(output.contains("; publishing open on c3\n"), output)
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
