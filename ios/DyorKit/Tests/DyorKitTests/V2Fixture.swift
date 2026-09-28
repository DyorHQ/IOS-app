import BigInt
import Foundation
@testable import DyorKit

/// A made-up v2 deployment for tests. `LaunchpadAddresses.monadMainnet` stays all zero until the owner deploys v2, so a
/// test that needs a live v2 stack uses this instead. No address here is a real contract, a retired one, or another
/// fixture's.
enum V2Fixture {
    static let launchpad = LaunchpadAddresses(
        factory: Address(literal: "0x00000000000000000000000000000000c4f00001"),
        router: Address(literal: "0x00000000000000000000000000000000c4f00002"),
        escrow: Address(literal: "0x00000000000000000000000000000000c4f00003"),
        holderFeeSharing: Address(literal: "0x00000000000000000000000000000000c4f00004"),
        hook: Address(literal: "0x00000000000000000000000000000000c4f000cc"),
        poolManager: Uniswap.poolManager,
        generation: .v2
    )
}
