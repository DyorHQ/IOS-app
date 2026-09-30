import BigInt
import XCTest
@testable import DyorKit

/// A retired cohort is read by its pinned Moments (`MomentLink.Cohort.finalMomentCount`, the coins in
/// `MomentsAddresses.retiredMainnetCoins`): cohort 3's publishing isn't paused on chain, and however many Moments are
/// published there after the pin, none of them can push a pinned Moment off the list and hide what its holders are owed.
/// Uses `RetiredMoments` calls only, so the same file shows what earlier builds answered.
final class RetiredMomentsPinTests: XCTestCase {
    private static let cohort3 = MomentsAddresses.retiredMainnet.first { $0.factory == MomentLink.Cohort.c3.factory }!
    private static let holder = Address(literal: "0x00000000000000000000000000000000000c0113")

    /// "Nature" (#1, pinned) and `later` Moments published after it; the holder holds Nature's edition.
    private func install(later: Int) -> FakeMomentsStack {
        let stack = FakeMomentsStack(addresses: Self.cohort3, policy: V2Fixture.policy(termsHash: nil), factoryBase: "", nftBase: "",
                                     names: ["Nature"] + (0..<later).map { "Later \($0)" })
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            func is_(_ s: String) -> Bool { selector == ABI.selector(s) }
            let args = ABIWords(data.dropFirst(4))
            if to == stack.addresses.vesting, is_(MomentsABI.Vesting.entitlement) || is_(MomentsABI.Vesting.claimed) || is_(MomentsABI.Vesting.creatorClaimed) {
                return try! ABI.encode([.uint(0)], "uint256")
            }
            if to == stack.addresses.vesting, is_(MomentsABI.Vesting.claimable) { return try! ABI.encode([.uint(0), .uint(0)], "uint256,uint256") }
            if is_(MomentsABI.NFT.balanceOf) || is_(MomentsABI.Coin.balanceOf) {
                return try! ABI.encode([.uint(to == stack.nft(1) && args.address(0) == Self.holder ? 1 : 0)], "uint256")
            }
            if to == stack.addresses.hook { return try! ABI.encode([.uint(0)], "uint256") }
            return stack.answer(to, data)
        }
        return stack
    }

    func testAPinnedMomentIsReadHoweverManyArePublishedAfterIt() async throws {
        let stack = install(later: 200)
        let cohort = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let moments = try await cohort.moments()
        XCTAssertTrue(moments.contains { $0.id == 1 && $0.name == "Nature" }, "the pinned Moment is read")
        let positions = try await cohort.positions(account: Self.holder)
        XCTAssertEqual(positions.map(\.key), [MomentKey(factory: stack.addresses.factory, id: 1)], "its holder's edition is listed")
    }

    func testMomentsAfterThePinAreStillReadWhenFew() async throws {
        let stack = install(later: 2)
        let cohort = RetiredMoments(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let moments = try await cohort.moments()
        XCTAssertEqual(moments.map(\.id), [3, 2, 1], "newest first, the pinned Moment included")
    }
}
