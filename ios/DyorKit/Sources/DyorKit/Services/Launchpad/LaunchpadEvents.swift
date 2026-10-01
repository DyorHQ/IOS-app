import BigInt
import Foundation

/* On-chain history without an indexer: `eth_getLogs` over recent blocks in chunks the endpoint accepts (see
   `RPCClient.chunkedLogs`). Windows are deliberately recent (hours, not months). A port of the web app's
   `launchpad/events.ts`. */

public extension LaunchpadService {
    /// Curve fills for one launch over the last `lookbackBlocks` blocks, or the last 24 hours (`clock`) when nil, oldest
    /// first. `pair` scales prices to pair units so they line up with `priceNumber`; each fill's time is estimated at the
    /// session's measured pace.
    func trades(curve: Address, pair: PairInfo, lookbackBlocks: UInt64? = nil) async throws -> [CurveTrade] {
        let anchor = try await rpc.block(.latest)
        let secondsPerBlock = await clock.secondsPerBlock()
        let lookback = lookbackBlocks ?? BlockClock.blocks(in: 86_400, secondsPerBlock: secondsPerBlock)
        let from = anchor.number > lookback ? anchor.number - lookback : 0
        async let buyLogs = logsRPC.chunkedLogs(address: curve, topics: [LaunchpadABI.Events.buyTopic], fromBlock: from, toBlock: anchor.number)
        async let sellLogs = logsRPC.chunkedLogs(address: curve, topics: [LaunchpadABI.Events.sellTopic], fromBlock: from, toBlock: anchor.number)
        let (buys, sells) = await (buyLogs, sellLogs)
        return Self.trades(buys: buys, sells: sells, anchor: anchor, pair: pair, secondsPerBlock: secondsPerBlock)
    }

    /// The blocks a coin launched at `launchedAt` (seconds since 1970) has existed for, plus `tradeLookbackMargin`, at the
    /// session's pace, for reading its whole trade history (a profile's PnL); at most `maxTradeLookback` of them.
    func tradeLookback(launchedAt: Int, now: Date = Date()) async -> UInt64 {
        Self.tradeLookback(ageSeconds: now.timeIntervalSince1970 - TimeInterval(launchedAt), secondsPerBlock: await clock.secondsPerBlock())
    }

    /// Pure half of `tradeLookback(launchedAt:now:)`: a coin's age (no less than 0, no more than `maxTradeLookback`) in
    /// blocks, rounded up, plus `tradeLookbackMargin`.
    nonisolated static func tradeLookback(ageSeconds: TimeInterval, secondsPerBlock: Double) -> UInt64 {
        BlockClock.blocks(in: min(maxTradeLookback, max(0, ageSeconds)), secondsPerBlock: secondsPerBlock) + tradeLookbackMargin
    }

    /// Approximate holder count: the number of addresses with a positive net token balance, from the token's
    /// `Transfer` events over the last `lookbackBlocks` blocks (a budget, `holderScanBlocks`). Mints/burns (the zero
    /// address) and any `excluding` address (e.g. the bonding curve, which holds the unsold supply) are left out. Exact
    /// counts want an indexer; this is right for a new coin.
    func holderCount(token: Address, excluding: Set<Address> = [], lookbackBlocks: UInt64 = LaunchpadService.holderScanBlocks) async -> Int {
        guard let anchor = try? await logsRPC.block(.latest) else { return 0 }
        let from = anchor.number > lookbackBlocks ? anchor.number - lookbackBlocks : 0
        let logs = await logsRPC.chunkedLogs(address: token, topics: [ABI.eventTopic("Transfer(address,address,uint256)")], fromBlock: from, toBlock: anchor.number)
        var net: [Address: BigInt] = [:]
        for log in logs {
            guard let sender = log.indexedAddress(0), let recipient = log.indexedAddress(1) else { continue }
            let amount = BigInt(BigUInt(log.data))
            if !sender.isZero { net[sender, default: 0] -= amount }
            if !recipient.isZero { net[recipient, default: 0] += amount }
        }
        return net.reduce(0) { count, entry in count + (entry.value > 0 && !excluding.contains(entry.key) ? 1 : 0) }
    }

    /// Pure half of `trades(curve:pair:lookbackBlocks:)`, so the parser can be tested on canned logs. Times are estimated
    /// from `anchor` at `secondsPerBlock`.
    nonisolated static func trades(buys: [Log], sells: [Log], anchor: BlockHeader, pair: PairInfo, secondsPerBlock: Double) -> [CurveTrade] {
        var out: [CurveTrade] = []
        for log in buys {
            // Quote that moved the reserves: the input net of fee and tax.
            guard let fill = LaunchpadABI.fill(log) else { continue }
            let fees = fill.fee + fill.tax
            let quote = fees > fill.amountIn ? 0 : fill.amountIn - fees
            out.append(trade(log, anchor: anchor, secondsPerBlock: secondsPerBlock, pair: pair, trader: fill.trader, isBuy: true, quote: quote, tokens: fill.amountOut))
        }
        for log in sells {
            // Gross quote before fees, which is what left the reserves.
            guard let fill = LaunchpadABI.fill(log) else { continue }
            out.append(trade(log, anchor: anchor, secondsPerBlock: secondsPerBlock, pair: pair, trader: fill.trader, isBuy: false, quote: fill.amountOut + fill.fee + fill.tax, tokens: fill.amountIn))
        }
        return out.sorted { a, b in a.block == b.block ? a.logIndex < b.logIndex : a.block < b.block }
    }

    private nonisolated static func trade(_ log: Log, anchor: BlockHeader, secondsPerBlock: Double, pair: PairInfo, trader: Address, isBuy: Bool, quote: BigUInt, tokens: BigUInt) -> CurveTrade {
        CurveTrade(
            id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(anchor: anchor, block: log.blockNumber, secondsPerBlock: secondsPerBlock), trader: trader, isBuy: isBuy,
            quoteAmount: quote, tokenAmount: tokens, quoteDecimals: pair.decimals, price: price(quote: quote, tokens: tokens, quoteDecimals: pair.decimals)
        )
    }

    /// Quote per whole token in pair units: raw quote / raw tokens scaled by 10^(18 − quote decimals).
    nonisolated static func price(quote: BigUInt, tokens: BigUInt, quoteDecimals: Int) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(quote) / Double(tokens) * pow(10, Double(18 - quoteDecimals))
    }

    /// Estimated timestamp of `block` (seconds since 1970, rounded) from a later block's and the pace
    /// (`BlockClock.time(of:anchor:secondsPerBlock:)`).
    nonisolated static func time(anchor: BlockHeader, block: UInt64, secondsPerBlock: Double) -> Int {
        Int(BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock).timeIntervalSince1970.rounded(.toNearestOrAwayFromZero))
    }

    /// OHLC candles from trades in `interval`-second buckets. Empty buckets between trades carry the previous
    /// close forward (capped at 2 000 candles) so the chart has no holes.
    nonisolated static func candles(from trades: [CurveTrade], interval: Int) -> [Candle] {
        guard interval > 0 else { return [] }
        var buckets: [Int: Candle] = [:]
        for trade in trades where trade.price > 0 {
            let bucket = Int((Double(trade.time) / Double(interval)).rounded(.down)) * interval
            let price = trade.price
            let volume = Amount.units(trade.quoteAmount, decimals: trade.quoteDecimals)
            if var candle = buckets[bucket] {
                candle.high = max(candle.high, price)
                candle.low = min(candle.low, price)
                candle.close = price
                candle.volume += volume
                buckets[bucket] = candle
            } else {
                buckets[bucket] = Candle(time: bucket, open: price, high: price, low: price, close: price, volume: volume)
            }
        }
        let sorted = buckets.values.sorted { $0.time < $1.time }
        var filled: [Candle] = []
        for (i, candle) in sorted.enumerated() {
            filled.append(candle)
            guard i + 1 < sorted.count else { break }
            let next = sorted[i + 1]
            var t = candle.time + interval
            while t < next.time, filled.count < 2000 {
                filled.append(Candle(time: t, open: candle.close, high: candle.close, low: candle.close, close: candle.close, volume: 0))
                t += interval
            }
        }
        return filled
    }

    /// Everything that happened on the launchpad in the last `lookbackBlocks` blocks (9 000 by default, about 45 minutes):
    /// launches, curve trades and graduations, newest first, at most `limit` rows. Trades are matched against
    /// `launches` (the explore list) so only curves these factories created count; when nil, the newest 60 launches
    /// of every stack are read first. Launch and graduation events come from the live and the retired factories
    /// (whose curves still trade and graduate); while the live stack is pending (v2), from the retired ones alone.
    func activity(limit: Int = 50, lookbackBlocks: UInt64 = 9_000, launches known: [Launch]? = nil) async throws -> [ActivityItem] {
        guard limit > 0, !stacks.isEmpty else { return [] }
        let launches: [Launch]
        if let known { launches = known } else { launches = try await allLaunches(limit: 60) }
        let curves = Dictionary(launches.map { ($0.curve, $0.token) }, uniquingKeysWith: { first, _ in first })
        let anchor = try await rpc.block(.latest)
        let secondsPerBlock = await clock.secondsPerBlock()
        let from = anchor.number > lookbackBlocks ? anchor.number - lookbackBlocks : 0
        // One scan per event across every factory, kept to the factories of this launchpad's stacks.
        let factories = Set(stacks.map(\.factory))
        async let launched = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.launchedTopic], fromBlock: from, toBlock: anchor.number)
        async let graduated = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.graduatedTopic], fromBlock: from, toBlock: anchor.number)
        async let buys = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.buyTopic], fromBlock: from, toBlock: anchor.number)
        async let sells = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.sellTopic], fromBlock: from, toBlock: anchor.number)
        let items = Self.activity(
            launched: await launched.filter { factories.contains($0.address) }, graduated: await graduated.filter { factories.contains($0.address) },
            buys: await buys, sells: await sells, anchor: anchor, secondsPerBlock: secondsPerBlock, curves: curves
        )
        return Array(items.prefix(limit))
    }

    /// Pure half of `activity`, newest first, each item's time estimated from `anchor` at `secondsPerBlock`.
    nonisolated static func activity(launched: [Log], graduated: [Log], buys: [Log], sells: [Log], anchor: BlockHeader, secondsPerBlock: Double, curves: [Address: Address]) -> [ActivityItem] {
        func time(_ log: Log) -> Int { Self.time(anchor: anchor, block: log.blockNumber, secondsPerBlock: secondsPerBlock) }
        var items: [ActivityItem] = []
        for log in launched {
            guard let event = LaunchpadABI.launched(log) else { continue }
            items.append(ActivityItem(id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(log), transactionHash: log.transactionHash, kind: .launch(token: event.token, curve: event.curve, deployer: event.deployer)))
        }
        for log in graduated {
            guard let event = LaunchpadABI.graduated(log) else { continue }
            items.append(ActivityItem(id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(log), transactionHash: log.transactionHash, kind: .graduated(token: event.token, poolId: event.poolId)))
        }
        for log in buys {
            // Feed rows show the gross quote a buyer paid.
            guard let token = curves[log.address], let fill = LaunchpadABI.fill(log) else { continue }
            items.append(ActivityItem(id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(log), transactionHash: log.transactionHash, kind: .trade(token: token, curve: log.address, trader: fill.trader, isBuy: true, quoteAmount: fill.amountIn, tokenAmount: fill.amountOut)))
        }
        for log in sells {
            // And the net quote a seller received.
            guard let token = curves[log.address], let fill = LaunchpadABI.fill(log) else { continue }
            items.append(ActivityItem(id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(log), transactionHash: log.transactionHash, kind: .trade(token: token, curve: log.address, trader: fill.trader, isBuy: false, quoteAmount: fill.amountOut, tokenAmount: fill.amountIn)))
        }
        return items.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block }
    }
}
