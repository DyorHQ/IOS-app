import XCTest
@testable import DyorKit

/// The launchpad addresses baked into DyorKit must be the ones the contracts repo records for Monad mainnet, so a
/// redeploy can never leave the app on a retired (pre-audit) factory without this test saying so.
final class LaunchpadDeploymentTests: XCTestCase {
    func testMainnetAddressesMatchDeploymentRecord() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios → repo root
        url.appendPathComponent("contracts/deployments/143.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("contracts/deployments/143.json is not in this checkout") }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
    }
}
