import BigInt
import XCTest
@testable import DyorKit

/// A creator's fees wait in each launchpad's escrow, per pair asset. My Launchpad reads every escrow for MON and every
/// pair asset a launch can use (`LaunchpadService.escrowReads`), not only the pair assets of the created coins among the
/// launches it read: a creator whose USDC coin is older than the newest 100 launches (or whose launches couldn't be read)
/// still sees, and can claim, their USDC fees. An escrow that can't be read says so, never zero, and keeps the balances
/// last read for the same wallet (`LaunchpadEscrowRead.keeping`), which Claim All leaves out.
final class CreatorEscrowTests: XCTestCase {
    private static let creator = Address(literal: "0x00000000000000000000000000000000000c7ea7")

    func testEveryPairAssetIsReadWhateverLaunchesWereRead() async throws {
        let live = V2Fixture.launchpad
        let brokenRetired = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first { !$0.escrow.isZero })
        MomentsChainStub.install({ to, data in
            let selector = data.prefix(4)
            let args = ABIWords(data.dropFirst(4))
            guard to == live.escrow || LaunchpadAddresses.retiredStacks.contains(where: { $0.escrow == to }) else { return nil }
            if selector == ABI.selector(LaunchpadABI.Escrow.balanceOf) { return try! ABI.encode([.uint(0)], "uint256") }
            if selector == ABI.selector(LaunchpadABI.Escrow.balanceOfToken) {
                let owed: BigUInt = to == live.escrow && args.address(0) == Self.creator && args.address(1) == Monad.usdc ? 5_000_000 : 0
                return try! ABI.encode([.uint(owed)], "uint256")
            }
            return nil
        }, breaking: [brokenRetired.escrow])
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: live)
        let reads = await service.escrowReads(account: Self.creator)
        XCTAssertEqual(reads.first?.escrow, live.escrow, "the live launchpad's escrow first")
        XCTAssertEqual(reads.first?.balances?.tokens[Monad.usdc], 5_000_000, "USDC fees, with no launch read")
        XCTAssertEqual(Set(reads.first?.balances?.tokens.keys.map { $0 } ?? []), Set(Token.launchpadPairAssets), "every pair asset a launch can use")
        XCTAssertEqual(reads.first { $0.escrow == brokenRetired.escrow }?.balances, nil, "an escrow that can't be read has no balances, not zero")
        XCTAssertEqual(reads.first { $0.escrow == brokenRetired.escrow }?.retired, true)
    }

    /// My Launchpad wires it in: every escrow read for every pair asset, before and whatever the launches read, and an
    /// escrow that can't be read makes the screen say it is incomplete.
    func testMyLaunchpadReadsEveryPairAsset() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadProfileView.swift"), encoding: .utf8)
        let read = try XCTUnwrap(source.range(of: "let escrowReads = await env.launchpad.escrowReads(account: address, extraPairTokens: createdPairs)"))
        let guardEmpty = try XCTUnwrap(source.range(of: "guard !launches.isEmpty else {"))
        XCTAssertLessThan(read.lowerBound, guardEmpty.lowerBound, "the escrows are read even when no launch could be")
        XCTAssertTrue(source.contains("if escrowReads.contains(where: { $0.balances == nil }) { unread = true }"))
        XCTAssertTrue(source.contains("let pairTokens = Set(launches.map(\\.pairToken)).union(Token.launchpadPairAssets).union([Monad.native])"))
        XCTAssertFalse(source.contains("pairsByEscrow"), "never only the pair assets of the created coins read")
    }

    private static let escrowA = Address(literal: "0x00000000000000000000000000000000000e5c0a")
    private static let escrowB = Address(literal: "0x00000000000000000000000000000000000e5c0b")
    private static let factory = Address(literal: "0x00000000000000000000000000000000000fac70")

    private static func read(_ escrow: Address, _ native: BigUInt?, kept: Bool = false) -> LaunchpadEscrowRead {
        LaunchpadEscrowRead(escrow: escrow, factory: factory, retired: escrow == escrowB, balances: native.map { EscrowBalances(native: $0, tokens: [:]) }, kept: kept)
    }

    /// An escrow read now shows what was read; one whose read failed keeps its last balances, marked `kept`, however many
    /// reads fail in a row; one never read stays unread. Never zero for a read that failed.
    func testAnEscrowThatCantBeReadKeepsItsLastBalances() {
        let first = LaunchpadEscrowRead.keeping([Self.read(Self.escrowA, 5), Self.read(Self.escrowB, 7)], previous: [])
        XCTAssertEqual(first, [Self.read(Self.escrowA, 5), Self.read(Self.escrowB, 7)])

        let second = LaunchpadEscrowRead.keeping([Self.read(Self.escrowA, 6), Self.read(Self.escrowB, nil)], previous: first)
        XCTAssertEqual(second, [Self.read(Self.escrowA, 6), Self.read(Self.escrowB, 7, kept: true)])

        let third = LaunchpadEscrowRead.keeping([Self.read(Self.escrowA, nil), Self.read(Self.escrowB, nil)], previous: second)
        XCTAssertEqual(third, [Self.read(Self.escrowA, 6, kept: true), Self.read(Self.escrowB, 7, kept: true)], "still the last balances read")

        let fourth = LaunchpadEscrowRead.keeping([Self.read(Self.escrowA, 0), Self.read(Self.escrowB, 1)], previous: third)
        XCTAssertEqual(fourth, [Self.read(Self.escrowA, 0), Self.read(Self.escrowB, 1)], "a read replaces what was kept")

        let never = LaunchpadEscrowRead.keeping([Self.read(Self.escrowA, nil)], previous: [])
        XCTAssertEqual(never, [Self.read(Self.escrowA, nil)], "nothing kept: unread, not zero")
    }

    /// My Launchpad keeps an escrow's balances only for the wallet they were read for, never plans Claim All on kept
    /// balances, and says fees couldn't be read (with Retry) rather than "Nothing to claim yet".
    func testMyLaunchpadKeepsFeesForTheSameWalletOnly() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadProfileView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("LaunchpadEscrowRead.keeping(escrowReads, previous: escrowsFor == address ? lastEscrowReads : [])"))
        XCTAssertTrue(source.contains("for holding in escrows where holding.current && !holding.balances.isEmpty"), "Claim All plans only escrows read in this load")
        XCTAssertTrue(source.contains("Creator fees couldn't be read just now."))
        XCTAssertFalse(source.contains("$0.balances ?? EscrowBalances(native: 0, tokens: [:])"), "a failed read is never zero")
    }
}
