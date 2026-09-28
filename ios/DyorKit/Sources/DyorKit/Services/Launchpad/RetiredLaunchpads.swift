import BigInt
import Foundation

/* Retired launchpads (`LaunchpadAddresses.retiredStacks`: 0x6B1C…, 0x10F3…, 0x2F02…, 0xad3d…) are SELL-ONLY (owner
   decision 2026-09-28). A coin still on a retired launchpad's bonding curve — climbing, completed but not graduated, or
   in refund mode — can be sold by its holders, and nobody can buy it: no curve buy, and no developer buy through a
   retired router's `launchAndBuy`. The plan builders refuse both (`LaunchpadService.buyPlan`, `launchPlan`), so nothing
   is built, not even the approval, and the coin page offers Sell only.

   A coin that GRADUATED from a retired stack into a Monday Trade or Uniswap v4 pool is an ordinary pool token and trades
   both ways. The live stack (v2) is unaffected. */

public extension LaunchpadAddresses {
    /// Whether `factory` is one of the retired launchpads, whose curves take sells only.
    static func isRetired(_ factory: Address) -> Bool {
        !factory.isZero && retiredStack(for: factory) != nil
    }

    /// The retired stacks' routers: a `launchAndBuy` on one would be a developer buy on a retired curve.
    static var retiredRouters: [Address] { retiredStacks.map(\.router) }
}

/// What the app says and checks about the retired launchpads' coins.
public enum RetiredLaunchpad {
    /// What every screen says where a buy of such a coin is refused.
    public static let notice = "This coin's launchpad is retired: you can sell, but not buy."
}
