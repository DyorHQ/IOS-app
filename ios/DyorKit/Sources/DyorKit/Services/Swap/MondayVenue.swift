import BigInt
import Foundation

/// Monday Trade spot: concentrated-liquidity pools with an embedded order book, exposed through a Uniswap-v3-style
/// QuoterV2 and a SwapRouter with the v1 layout (deadline inside the params, `multicall(bytes[])`).
struct MondayVenue: Sendable {
    let v3: V3Router

    static let venue = V3Venue(factory: MondayTrade.factory, quoter: MondayTrade.quoterV2, tiers: MondayTrade.feeTiers)

    func quote(_ req: SwapRequest) async throws -> VenueQuote? {
        let tokenIn = req.tokenIn.wrappedAddress
        let tokenOut = req.tokenOut.wrappedAddress
        guard tokenIn != tokenOut else { return nil }
        guard let best = try await v3.bestRoute(on: Self.venue, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: req.amountIn) else { return nil }
        let minOut = SwapMath.minAfterSlippage(best.amountOut, bps: req.slippageBps)
        let nativeIn = req.tokenIn.isNative
        let nativeOut = req.tokenOut.isNative
        var symbols = [req.tokenIn.symbol]
        if best.route.path.count == 3 { symbols.append(V3Router.hopSymbol(best.route.path[1])) }
        symbols.append(req.tokenOut.symbol)
        let priceImpactBps = await v3.priceImpact(on: Self.venue, route: best.route, amountIn: req.amountIn, amountOut: best.amountOut)
        let inToken = req.tokenIn
        let amountIn = req.amountIn

        return VenueQuote(venue: .monday, amountOut: best.amountOut, minOut: minOut, route: V3Router.describe(best.route, symbols: symbols), gasEstimate: best.gas, priceImpactBps: priceImpactBps) { account in
            var steps: [TransactionStep] = []
            if !nativeIn { steps.append(.approve(token: inToken.address, spender: MondayTrade.swapRouter, amount: amountIn, label: "Approve \(inToken.symbol) for Monday Trade")) }
            let deadline = BigUInt(SwapMath.nowSeconds + SwapCalldata.deadlineSeconds)
            let request = try SwapCalldata.mondaySwap(route: best.route, amountIn: amountIn, minOut: minOut, account: account, nativeIn: nativeIn, nativeOut: nativeOut, deadline: deadline)
            steps.append(.call(request, label: "Swap on Monday Trade"))
            return steps
        }
    }
}
