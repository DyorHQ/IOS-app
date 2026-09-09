import BigInt
import Foundation

/// A Uniswap-v3-style venue: a factory, a QuoterV2 and the fee tiers it enables. Shared by Uniswap v3 and Monday Trade.
struct V3Venue: Sendable {
    let factory: Address
    let quoter: Address
    let tiers: [Int]
}

struct V3Candidate: Sendable {
    let route: V3Route
    let amountOut: BigUInt
    let gas: BigUInt
}

/// Route search over v3-style pools: direct at the three deepest fee tiers, two-hop through `Token.hopTokens` at
/// the deepest tier per leg. Quoter simulations are the expensive part, so only those routes are quoted.
struct V3Router: Sendable {
    let multicall: Multicall

    /// The best single- or two-hop route, or nil when the venue has no pool for the pair.
    func bestRoute(on venue: V3Venue, tokenIn: Address, tokenOut: Address, amountIn: BigUInt) async throws -> V3Candidate? {
        let hops = Token.hopTokens.filter { $0 != tokenIn && $0 != tokenOut }
        var pairs: [(Address, Address)] = [(tokenIn, tokenOut)]
        for hop in hops { pairs += [(tokenIn, hop), (hop, tokenOut)] }
        let poolCalls = try pairs.flatMap { pair in try venue.tiers.map { try SwapCalldata.v3GetPool(factory: venue.factory, pair.0, pair.1, fee: $0) } }
        let pools = try await multicall.readAll(poolCalls).map { $0[0].address }
        let live = pools.enumerated().filter { !$0.element.isZero }
        if live.isEmpty { return nil }
        let liquidity = try await multicall.read(try live.map { try SwapCalldata.v3Liquidity(pool: $0.element) })
        var depth: [Int: BigUInt] = [:]
        for (k, entry) in live.enumerated() {
            if case .success(let values) = liquidity[k], values[0].uint > 0 { depth[entry.offset] = values[0].uint }
        }
        // Deepest tiers first; ties keep tier order, as the web app's stable sort does. Written as an explicit
        // loop so the Swift type-checker doesn't choke on a long tuple-returning chain.
        func tiers(forPair pairIndex: Int, take: Int) -> [Int] {
            var scored: [(fee: Int, depth: BigUInt, order: Int)] = []
            for (order, fee) in venue.tiers.enumerated() {
                let d = depth[pairIndex * venue.tiers.count + order] ?? 0
                if d > 0 { scored.append((fee: fee, depth: d, order: order)) }
            }
            scored.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.order < $1.order }
            return scored.prefix(take).map(\.fee)
        }
        var routes = tiers(forPair: 0, take: 3).map { V3Route(path: [tokenIn, tokenOut], fees: [$0]) }
        for (h, hop) in hops.enumerated() {
            for a in tiers(forPair: 1 + h * 2, take: 1) {
                for b in tiers(forPair: 2 + h * 2, take: 1) { routes.append(V3Route(path: [tokenIn, hop, tokenOut], fees: [a, b])) }
            }
        }
        if routes.isEmpty { return nil }
        let quotes = try await multicall.read(try routes.map { try SwapCalldata.quote(quoter: venue.quoter, route: $0, amountIn: amountIn) })
        var best: V3Candidate?
        for (i, quote) in quotes.enumerated() {
            guard case .success(let values) = quote else { continue }
            let amountOut = values[0].uint
            if best.map({ amountOut > $0.amountOut }) ?? true { best = V3Candidate(route: routes[i], amountOut: amountOut, gas: values[3].uint) }
        }
        return best
    }

    /// Like `bestRoute`, but a failed search counts as no route (what Uniswap's quote does).
    func bestRouteOrNil(on venue: V3Venue, tokenIn: Address, tokenOut: Address, amountIn: BigUInt) async -> V3Candidate? {
        (try? await bestRoute(on: venue, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn)) ?? nil
    }

    /// Marginal price check: quotes a 1/1000 slice of the trade and compares the rates. nil when unknown.
    func priceImpact(on venue: V3Venue, route: V3Route, amountIn: BigUInt, amountOut: BigUInt) async -> Int? {
        let slice = amountIn / 1000
        guard slice > 0, amountOut > 0 else { return nil }
        guard let call = try? SwapCalldata.quote(quoter: venue.quoter, route: route, amountIn: slice),
              let small = try? await multicall.readAll([call]).first?[0].uint else { return nil }
        return SwapMath.impactBps(amountIn: amountIn, amountOut: amountOut, sliceIn: slice, sliceOut: small)
    }

    /// "MON → USDC · 0.05%" / "USDC → WETH → MON · 0.05% + 0.3%".
    static func describe(_ route: V3Route, symbols: [String]) -> String {
        "\(symbols.joined(separator: " → ")) · \(route.fees.map(SwapMath.feeLabel).joined(separator: " + "))"
    }

    private static let hopSymbols: [Address: String] = [Monad.wmon: "WMON", Monad.usdc: "USDC", Monad.usdt0: "USDT0", Monad.weth: "WETH"]

    static func hopSymbol(_ address: Address) -> String { hopSymbols[address] ?? "…" }
}
