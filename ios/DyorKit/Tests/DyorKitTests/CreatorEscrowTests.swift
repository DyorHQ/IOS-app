import BigInt
import XCTest
@testable import DyorKit

/// A creator's fees wait in each launchpad's escrow, per pair asset. My Launchpad reads every escrow for MON and every
/// pair asset a launch can use (`LaunchpadService.escrowReads`), not only the pair assets of the created coins among the
/// launches it read: a creator whose USDC coin is older than the newest 100 launches (or whose launches couldn't be read)
/// still sees, and can claim, their USDC fees. An escrow that can't be read says so, never zero.
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
}
