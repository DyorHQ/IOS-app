import BigInt
import Foundation

public struct PriceInfo: Hashable, Sendable {
    public let usd: Double
    /// Percent change over the last 24 hours; nil when the historical read was not available.
    public let change24h: Double?
    /// "Uniswap v4", "Uniswap v3" or "USDC".
    public let source: String

    public init(usd: Double, change24h: Double?, source: String) {
        self.usd = usd
        self.change24h = change24h
        self.source = source
    }
}

public struct PricePoint: Hashable, Sendable, Identifiable {
    public var id: UInt64 { block }
    public let block: UInt64
    public let time: Date
    public let usd: Double

    public init(block: UInt64, time: Date, usd: Double) {
        self.block = block
        self.time = time
        self.usd = usd
    }
}

/// Spot prices straight from the deepest on-chain pool for each token, quoted in USDC, plus the same read 24 hours
/// earlier (Monad's public RPCs serve historical state) for the 24h change. Nothing here depends on an indexer.
public actor PriceService {
    /// Monad's block cadence, used to turn block numbers into times for price history.
    public static let secondsPerBlock: TimeInterval = 0.4

    enum Source: Hashable, Sendable {
        case v4(poolId: Data)
        case v3(pool: Address, token: Address, quote: Address, token0: Address)

        var label: String {
            switch self {
            case .v4: return "Uniswap v4"
            case .v3: return "Uniswap v3"
            }
        }

        /// The read whose first return value is `sqrtPriceX96`.
        var slot0Call: ContractCall {
            get throws {
                switch self {
                case .v4(let poolId): return try SwapCalldata.stateViewSlot0(poolId: poolId)
                case .v3(let pool, _, _, _): return try SwapCalldata.v3Slot0(pool: pool)
                }
            }
        }

        var isWMONQuoted: Bool {
            if case .v3(_, _, let quote, _) = self { return quote == Monad.wmon }
            return false
        }
    }

    public let rpc: RPCClient
    private let multicall: Multicall
    /// Tokens whose pool has been looked up; `misses` are the ones without any pool so they are not searched again.
    private var discovered: [Address: Source] = [:]
    private var misses: Set<Address> = []

    public init(rpc: RPCClient) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
    }

    // MARK: Public

    /// USD price and 24h change for every token that has a discoverable pool. USDC is 1 by definition.
    public func prices(for tokens: [Token]) async throws -> [Address: PriceInfo] {
        try await discover(tokens)
        let latest = try await rpc.blockNumber()
        let dayAgo: UInt64? = latest > Monad.blocksPerDay ? latest - Monad.blocksPerDay : nil
        let sources = resolve(tokens)
        async let nowRead = Self.readPrices(multicall: multicall, sources, block: .latest)
        async let beforeRead = Self.readPricesOrEmpty(multicall: multicall, sources, dayAgo: dayAgo)
        let (now, before) = try await (nowRead, beforeRead)
        var map: [Address: PriceInfo] = [:]
        for token in tokens {
            if Self.isUSD(token) {
                map[token.address] = PriceInfo(usd: 1, change24h: 0, source: "USDC")
                continue
            }
            guard let usd = now[token.address] else { continue }
            let change = before[token.address].flatMap { prev in prev != 0 ? (usd - prev) / prev * 100 : nil }
            map[token.address] = PriceInfo(usd: usd, change24h: change, source: discovered[token.address]?.label ?? "Uniswap v3")
        }
        return map
    }

    /// Samples the token's pool at `points` evenly spaced blocks over `span`, ending at the latest block, in one
    /// batched JSON-RPC request. Samples the node cannot serve are dropped, so fewer than `points` may come back.
    public func history(for token: Token, points: Int = 48, span: TimeInterval = 86_400) async throws -> [PricePoint] {
        guard points > 0 else { return [] }
        let latest = try await rpc.blockNumber()
        let latestTime = Date()
        let spanBlocks = UInt64(max(0, span) / Self.secondsPerBlock)
        let step = points > 1 ? spanBlocks / UInt64(points - 1) : 0
        var blocks: [UInt64] = []
        for i in 0..<points {
            let back = step * UInt64(points - 1 - i)
            let block = latest > back ? latest - back : 0
            if blocks.last != block { blocks.append(block) }
        }
        func time(_ block: UInt64) -> Date { latestTime.addingTimeInterval(-Double(latest - block) * Self.secondsPerBlock) }
        if Self.isUSD(token) { return blocks.map { PricePoint(block: $0, time: time($0), usd: 1) } }

        try await discover([token])
        guard let source = discovered[token.address] else { return [] }
        // WMON-quoted pools need MON's own price at every sample to become USD.
        var monSource: Source?
        if source.isWMONQuoted {
            try await discover([Token.mon])
            guard let mon = discovered[Monad.native] else { return [] }
            monSource = mon
        }
        let call = try source.slot0Call
        let monCall = try monSource?.slot0Call
        var requests: [(CallRequest, BlockTag)] = []
        for block in blocks {
            requests.append((CallRequest(to: call.to, data: call.data), .number(block)))
            if let monCall { requests.append((CallRequest(to: monCall.to, data: monCall.data), .number(block))) }
        }
        let results = try await rpc.ethCalls(requests)
        guard results.count == requests.count else { throw NetworkError.malformedResponse }
        let stride = monCall == nil ? 1 : 2
        var out: [PricePoint] = []
        for (i, block) in blocks.enumerated() {
            guard case .success(let data) = results[i * stride], let sqrt = Self.sqrtPrice(data) else { continue }
            var usd = Self.usd(sqrtPriceX96: sqrt, source: source, tokenDecimals: token.decimals)
            if let monSource {
                guard case .success(let monData) = results[i * stride + 1], let monSqrt = Self.sqrtPrice(monData) else { continue }
                usd *= Self.usd(sqrtPriceX96: monSqrt, source: monSource, tokenDecimals: 18)
            }
            out.append(PricePoint(block: block, time: time(block), usd: usd))
        }
        return out
    }

    /// Value of a raw token amount at a USD price; nil when the price is unknown.
    public static func usdValue(_ amount: BigUInt, decimals: Int, price: Double?) -> Double? {
        price.map { Amount.units(amount, decimals: decimals) * $0 }
    }

    // MARK: Discovery

    /// Finds the deepest pool for each token not yet looked up: for MON/WMON the v4 native/USDC pool (falling back
    /// to v3), for everything else the v3 pool against USDC, or against WMON when no USDC pool has liquidity.
    private func discover(_ tokens: [Token]) async throws {
        var todo: [Token] = []
        for token in tokens where discovered[token.address] == nil && !misses.contains(token.address) && !Self.isUSD(token) && !todo.contains(where: { $0.address == token.address }) {
            todo.append(token)
        }
        guard !todo.isEmpty else { return }
        let v4Ids = Uniswap.v4Tiers.map { PoolKey.canonical(Monad.native, Monad.usdc, fee: $0.fee, tickSpacing: $0.tickSpacing).id }
        var pairs: [(token: Address, quote: Address, fee: Int)] = []
        for token in todo {
            let base = token.isNative ? Monad.wmon : token.address
            for quote in [Monad.usdc, Monad.wmon] where base != quote {
                for fee in Uniswap.v3FeeTiers { pairs.append((base, quote, fee)) }
            }
        }
        let v4Calls = try v4Ids.map { try SwapCalldata.stateViewLiquidity(poolId: $0) }
        let poolCalls = try pairs.map { try SwapCalldata.v3GetPool(factory: Uniswap.v3Factory, $0.token, $0.quote, fee: $0.fee) }
        async let v4Read = multicall.read(v4Calls)
        async let poolRead = multicall.readAll(poolCalls)
        let (v4Liquidity, pools) = try await (v4Read, poolRead)

        let existing = pools.enumerated().compactMap { entry -> (index: Int, pool: Address)? in
            let pool = entry.element[0].address
            return pool.isZero ? nil : (entry.offset, pool)
        }
        let liquidityCalls = try existing.map { try SwapCalldata.v3Liquidity(pool: $0.pool) }
        let token0Calls = try existing.map { try SwapCalldata.v3Token0(pool: $0.pool) }
        async let liquidityRead = multicall.read(liquidityCalls)
        async let token0Read = multicall.read(token0Calls)
        let (liquidities, token0s) = try await (liquidityRead, token0Read)

        var bestV3: [Address: (weight: BigUInt, source: Source)] = [:]
        for (k, entry) in existing.enumerated() {
            guard case .success(let liquidity) = liquidities[k], liquidity[0].uint > 0, case .success(let token0) = token0s[k] else { continue }
            let pair = pairs[entry.index]
            // Prefer USDC-quoted pools; a WMON-quoted pool only wins when no USDC pool has liquidity.
            let weight = pair.quote == Monad.usdc ? liquidity[0].uint * 1_000_000 : liquidity[0].uint
            if let previous = bestV3[pair.token], weight <= previous.weight { continue }
            bestV3[pair.token] = (weight, .v3(pool: entry.pool, token: pair.token, quote: pair.quote, token0: token0[0].address))
        }
        var v4Best: (liquidity: BigUInt, id: Data)?
        for (i, result) in v4Liquidity.enumerated() {
            guard case .success(let values) = result else { continue }
            let liquidity = values[0].uint
            if liquidity > 0, v4Best.map({ liquidity > $0.liquidity }) ?? true { v4Best = (liquidity, v4Ids[i]) }
        }
        for token in todo {
            let source: Source?
            if token.isNative || token.address == Monad.wmon {
                source = v4Best.map { .v4(poolId: $0.id) } ?? bestV3[Monad.wmon]?.source
            } else {
                source = bestV3[token.address]?.source
            }
            if let source { discovered[token.address] = source } else { misses.insert(token.address) }
        }
    }

    private func resolve(_ tokens: [Token]) -> [(token: Token, source: Source)] {
        var seen: Set<Address> = []
        return tokens.compactMap { token in
            guard seen.insert(token.address).inserted, let source = discovered[token.address] else { return nil }
            return (token, source)
        }
    }

    // MARK: Reads

    private static func readPricesOrEmpty(multicall: Multicall, _ sources: [(token: Token, source: Source)], dayAgo: UInt64?) async -> [Address: Double] {
        guard let dayAgo else { return [:] }
        return (try? await readPrices(multicall: multicall, sources, block: .number(dayAgo))) ?? [:]
    }

    /// USD price per token from each source's `sqrtPriceX96`; WMON-quoted prices become USD through MON's own price.
    private static func readPrices(multicall: Multicall, _ sources: [(token: Token, source: Source)], block: BlockTag) async throws -> [Address: Double] {
        var out: [Address: Double] = [:]
        guard !sources.isEmpty else { return out }
        let results = try await multicall.read(try sources.map { try $0.source.slot0Call }, block: block)
        for (i, result) in results.enumerated() {
            guard case .success(let values) = result else { continue }
            let (token, source) = sources[i]
            out[token.address] = usd(sqrtPriceX96: values[0].uint, source: source, tokenDecimals: token.decimals)
        }
        for (token, source) in sources where source.isWMONQuoted {
            let mon = out[Monad.native] ?? out[Monad.wmon]
            if let mon, let value = out[token.address] { out[token.address] = value * mon } else { out[token.address] = nil }
        }
        return out
    }

    // MARK: Math

    /// Price of `token` in `quote` units per whole token, from the sqrtPriceX96 of a pool whose token0 is known.
    public static func price(sqrtPriceX96: BigUInt, token: Address, token0: Address, tokenDecimals: Int, quoteDecimals: Int) -> Double {
        let ratio = Double(sqrtPriceX96) / pow(2, 96) // sqrt(token1 per token0 in raw units)
        let price1per0 = ratio * ratio
        let raw = token == token0 ? price1per0 : 1 / price1per0 // quote-raw per token-raw
        return raw * pow(10, Double(tokenDecimals - quoteDecimals))
    }

    static func usd(sqrtPriceX96: BigUInt, source: Source, tokenDecimals: Int) -> Double {
        switch source {
        case .v4:
            return price(sqrtPriceX96: sqrtPriceX96, token: Monad.native, token0: Monad.native, tokenDecimals: 18, quoteDecimals: 6)
        case .v3(_, let token, let quote, let token0):
            return price(sqrtPriceX96: sqrtPriceX96, token: token, token0: token0, tokenDecimals: tokenDecimals, quoteDecimals: quote == Monad.usdc ? 6 : 18)
        }
    }

    static func sqrtPrice(_ slot0: Data) -> BigUInt? {
        guard let value = try? ABI.decode(slot0, "uint160").first, case .uint(let sqrt) = value else { return nil }
        return sqrt
    }

    static func isUSD(_ token: Token) -> Bool { token.address == Monad.usdc }
}
