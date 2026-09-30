import Foundation

/// Builds the tradeable-asset list straight from the venues themselves — every token that has a pool on Uniswap v3,
/// Monday Trade, or Uniswap v4 on Monad — by scanning their pool-creation events. Symbols/decimals are read on-chain
/// (authoritative); logos are left for the caller to enrich (Kuru's CDN), since the venues don't serve icons and the
/// canonical token-list ships unrenderable SVGs. This is the "real assets, accurate metadata" source behind the
/// swap picker, distinct from a curated hardcoded list.
public struct VenueTokensService: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall
    /// Ranges each venue's scan asks per round trip (`RPCClient.chunkedLogsReport`).
    private let concurrency: Int

    /// `logsRPC` reads the venues' events from genesis: rpc1, in 100,000-block ranges (`RPCClient.logChunkSize`), about
    /// 1,100 ranges a venue for 109M blocks. `concurrency` 2 keeps the three venues to six ranges at a time, so a fresh
    /// install's first read doesn't crowd out the wallet's own history scans on the same endpoint.
    public init(logsRPC: RPCClient, multicall: Multicall, concurrency: Int = 2) {
        self.logsRPC = logsRPC
        self.multicall = multicall
        self.concurrency = max(1, concurrency)
    }

    // Uniswap v3 / Monday Trade share the v3 PoolCreated shape; Uniswap v4 uses the PoolManager's Initialize.
    private static let poolCreated = "PoolCreated(address,address,uint24,int24,address)"
    private static let initialize = "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"

    /// Blocks a refresh reads between saves (`refresh`), so progress survives an interruption.
    public static let segment: UInt64 = 5_000_000

    /// What one read of the venues found (`tokens`).
    public struct Scan: Sendable, Equatable {
        public var tokens: [Token]
        /// Whether the window was read in full: every venue's ranges (`RPCClient.chunkedLogsReport`) and the metadata of
        /// every token found. False when a range was left as a gap, a metadata read got no answer, or the read was
        /// cancelled.
        public var complete: Bool
        /// Whether more tokens gained a pool than the read's `limit`: the first are here, and a read of the same window
        /// that excludes them, and `dropped`, brings the rest.
        public var capped: Bool
        /// Addresses with no readable symbol, read on their own (`ERC20.metadataReport`), left out as `ERC20.metadata`
        /// leaves them out.
        public var dropped: [Address]

        public init(tokens: [Token], complete: Bool, capped: Bool = false, dropped: [Address] = []) {
            self.tokens = tokens
            self.complete = complete
            self.capped = capped
            self.dropped = dropped
        }
    }

    /// Chain head, for a caller that scans the full history in checkpointed segments.
    public func head() async -> UInt64 { (try? await logsRPC.block(.latest))?.number ?? 0 }

    /// Tokens that gained a pool on any venue between `fromBlock` and `toBlock`, resolved to on-chain metadata, and
    /// whether the window was read in full. Quote/stable/hop assets and anything in `exclude` are dropped; the first
    /// `limit` are kept (newest pools first), and the read says when there were more. Callers scan the full history from
    /// genesis in segments (`refresh`), checkpointing each segment once it is read in full.
    public func tokens(fromBlock: UInt64, toBlock: UInt64, exclude: Set<Address> = [], limit: Int = 3000) async -> Scan {
        guard fromBlock <= toBlock else { return Scan(tokens: [], complete: true) }
        let created = ABI.eventTopic(Self.poolCreated)
        let initialized = ABI.eventTopic(Self.initialize)

        async let v3 = logsRPC.chunkedLogsReport(address: Uniswap.v3Factory, topics: [created], fromBlock: fromBlock, toBlock: toBlock, concurrency: concurrency)
        async let monday = logsRPC.chunkedLogsReport(address: MondayTrade.factory, topics: [created], fromBlock: fromBlock, toBlock: toBlock, concurrency: concurrency)
        async let v4 = logsRPC.chunkedLogsReport(address: Uniswap.poolManager, topics: [initialized], fromBlock: fromBlock, toBlock: toBlock, concurrency: concurrency)
        let (v3Scan, mondayScan, v4Scan) = await (v3, monday, v4)
        let read = v3Scan.complete && mondayScan.complete && v4Scan.complete

        // Exclude the quote/stable/hop assets (they're already curated) so the list is the tradeable long tail.
        var seen: Set<Address> = [Monad.native, Monad.wmon, Monad.usdc, Monad.ausd, Monad.usdt0, Monad.weth]
        seen.formUnion(exclude)
        var addresses: [Address] = []
        func consider(_ address: Address?) { if let address, seen.insert(address).inserted { addresses.append(address) } }
        // v3 / Monday: token0 = indexedAddress(0), token1 = indexedAddress(1). Newest pools first for relevance.
        for log in (v3Scan.logs + mondayScan.logs).sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(0)); consider(log.indexedAddress(1))
        }
        // v4: topic1 is the poolId; currency0 = indexedAddress(1), currency1 = indexedAddress(2).
        for log in v4Scan.logs.sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(1)); consider(log.indexedAddress(2))
        }
        guard !addresses.isEmpty else { return Scan(tokens: [], complete: read) }
        let capped = addresses.count > max(1, limit)
        if capped { addresses = Array(addresses.prefix(max(1, limit))) }
        let metadata = await ERC20.metadataReport(addresses, multicall: multicall)
        let answered = Set(metadata.tokens.map(\.address)).union(metadata.unread)
        return Scan(tokens: metadata.tokens, complete: read && metadata.unread.isEmpty && !Task.isCancelled, capped: capped,
                    dropped: addresses.filter { !answered.contains($0) })
    }

    /// Where a refresh has got to (`refresh`): the list, and the last block it is read up to in full.
    public struct Progress: Sendable, Equatable {
        public var tokens: [Token]
        public var checkpoint: UInt64
        /// The chain head the refresh read towards.
        public var head: UInt64
        /// Whether the list is read up to the head.
        public var complete: Bool { checkpoint >= head }

        public init(tokens: [Token], checkpoint: UInt64, head: UInt64) {
            self.tokens = tokens
            self.checkpoint = checkpoint
            self.head = head
        }
    }

    /// Brings a venue list up to the chain head: from the block after `checkpoint` (from genesis when it is 0), in
    /// segments of `segment` blocks. Each segment's new tokens are added to the list, with their logo from `logos` (read
    /// once, only when there is something to read), and the list is handed to `save` with its checkpoint. The checkpoint
    /// moves past a segment only once every venue was read in it in full, and every token found was read (`Scan`); a
    /// segment read in part keeps what it found, ends the refresh there, and is read again by the next one. A segment
    /// with more new tokens than one read keeps (`limit`) is read again at once, what it found or dropped excluded, until
    /// the rest are in. Returns where it got to, to the head or short of it; nil when the head couldn't be read, so
    /// nothing was.
    @discardableResult
    public func refresh(tokens known: [Token], checkpoint: UInt64, logos: @Sendable () async -> [Address: URL], segment: UInt64 = Self.segment,
                        limit: Int = 3000, save: @Sendable (Progress) async -> Void) async -> Progress? {
        var progress = Progress(tokens: known, checkpoint: checkpoint, head: await head())
        guard progress.head > 0 else { return nil }
        guard checkpoint < progress.head else { return progress }
        let logos = await logos()
        // Addresses this refresh read with no readable symbol: left out of a segment's next read, as the list is.
        var dropped: Set<Address> = []
        var from = checkpoint == 0 ? 0 : checkpoint + 1
        while from <= progress.head, !Task.isCancelled {
            let to = min(from + max(1, segment) - 1, progress.head)
            let exclude = Set(Token.core.map(\.address)).union(progress.tokens.map(\.address)).union(dropped)
            let scan = await tokens(fromBlock: from, toBlock: to, exclude: exclude, limit: limit)
            dropped.formUnion(scan.dropped)
            progress.tokens += scan.tokens.map { token -> Token in
                guard token.logoURL == nil, let logo = logos[token.address] else { return token }
                return Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logo, isLaunchpad: token.isLaunchpad)
            }
            if scan.complete, !scan.capped { progress.checkpoint = to }
            await save(progress)
            // A gap is left for the next refresh: asking again now would get the same answer.
            guard scan.complete else { break }
            // The same segment again, what it read now excluded: at least `limit` fewer each time, so this ends.
            if scan.capped { continue }
            guard to < progress.head else { break }
            from = to + 1
        }
        return progress
    }
}
