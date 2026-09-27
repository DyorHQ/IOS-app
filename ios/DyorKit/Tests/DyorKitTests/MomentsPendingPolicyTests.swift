import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// A policy proposed but not applied yet is read and compared with the live one, so the app can warn that a publish
/// may land under it (security audit 2026-09-26, MO-4).
final class MomentsPendingPolicyTests: XCTestCase {
    private let platform = Address(literal: "0x00000000000000000000000000000000000000a1")
    private let treasury = Address(literal: "0x00000000000000000000000000000000000000b2")

    func testSelectorsMatchFoundry() {
        // cast sig "pendingPolicy()" / "pendingPolicyAt()"
        XCTAssertEqual(ABI.selector(MomentsABI.Factory.pendingPolicy).hexString, "0xe6c5cf40")
        XCTAssertEqual(ABI.selector(MomentsABI.Factory.pendingPolicyAt).hexString, "0x15603e91")
    }

    private func current() -> MomentPolicy {
        MomentPolicy(threshold: 10_000_000, minPrice: 1_000_000, creatorBps: 2000, platformBps: 500, reserveBps: 7500, maxCreatorAllocBps: 1000,
                     expiryCreatorBps: 6000, royaltyBps: 500, platform: platform, treasury: treasury, momentCount: 3, publishingPaused: false, externalBaseURI: "")
    }

    private func pending(threshold: BigUInt = 10_000_000, creatorBps: Int = 2000, platformBps: Int = 500, royaltyBps: Int = 500,
                         treasury: Address? = nil, at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> PendingMomentPolicy {
        PendingMomentPolicy(threshold: threshold, minPrice: 1_000_000, creatorBps: creatorBps, platformBps: platformBps, reserveBps: 7500, maxCreatorAllocBps: 1000,
                            expiryCreatorBps: 6000, royaltyBps: royaltyBps, platform: platform, treasury: treasury ?? self.treasury, applicableAt: at)
    }

    func testAProposalThatRepeatsThePolicyChangesNothing() {
        XCTAssertEqual(pending().changes(from: current()), [])
    }

    func testChangedTermsAreListedInOrder() {
        let other = Address(literal: "0x00000000000000000000000000000000000000c3")
        let proposal = pending(threshold: 50_000_000, creatorBps: 1500, platformBps: 1000, royaltyBps: 750, treasury: other)
        XCTAssertEqual(proposal.changes(from: current()), [.threshold, .split, .royalty, .treasury])
    }

    func testApplicableFromItsTime() {
        let proposal = pending(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(proposal.isApplicable(at: Date(timeIntervalSince1970: 1_799_999_999)))
        XCTAssertTrue(proposal.isApplicable(at: Date(timeIntervalSince1970: 1_800_000_000)))
    }
}
