import XCTest
@testable import DyorKit

/// The launchpad addresses baked into DyorKit must be the ones the contracts repo records for Monad mainnet, so a
/// redeploy can never leave the app on a retired (pre-audit) factory without this test saying so.
final class LaunchpadDeploymentTests: XCTestCase {
    /// A deployment record from `contracts/deployments/`, or a skip when this checkout has no contracts.
    private func deploymentRecord(_ name: String) throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → repo root
        url.appendPathComponent("contracts/deployments/\(name)")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("contracts/deployments/\(name) is not in this checkout") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMainnetAddressesMatchDeploymentRecord() throws {
        let record = try deploymentRecord("143.json")
        func address(_ key: String) throws -> Address { try XCTUnwrap(Address(try XCTUnwrap(record[key] as? String, key)), key) }

        let baked = LaunchpadAddresses.monadMainnet
        XCTAssertEqual(record["chainId"] as? Int, 143)
        XCTAssertTrue(baked.isDeployed)
        XCTAssertEqual(baked.factory, try address("factory"))
        XCTAssertEqual(baked.router, try address("launchAndBuyRouter"))
        XCTAssertEqual(baked.escrow, try address("escrow"))
        XCTAssertEqual(baked.holderFeeSharing, try address("holderFeeSharing"))
        XCTAssertEqual(baked.hook, try address("hook"))
        XCTAssertEqual(baked.poolManager, try address("poolManager"))
        XCTAssertEqual(baked.poolManager, Uniswap.poolManager)
    }

    func testMainnetIsNotTheRetiredFactory() {
        // The pre-audit deployment (2026-09-12) carried a live holder-reward drain; nothing may point at it again.
        XCTAssertNotEqual(LaunchpadAddresses.monadMainnet.factory, Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"))
        // Nor at any other retired factory: new launches always go to the live one.
        XCTAssertFalse(LaunchpadAddresses.retiredFactories.contains(LaunchpadAddresses.monadMainnet.factory))
        XCTAssertNil(LaunchpadAddresses.retiredStack(for: LaunchpadAddresses.monadMainnet.factory))
    }

    func testNewestRetiredStackMatchesDeploymentRecord() throws {
        let record = try deploymentRecord("143-retired-0x10F3.json")
        func address(_ key: String) throws -> Address { try XCTUnwrap(Address(try XCTUnwrap(record[key] as? String, key)), key) }

        let retired = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        XCTAssertEqual(record["chainId"] as? Int, 143)
        XCTAssertEqual(retired.factory, try address("factory"))
        XCTAssertEqual(retired.router, try address("launchAndBuyRouter"))
        XCTAssertEqual(retired.escrow, try address("escrow"))
        XCTAssertEqual(retired.holderFeeSharing, try address("holderFeeSharing"))
        XCTAssertEqual(retired.hook, try address("hook"))
        XCTAssertEqual(retired.poolManager, try address("poolManager"))
    }

    func testRetiredStackFlags() {
        let stacks = LaunchpadAddresses.retiredStacks
        XCTAssertEqual(stacks.map(\.factory), [
            Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
            Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea"),
        ])
        XCTAssertEqual(stacks.map(\.hasQueuedRewards), [true, false, false])
        XCTAssertEqual(stacks.map(\.hasGraduateFallback), [true, false, false])
        XCTAssertEqual(stacks.map(\.legacyRecord), [false, false, true])
        XCTAssertTrue(stacks.allSatisfy { $0.poolManager == Uniswap.poolManager })
        XCTAssertFalse(LaunchpadAddresses.monadMainnet.legacyRecord)
        XCTAssertTrue(LaunchpadAddresses.monadMainnet.hasQueuedRewards)
        // No stack, live or retired, shares a module with another.
        let modules = ([LaunchpadAddresses.monadMainnet] + stacks).flatMap { [$0.factory, $0.router, $0.escrow, $0.holderFeeSharing, $0.hook] }
        XCTAssertEqual(Set(modules).count, modules.count)
    }
}
