import BigInt
import Foundation

/// Uniswap on Monad: v3 pools through SwapRouter02 and v4 pools (hookless canonical pools plus graduated
/// launchpad pools) through the Universal Router. Quotes come from QuoterV2 and V4Quoter; the better one is offered.
struct UniswapVenue: Sendable {
    let multicall: Multicall
    let v3: V3Router
    /// The launchpad factory whose graduated pools are routable; nil until it is deployed.
    let launchpadFactory: Address?
    /// The Moments contracts whose graduated coin ↔ USDC pools are routable; nil when Moments are not live.
    let moments: MomentsAddresses?

    init(multicall: Multicall, v3: V3Router, launchpadFactory: Address?, moments: MomentsAddresses? = nil) {
        self.multicall = multicall
        self.v3 = v3
        self.launchpadFactory = launchpadFactory
        self.moments = moments
    }

    static let v3Venue = V3Venue(factory: Uniswap.v3Factory, quoter: Uniswap.quoterV2, tiers: Uniswap.v3FeeTiers)

    private struct V4Candidate: Sendable {
        let hops: [V4Hop]
        let amountOut: BigUInt
        let gas: BigUInt
    }

    private enum Chosen: Sendable {
        case v3(V3Candidate)
        case v4(V4Candidate)
    }

    func quote(_ req: SwapRequest) async throws -> VenueQuote? {
        let tokenIn = req.tokenIn.wrappedAddress
        let tokenOut = req.tokenOut.wrappedAddress
        guard tokenIn != tokenOut else { return nil }
        let nativeIn = req.tokenIn.isNative
        let nativeOut = req.tokenOut.isNative
        // v4 pools hold native MON directly; WMON legs stay on v3.
        let v4Eligible = req.tokenIn.address != Monad.wmon && req.tokenOut.address != Monad.wmon
        async let v3Search = v3.bestRouteOrNil(on: Self.v3Venue, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: req.amountIn)
        async let v4Search = bestV4OrNil(eligible: v4Eligible, currencyIn: req.tokenIn.address, currencyOut: req.tokenOut.address, amountIn: req.amountIn)
        let (v3Best, v4Best) = await (v3Search, v4Search)

        let chosen: Chosen
        switch (v3Best, v4Best) {
        case (nil, nil): return nil
        case (let v3?, nil): chosen = .v3(v3)
        case (nil, let v4?): chosen = .v4(v4)
        case (let v3?, let v4?): chosen = v4.amountOut >= v3.amountOut ? .v4(v4) : .v3(v3)
        }

        var symbols = [req.tokenIn.symbol]
        if let v3Best, v3Best.route.path.count == 3 { symbols.append(V3Router.hopSymbol(v3Best.route.path[1])) }
        symbols.append(req.tokenOut.symbol)

        let amountOut: BigUInt
        let gas: BigUInt
        let route: String
        let priceImpactBps: Int?
        switch chosen {
        case .v4(let v4):
            amountOut = v4.amountOut
            gas = v4.gas
            route = Self.describeV4(v4.hops, symbolIn: req.tokenIn.symbol, symbolOut: req.tokenOut.symbol, momentsHook: moments?.hook)
            let slice = req.amountIn / 1000
            if slice > 0, let sliceOut = try? await quoteV4Once(currencyIn: req.tokenIn.address, hops: v4.hops, amountIn: slice) {
                priceImpactBps = SwapMath.impactBps(amountIn: req.amountIn, amountOut: amountOut, sliceIn: slice, sliceOut: sliceOut)
            } else {
                priceImpactBps = nil
            }
        case .v3(let candidate):
            amountOut = candidate.amountOut
            gas = candidate.gas
            route = "v3 · " + V3Router.describe(candidate.route, symbols: symbols)
            priceImpactBps = await v3.priceImpact(on: Self.v3Venue, route: candidate.route, amountIn: req.amountIn, amountOut: amountOut)
        }
        let minOut = SwapMath.minAfterSlippage(amountOut, bps: req.slippageBps)
        let multicall = self.multicall
        let inToken = req.tokenIn
        let outAddress = req.tokenOut.address
        let amountIn = req.amountIn

        return VenueQuote(venue: .uniswap, amountOut: amountOut, minOut: minOut, route: route, gasEstimate: gas, priceImpactBps: priceImpactBps) { account in
            let deadline = BigUInt(SwapMath.nowSeconds + SwapCalldata.deadlineSeconds)
            var steps: [TransactionStep] = []
            switch chosen {
            case .v4(let v4):
                if !nativeIn {
                    steps.append(.approve(token: inToken.address, spender: Uniswap.permit2, amount: SwapCalldata.maxUint160, label: "Approve \(inToken.symbol) for Permit2"))
                    if let permit = try await Self.permit2Step(multicall: multicall, owner: account, token: inToken, amount: amountIn) { steps.append(permit) }
                }
                let request = try SwapCalldata.universalRouterV4(currencyIn: inToken.address, currencyOut: outAddress, hops: v4.hops, amountIn: amountIn, minOut: minOut, deadline: deadline)
                steps.append(.call(request, label: "Swap on Uniswap v4"))
            case .v3(let candidate):
                if !nativeIn { steps.append(.approve(token: inToken.address, spender: Uniswap.swapRouter02, amount: amountIn, label: "Approve \(inToken.symbol) for Uniswap")) }
                let request = try SwapCalldata.swapRouter02(route: candidate.route, amountIn: amountIn, minOut: minOut, account: account, nativeIn: nativeIn, nativeOut: nativeOut, deadline: deadline)
                steps.append(.call(request, label: "Swap on Uniswap v3"))
            }
            return steps
        }
    }

    /// The Permit2 approval for the Universal Router, or nil when the existing one still covers the amount for
    /// more than two minutes. The web app performs this check while running the plan; here it is part of building it.
    static func permit2Step(multicall: Multicall, owner: Address, token: Token, amount: BigUInt) async throws -> TransactionStep? {
        let allowance = try await multicall.readAll([try SwapCalldata.permit2Allowance(owner: owner, token: token.address, spender: Uniswap.universalRouter)])[0]
        let now = SwapMath.nowSeconds
        if allowance[0].uint >= amount, allowance[1].uint > BigUInt(now + 120) { return nil }
        let data = try SwapCalldata.permit2Approve(token: token.address, spender: Uniswap.universalRouter, amount: amount, expiration: BigUInt(now + 30 * 24 * 3600))
        return .call(TransactionRequest(to: Uniswap.permit2, data: data), label: "Allow the Universal Router to spend \(token.symbol)")
    }

    // MARK: v4 routing

    private func bestV4OrNil(eligible: Bool, currencyIn: Address, currencyOut: Address, amountIn: BigUInt) async -> V4Candidate? {
        guard eligible else { return nil }
        return (try? await bestV4(currencyIn: currencyIn, currencyOut: currencyOut, amountIn: amountIn)) ?? nil
    }

    private func bestV4(currencyIn: Address, currencyOut: Address, amountIn: BigUInt) async throws -> V4Candidate? {
        let routes = try await v4Routes(currencyIn: currencyIn, currencyOut: currencyOut)
        if routes.isEmpty { return nil }
        let results = try await multicall.read(try routes.map { try SwapCalldata.v4Quote(currencyIn: currencyIn, hops: $0, amountIn: amountIn) })
        var best: V4Candidate?
        for (i, result) in results.enumerated() {
            guard case .success(let values) = result else { continue }
            let amountOut = values[0].uint
            if best.map({ amountOut > $0.amountOut }) ?? true { best = V4Candidate(hops: routes[i], amountOut: amountOut, gas: values[1].uint) }
        }
        return best
    }

    private func quoteV4Once(currencyIn: Address, hops: [V4Hop], amountIn: BigUInt) async throws -> BigUInt {
        try await multicall.readAll([try SwapCalldata.v4Quote(currencyIn: currencyIn, hops: hops, amountIn: amountIn)])[0][0].uint
    }

    /// Candidate v4 routes: hookless canonical pools (direct and through native MON), graduated launchpad pools,
    /// and graduated Moment pools (coin ↔ USDC, reached directly or through a canonical USDC pool).
    private func v4Routes(currencyIn cIn: Address, currencyOut cOut: Address) async throws -> [[V4Hop]] {
        let canonical = { (a: Address, b: Address) in Uniswap.v4Tiers.map { PoolKey.canonical(a, b, fee: $0.fee, tickSpacing: $0.tickSpacing) } }
        let viaNative = !cIn.isZero && !cOut.isZero
        let usdc = moments?.usdc ?? Monad.usdc
        // Probe layout: [0,4) direct, [4,8) in→MON, [8,12) MON→out, [12,16) in→USDC, [16,20) USDC→out (the latter
        // two pad with the direct pools when a side already is USDC, so the offsets stay fixed).
        let probe = canonical(cIn, cOut)
            + (viaNative ? canonical(cIn, Monad.native) + canonical(Monad.native, cOut) : canonical(cIn, cOut) + canonical(cIn, cOut))
            + (cIn != usdc ? canonical(cIn, usdc) : canonical(cIn, cOut))
            + (cOut != usdc ? canonical(usdc, cOut) : canonical(cIn, cOut))
        let liquidityCalls = try probe.map { try SwapCalldata.stateViewLiquidity(poolId: $0.id) }
        async let liquidityRead = multicall.read(liquidityCalls)
        async let launchRead = launchpadKeys([cIn, cOut])
        async let momentRead = momentsKeys([cIn, cOut])
        let (liquidity, launchKeys, momentKeys) = try await (liquidityRead, launchRead, momentRead)

        func alive(_ range: Range<Int>) -> [PoolKey] {
            probe.enumerated().filter { range.contains($0.offset) }.compactMap { entry in
                guard case .success(let values) = liquidity[entry.offset], values[0].uint > 0 else { return nil }
                return entry.element
            }
        }
        let direct = alive(0..<4)
        let toNative = viaNative ? alive(4..<8) : []
        let fromNative = viaNative ? alive(8..<12) : []
        let toUSDC = cIn != usdc ? alive(12..<16) : []
        let fromUSDC = cOut != usdc ? alive(16..<20) : []
        func route(_ hops: [V4Hop?]) -> [V4Hop]? {
            let present = hops.compactMap { $0 }
            return present.count == hops.count ? present : nil
        }

        var routes: [[V4Hop]] = direct.compactMap { route([V4Hop(key: $0, from: cIn)]) }
        if viaNative {
            for a in toNative {
                for b in fromNative { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: b, from: Monad.native)]) { routes.append(r) } }
            }
        }
        // Launchpad pools pair a token with its quote asset; reach them directly or through native MON.
        for (token, key) in launchKeys {
            let quote = key.currency0 == token ? key.currency1 : key.currency0
            if cOut == token {
                if cIn == quote {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else if quote.isZero {
                    for a in toNative { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: key, from: Monad.native)]) { routes.append(r) } }
                }
            } else if cIn == token {
                if cOut == quote {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else if quote.isZero {
                    for b in fromNative { if let r = route([V4Hop(key: key, from: cIn), V4Hop(key: b, from: Monad.native)]) { routes.append(r) } }
                }
            }
        }
        // Moment pools pair a coin with USDC; reach them directly or through a canonical USDC pool.
        for (coin, key) in momentKeys {
            if cOut == coin {
                if cIn == usdc {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else {
                    for a in toUSDC { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: key, from: usdc)]) { routes.append(r) } }
                }
            } else if cIn == coin {
                if cOut == usdc {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else {
                    for b in fromUSDC { if let r = route([V4Hop(key: key, from: cIn), V4Hop(key: b, from: usdc)]) { routes.append(r) } }
                }
            }
        }
        return routes
    }

    /// Pool keys of graduated Moment coins among `tokens`, in input order.
    private func momentsKeys(_ tokens: [Address]) async throws -> [(coin: Address, key: PoolKey)] {
        guard let moments, moments.isDeployed else { return [] }
        let candidates = tokens.filter { !$0.isZero && $0 != moments.usdc && $0 != Monad.wmon }
        if candidates.isEmpty { return [] }
        let ids = try await multicall.read(try candidates.map { try SwapCalldata.momentIdByCoin(factory: moments.factory, coin: $0) })
        var coins: [(Address, BigUInt)] = []
        for (coin, result) in zip(candidates, ids) {
            guard case .success(let values) = result, values[0].uint > 0 else { continue }
            coins.append((coin, values[0].uint))
        }
        if coins.isEmpty { return [] }
        let keys = try await multicall.read(try coins.map { try SwapCalldata.momentsPoolKey(graduation: moments.graduation, momentId: $0.1) })
        var out: [(coin: Address, key: PoolKey)] = []
        for (entry, result) in zip(coins, keys) {
            guard case .success(let values) = result else { continue }
            let key = values[0]
            let poolKey = PoolKey(currency0: key[0].address, currency1: key[1].address, fee: Int(key[2].uint), tickSpacing: Int(key[3].int), hooks: key[4].address)
            guard !poolKey.hooks.isZero else { continue } // not graduated: no pool yet
            out.append((entry.0, poolKey))
        }
        return out
    }

    /// Pool keys of graduated launchpad tokens among `tokens`, in input order.
    private func launchpadKeys(_ tokens: [Address]) async throws -> [(token: Address, key: PoolKey)] {
        guard let factory = launchpadFactory, !factory.isZero else { return [] }
        let candidates = tokens.filter { !$0.isZero && $0 != Monad.wmon }
        if candidates.isEmpty { return [] }
        let records = try await multicall.read(try candidates.map { try SwapCalldata.launchedToken(factory: factory, token: $0) })
        let graduated = zip(candidates, records).compactMap { token, record -> Address? in
            guard case .success(let values) = record else { return nil }
            let launched = values[0]
            return launched[15].bool && launched[10].uint == 2 ? token : nil
        }
        if graduated.isEmpty { return [] }
        let keys = try await multicall.readAll(try graduated.map { try SwapCalldata.launchpadPoolKey(factory: factory, token: $0) })
        return zip(graduated, keys).map { token, values in
            let key = values[0]
            return (token, PoolKey(currency0: key[0].address, currency1: key[1].address, fee: Int(key[2].uint), tickSpacing: Int(key[3].int), hooks: key[4].address))
        }
    }

    /// "v4 · MON → USDC · 0.05%" / "v4 · USDC → MON → TOKEN · 0.05% + launchpad" / "v4 · USDC → COIN · moments 1.5%".
    static func describeV4(_ hops: [V4Hop], symbolIn: String, symbolOut: String, momentsHook: Address? = nil) -> String {
        var names = [symbolIn]
        for (i, hop) in hops.enumerated() {
            let middle = hop.currencyOut.isZero ? "MON" : (hop.currencyOut == Monad.usdc ? "USDC" : "…")
            names.append(i == hops.count - 1 ? symbolOut : middle)
        }
        let fees = hops.map { hop -> String in
            if hop.key.isHookless { return SwapMath.feeLabel(hop.key.fee) }
            if let momentsHook, hop.key.hooks == momentsHook { return "moments 1.5%" }
            return "launchpad"
        }.joined(separator: " + ")
        return "v4 · \(names.joined(separator: " → ")) · \(fees)"
    }
}
