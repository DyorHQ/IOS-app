import BigInt
import Foundation

/* On-chain history for Moments without an indexer: `eth_getLogs` from the factory's deployment block (nothing
   about Moments exists before it) in chunks the endpoint accepts, newest first. Every event that matters carries the
   wallet as an indexed topic, so each scan is one filtered query. The app's own screens read the wallet's Moments history
   from its history store (`WalletHistoryScans.moments`, every cohort), not from here. */

public extension MomentsService {
    /// Everything the wallet did on Moments — collects, vesting claims, USDC withdrawals, publishes — since
    /// `fromBlock` (default: the factory's deployment block), newest first, and whether every scan read the whole window
    /// (`complete`): false when the head couldn't be read, or a scan stopped short. The scans read newest first, so one
    /// that stops short holds the latest records; in build 22 and earlier they read oldest first and said nothing, and a
    /// cohort deployed more than about 4.8M blocks ago (each scan's budget, 80 requests) came back with its first weeks
    /// only, passed off as the whole.
    func history(account: Address, fromBlock: UInt64? = nil) async -> (history: MomentsAccountHistory, complete: Bool) {
        guard isDeployed else { return (.empty, true) }
        guard let anchor = try? await logsRPC.block(.latest) else { return (.empty, false) }
        let secondsPerBlock = await clock.secondsPerBlock()
        let from = max(fromBlock ?? addresses.deployBlock, addresses.deployBlock)
        guard from <= anchor.number else { return (.empty, true) }
        let word = account.data.leftPadded(to: 32)
        let to = anchor.number
        async let collectedRead = logsRPC.chunkedLogsReport(address: addresses.collect, topics: [MomentsABI.Events.collectedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let claimedRead = logsRPC.chunkedLogsReport(address: addresses.vesting, topics: [MomentsABI.Events.claimedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let withdrawnRead = logsRPC.chunkedLogsReport(address: addresses.collect, topics: [MomentsABI.Events.withdrawnTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let feesRead = logsRPC.chunkedLogsReport(address: addresses.hook, topics: [MomentsABI.Events.feesWithdrawnTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let publishedRead = logsRPC.chunkedLogsReport(address: addresses.factory, topics: [MomentsABI.Events.publishedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        let (collected, claimed, withdrawn, fees, published) = await (collectedRead, claimedRead, withdrawnRead, feesRead, publishedRead)
        let history = Self.history(collected: collected.logs, claimed: claimed.logs, withdrawn: withdrawn.logs, feesWithdrawn: fees.logs, published: published.logs,
                                   anchor: anchor, secondsPerBlock: secondsPerBlock, factory: addresses.factory)
        return (history, [collected, claimed, withdrawn, fees, published].allSatisfy { $0.complete })
    }

    /// Pure half of `history`, so the parsers can be tested on canned logs. Each record's time is its block's own when the
    /// log carries it (`Log.blockTimestamp`), else estimated from `anchor` at `secondsPerBlock`; `factory` tags every
    /// record with its cohort (Moment ids restart at 1 on every factory).
    nonisolated static func history(collected: [Log], claimed: [Log], withdrawn: [Log], feesWithdrawn: [Log], published: [Log], anchor: BlockHeader, secondsPerBlock: Double,
                                    factory: Address = .zero) -> MomentsAccountHistory {
        func time(_ log: Log) -> Date { BlockClock.time(of: log, anchor: anchor, secondsPerBlock: secondsPerBlock) }
        var collects: [MomentCollectRecord] = []
        for log in collected {
            guard let e = MomentsABI.collected(log) else { continue }
            collects.append(MomentCollectRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, collector: e.collector,
                                                gross: e.gross, editions: Int(clamping: e.editions), firstRank: Int(clamping: e.firstRank), entitlement: e.entitlement,
                                                reserveIn: e.reserveIn, creatorIn: e.creatorIn, platformIn: e.platformIn, factory: factory))
        }
        var claims: [MomentClaimRecord] = []
        for log in claimed {
            guard let e = MomentsABI.claimed(log) else { continue }
            claims.append(MomentClaimRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, collectorAmount: e.collectorAmount, creatorAmount: e.creatorAmount, factory: factory))
        }
        var withdrawals: [MomentWithdrawalRecord] = []
        for log in withdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, kind: .proceeds, amount: e.amount, factory: factory))
        }
        for log in feesWithdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, kind: .poolFees, amount: e.amount, factory: factory))
        }
        var publishes: [MomentPublishRecord] = []
        for log in published {
            guard let e = MomentsABI.published(log) else { continue }
            publishes.append(MomentPublishRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, coin: e.coin, factory: factory))
        }
        return MomentsAccountHistory(
            collects: collects.sorted { $0.block > $1.block },
            claims: claims.sorted { $0.block > $1.block },
            withdrawals: withdrawals.sorted { $0.block > $1.block },
            publishes: publishes.sorted { $0.block > $1.block }
        )
    }

    /// Holder statistics for a Moment coin from its `Transfer` logs since publish. The pool and the other protocol
    /// addresses are reported apart from wallets (spec §12 containment: holder count + top-holder share). Nil when the
    /// head, or the newest of the coin's blocks, couldn't be read: no figure at all, never 0 holders.
    ///
    /// The transfers are read newest first (`RPCClient.newestLogs`) within the patient budget (80 requests, about 4.8M
    /// blocks on rpc2, about 13 days of a Moment's age at this lookback; 80,000 blocks, hours, on the 1,000-block
    /// endpoints): a read that stops short of the publish gives the holders as a minimum and says so
    /// (`MomentHolderStats.complete`). In build 22 and earlier it read oldest first and said nothing: an older Moment's
    /// holders, top wallet and pool share were those of its first days, shown with the head as `scannedTo`.
    func holderStats(coin: Address, publishedAt: Int) async -> MomentHolderStats? {
        guard isDeployed, let anchor = try? await logsRPC.block(.latest) else { return nil }
        // The publish block from the anchor and the session's pace (with slack), never before deployment.
        let back = Self.holderLookback(ageSeconds: anchor.timestamp - publishedAt, secondsPerBlock: await clock.secondsPerBlock())
        let from = max(addresses.deployBlock, anchor.number > back ? anchor.number - back : 0)
        let read = await logsRPC.newestLogs(address: coin, topics: [MomentsABI.Events.transferTopic], fromBlock: from, toBlock: anchor.number)
        return Self.holderStats(read, addresses: addresses, scannedTo: anchor.number)
    }

    /// Pure half of `holderStats(coin:publishedAt:)` for a read that may have stopped short: nil when nothing was read down
    /// from the head.
    nonisolated static func holderStats(_ read: NewestLogs, addresses: MomentsAddresses, scannedTo: UInt64) -> MomentHolderStats? {
        guard read.readFrom != nil else { return nil }
        return holderStats(transfers: read.logs, addresses: addresses, scannedTo: scannedTo, complete: read.complete)
    }

    /// How far back `holderStats` reads a Moment's transfers: its age (no less than 0) in blocks at `secondsPerBlock`,
    /// with a quarter more and 2,000 blocks of slack, so the publish is inside the scan even if the pace was slower.
    nonisolated static func holderLookback(ageSeconds: Int, secondsPerBlock: Double) -> UInt64 {
        BlockClock.blocks(in: TimeInterval(max(0, ageSeconds)) * 1.25, secondsPerBlock: secondsPerBlock) + 2_000
    }

    /// Pure half of `holderStats`: `complete`, whether `transfers` are every one since the publish
    /// (`MomentHolderStats.complete`).
    nonisolated static func holderStats(transfers: [Log], addresses: MomentsAddresses, scannedTo: UInt64, complete: Bool = true) -> MomentHolderStats {
        var balances: [Address: BigInt] = [:]
        for log in transfers {
            guard let from = log.indexedAddress(0), let to = log.indexedAddress(1) else { continue }
            let value = BigInt(BigUInt(log.data))
            if !from.isZero { balances[from, default: 0] -= value }
            balances[to, default: 0] += value
        }
        let protocolSet = addresses.protocolHolders
        var minted = BigInt(0), pool = BigInt(0), circulating = BigInt(0)
        var holders = 0
        var top: (Address?, BigInt) = (nil, 0)
        for (who, balance) in balances where balance > 0 {
            minted += balance
            if who == addresses.poolManager { pool += balance }
            if protocolSet.contains(who) { continue }
            circulating += balance
            holders += 1
            if balance > top.1 { top = (who, balance) }
        }
        let scale = pow(10.0, Double(MomentsConstants.coinDecimals))
        return MomentHolderStats(
            holders: holders,
            topHolder: top.0,
            topHolderBps: circulating == 0 ? 0 : Int(clamping: (top.1 * 10_000 / circulating).magnitude),
            circulatingCoins: Double(circulating) / scale,
            poolBps: minted == 0 ? 0 : Int(clamping: (pool * 10_000 / minted).magnitude),
            mintedCoins: Double(minted) / scale,
            scannedTo: scannedTo,
            complete: complete
        )
    }
}
