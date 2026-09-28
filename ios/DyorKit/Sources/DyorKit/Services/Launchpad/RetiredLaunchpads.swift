import BigInt
import Foundation

/* Retired launchpads (`LaunchpadAddresses.retiredStacks`: 0x6B1C…, 0x10F3…, 0x2F02…, 0xad3d…) are SELL-ONLY (owner
   decision 2026-09-28). A coin still on a retired launchpad's bonding curve — climbing, completed but not graduated, or
   in refund mode — can be sold by its holders, and nobody can buy it: no curve buy, no developer buy through a retired
   router's `launchAndBuy`, and no swap that buys it. Each layer refuses on its own:

     - the plan builders (`LaunchpadService.buyPlan`, `launchPlan`): nothing is built, not even the approval;
     - the coin page offers Sell only, and Home's token page opens Swap on the sell side;
     - Swap (`SwapEngine.buyRefusal`): no venue is asked to quote buying such a coin, read on-chain from every retired
       factory's record; a read that fails refuses too. Selling one is never checked.

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

    // MARK: Coins bought (Swap)

    /// The coins among `tokens` still on a retired launchpad's side of graduation, from every retired factory's
    /// `getLaunchedToken` record (each in its own layout) in one Multicall3 read. A factory answers an unknown token with
    /// an empty record, so a failed read, or any factory's answer missing, throws: then no coin can be ruled out.
    static func sellOnlyCoins(_ tokens: [Address], multicall: Multicall) async throws -> Set<Address> {
        let queries = tokens.flatMap { token in LaunchpadAddresses.retiredStacks.map { (token: token, stack: $0) } }
        guard !queries.isEmpty else { return [] }
        let results = try await multicall.read(queries.map {
            LaunchpadABI.call($0.stack.factory, LaunchpadABI.Factory.getLaunchedToken, [.address($0.token)],
                              returns: LaunchpadABI.launchedTokenReturns(legacy: $0.stack.generation.legacyRecord))
        })
        return try sellOnlyCoins(queries: queries.map { ($0.token, $0.stack.generation.legacyRecord) }, results: results)
    }

    /// Pure half of `sellOnlyCoins`: a coin is sell-only when a retired factory's record of it exists and it has no pool
    /// yet (bonding, migrating or refund mode). A graduated one trades both ways.
    static func sellOnlyCoins(queries: [(token: Address, legacy: Bool)], results: [Result<[ABIValue], Error>]) throws -> Set<Address> {
        guard results.count == queries.count else { throw LaunchpadError.unexpectedResponse("retired launchpad records") }
        var out = Set<Address>()
        for (query, result) in zip(queries, results) {
            guard case .success(let values) = result, let tuple = values.first else { throw LaunchpadError.unexpectedResponse("a retired launchpad record") }
            let record = LaunchpadABI.LaunchRecord(tuple, legacy: query.legacy)
            if record.exists, record.phase != .graduated { out.insert(query.token) }
        }
        return out
    }
}
