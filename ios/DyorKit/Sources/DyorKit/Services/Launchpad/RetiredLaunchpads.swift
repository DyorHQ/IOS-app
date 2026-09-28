import BigInt
import Foundation

/* Retired launchpads (`LaunchpadAddresses.retiredStacks`: 0x6B1C…, 0x10F3…, 0x2F02…, 0xad3d…) are SELL-ONLY (owner
   decision 2026-09-28). A coin still on a retired launchpad's bonding curve — climbing, completed but not graduated, or
   in refund mode — can be sold by its holders, and nobody can buy it: no curve buy, no developer buy through a retired
   router's `launchAndBuy`, and no swap that buys it. Each layer refuses on its own:

     - the plan builders (`LaunchpadService.buyPlan`, `launchPlan`): nothing is built, not even the approval;
     - the coin page offers Sell only, and Home's token page opens Swap on the sell side;
     - Swap (`SwapEngine.buyRefusal`): no venue is asked to quote buying such a coin, read on-chain from every retired
       factory's record; a read that fails refuses too. Selling one is never checked;
     - a passkey account (`Mera.SigningPolicy.refusal`): a curve `buy` into a curve a retired factory recorded
       (`curveToToken`, read on-chain here), an approval paying anything but the coin into one, and `launchAndBuy` on a
       retired router are refused whatever the sheet declared or a Face ID approved, even if some screen built one.

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

    // MARK: Curves paid into (passkey policy)

    /// Which of `candidates` a retired factory recorded as a launch's curve, each with its coin, for
    /// `Mera.SigningPolicy.refusal`: every factory generation keeps the public `curveToToken(curve)` mapping, so each
    /// candidate is asked of every retired factory in one Multicall3 read. `.unknown` when the read fails or any answer is
    /// missing: then no curve can be ruled out.
    public static func curves(among candidates: Set<Address>, multicall: Multicall) async -> Mera.SigningPolicy.RetiredCurves {
        let curves = candidates.filter { !$0.isZero }.sorted { $0.hex < $1.hex }
        guard !curves.isEmpty else { return .none }
        let factories = LaunchpadAddresses.retiredFactories
        let calls = curves.flatMap { curve in factories.map { LaunchpadABI.call($0, LaunchpadABI.Factory.curveToToken, [.address(curve)], returns: "address") } }
        guard let results = try? await multicall.read(calls) else { return .unknown }
        return Self.curves(candidates: curves, factories: factories, results: results)
    }

    /// Pure half of `curves(among:)`: `results` holds each candidate's answer from each factory, candidate-major. A
    /// candidate is a retired curve when some factory maps it to a coin.
    static func curves(candidates: [Address], factories: [Address], results: [Result<[ABIValue], Error>]) -> Mera.SigningPolicy.RetiredCurves {
        guard results.count == candidates.count * factories.count else { return .unknown }
        var out: [Address: Address] = [:]
        for (i, curve) in candidates.enumerated() {
            for j in factories.indices {
                guard case .success(let values) = results[i * factories.count + j], let coin = values.first?.address else { return .unknown }
                if !coin.isZero, out[curve] == nil { out[curve] = coin }
            }
        }
        return .known(out)
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

public extension LaunchpadService {
    /// `RetiredLaunchpad.curves(among:)` on this service's chain: what a passkey session needs to refuse a buy on a
    /// retired launchpad (`Mera.SigningPolicy.refusal`).
    func retiredCurves(among candidates: Set<Address>) async -> Mera.SigningPolicy.RetiredCurves {
        await RetiredLaunchpad.curves(among: candidates, multicall: multicall)
    }
}
