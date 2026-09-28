import BigInt
import Foundation

/* Retired launchpads (`LaunchpadAddresses.retiredStacks`: 0x6B1C…, 0x10F3…, 0x2F02…, 0xad3d…) are SELL-ONLY (owner
   decision 2026-09-28). A coin still on a retired launchpad's bonding curve — climbing, completed but not graduated, or
   in refund mode — can be sold by its holders, and nobody can buy it: no curve buy, no developer buy through a retired
   router's `launchAndBuy`, and no swap that buys it. Each layer refuses on its own:

     - the plan builders (`LaunchpadService.buyPlan`, `launchPlan`): nothing is built, not even the approval;
     - the coin page offers Sell only (in refund mode too), and Home's token page and the Portfolio's holdings send a
       holder to that page, where the curve sell is: no Swap venue routes a bonding curve
       (`LaunchpadService.retiredLaunch(token:)`, `retiredCurveHoldings`);
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

    /// Home's token page, for a sell-only coin: it sells on its curve, from its Launch page, never through Swap.
    public static let sellOnLaunchPage = "This coin's launchpad is retired: you can sell it on its Launch page, but not buy."

    /// Home's token page, for a sell-only coin whose completed curve waits to graduate (or is migrating): nothing trades
    /// until it graduates, and then it trades both ways on Swap.
    public static let graduationPending = "This coin's launchpad is retired and its graduation is pending: it can't be traded until it graduates."

    /// What Home's token page says under a coin Swap refuses to buy, from its launch on the retired launchpad (`launch` nil
    /// when it couldn't be read): where to sell it, or, while its curve takes no sells, that it waits for its graduation.
    /// Nil once it graduated: it trades both ways on Swap.
    public static func tokenPageNotice(_ launch: Launch?) -> String? {
        guard let launch else { return sellOnLaunchPage }
        guard launch.isSellOnly else { return nil }
        return launch.curveSellsOpen ? sellOnLaunchPage : graduationPending
    }

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

/// A wallet's coins still on a retired launchpad's curve (`LaunchpadService.retiredCurveHoldings`), and their launches.
public struct RetiredCurveHoldings: Sendable, Equatable {
    /// The coins: Swap can't trade them, so a screen never offers it for one.
    public let coins: Set<Address>
    /// Their launches, by coin, for a screen to open their Launch page. A coin whose launch couldn't be read has none.
    public let launches: [Address: Launch]

    public init(coins: Set<Address>, launches: [Address: Launch]) {
        self.coins = coins
        self.launches = launches
    }
}

public extension LaunchpadService {
    /// The coins among a wallet's `holdings` still on a retired launchpad's curve, each with its launch, so a list of
    /// holdings (the Portfolio) opens a coin's Launch page, where the curve sell is, instead of Swap, which can't trade
    /// it: Swap refuses to buy it, and no venue routes a bonding curve. Home's token page does the same for one coin.
    /// One aggregate asks every retired factory for each coin's record, the check `SwapEngine.buyRefusal` makes (MON and
    /// the app's own tokens are never asked); then each such coin's launch is read (`retiredLaunch(token:)`). A coin
    /// that graduated since the check is left out. Throws when the aggregate fails: then no coin could be ruled in or out.
    func retiredCurveHoldings(_ holdings: [Token]) async throws -> RetiredCurveHoldings {
        var seen = Set<Address>()
        let candidates = holdings.filter { SwapEngine.mayBeLaunchCoin($0) && seen.insert($0.address).inserted }.map(\.address)
        guard !candidates.isEmpty else { return RetiredCurveHoldings(coins: [], launches: [:]) }
        let coins = try await RetiredLaunchpad.sellOnlyCoins(candidates, multicall: multicall)
        var launches: [Address: Launch] = [:]
        await withTaskGroup(of: (Address, Launch?).self) { group in
            for coin in coins { group.addTask { (coin, try? await self.retiredLaunch(token: coin)) } }
            for await (coin, launch) in group { if let launch { launches[coin] = launch } }
        }
        // Graduated since the check: an ordinary pool token again, which Swap trades both ways.
        let graduated = Set(launches.filter { !$0.value.isSellOnly }.keys)
        return RetiredCurveHoldings(coins: coins.subtracting(graduated), launches: launches.filter { !graduated.contains($0.key) })
    }

    /// `RetiredLaunchpad.curves(among:)` on this service's chain: what a passkey session needs to refuse a buy on a
    /// retired launchpad (`Mera.SigningPolicy.refusal`).
    func retiredCurves(among candidates: Set<Address>) async -> Mera.SigningPolicy.RetiredCurves {
        await RetiredLaunchpad.curves(among: candidates, multicall: multicall)
    }
}
