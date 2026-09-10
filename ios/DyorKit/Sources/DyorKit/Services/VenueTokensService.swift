import Foundation

/// Builds the tradeable-asset list straight from the venues themselves — every token that has a pool on Uniswap v3,
/// Monday Trade, or Uniswap v4 on Monad — by scanning their pool-creation events. Symbols/decimals are read on-chain
/// (authoritative); logos are left for the caller to enrich (Kuru's CDN), since the venues don't serve icons and the
/// canonical token-list ships unrenderable SVGs. This is the "real assets, accurate metadata" source behind the
/// swap picker, distinct from a curated hardcoded list.
public struct VenueTokensService: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall

    public init(logsRPC: RPCClient, multicall: Multicall) {
        self.logsRPC = logsRPC
        self.multicall = multicall
    }

    // Uniswap v3 / Monday Trade share the v3 PoolCreated shape; Uniswap v4 uses the PoolManager's Initialize.
    private static let poolCreated = "PoolCreated(address,address,uint24,int24,address)"
    private static let initialize = "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"

    /// Tokens that gained a pool on any venue in the recent `window`, resolved to on-chain metadata. Quote/stable/hop
    /// assets and anything in `exclude` are dropped; the result is capped at `limit` to bound the metadata reads.
    public func tokens(window: UInt64 = Monad.blocksPerDay * 45, exclude: Set<Address> = [], limit: Int = 400) async -> [Token] {
        guard let anchor = try? await logsRPC.block(.latest) else { return [] }
        let latest = anchor.number
        let from = latest > window ? latest - window : 0
        let created = ABI.eventTopic(Self.poolCreated)
        let initialized = ABI.eventTopic(Self.initialize)

        async let v3 = logsRPC.chunkedLogs(address: Uniswap.v3Factory, topics: [created], fromBlock: from, toBlock: latest)
        async let monday = logsRPC.chunkedLogs(address: MondayTrade.factory, topics: [created], fromBlock: from, toBlock: latest)
        async let v4 = logsRPC.chunkedLogs(address: Uniswap.poolManager, topics: [initialized], fromBlock: from, toBlock: latest)
        let (v3Logs, mondayLogs, v4Logs) = await (v3, monday, v4)

        // Exclude the quote/stable/hop assets (they're already curated) so the list is the tradeable long tail.
        var seen: Set<Address> = [Monad.native, Monad.wmon, Monad.usdc, Monad.ausd, Monad.usdt0, Monad.weth]
        seen.formUnion(exclude)
        var addresses: [Address] = []
        func consider(_ address: Address?) { if let address, seen.insert(address).inserted { addresses.append(address) } }
        // v3 / Monday: token0 = indexedAddress(0), token1 = indexedAddress(1). Newest pools first for relevance.
        for log in (v3Logs + mondayLogs).sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(0)); consider(log.indexedAddress(1))
        }
        // v4: topic1 is the poolId; currency0 = indexedAddress(1), currency1 = indexedAddress(2).
        for log in v4Logs.sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(1)); consider(log.indexedAddress(2))
        }
        guard !addresses.isEmpty else { return [] }
        if addresses.count > limit { addresses = Array(addresses.prefix(limit)) }
        return await ERC20.metadataBatch(addresses, multicall: multicall)
    }
}
