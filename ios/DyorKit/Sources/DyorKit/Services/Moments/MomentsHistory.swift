import BigInt
import Foundation

/* On-chain history for Moments without an indexer: `eth_getLogs` from the factory's deployment block (nothing
   about Moments exists before it) in chunks the endpoint accepts. Every event that matters carries the wallet as
   an indexed topic, so each scan is one filtered query. */

public extension MomentsService {
    /// Everything the wallet did on Moments — collects, vesting claims, USDC withdrawals, publishes — since
    /// `fromBlock` (default: the factory's deployment block), newest first.
    func history(account: Address, fromBlock: UInt64? = nil) async -> MomentsAccountHistory {
        guard isDeployed, let anchor = try? await logsRPC.block(.latest) else { return .empty }
        let from = max(fromBlock ?? addresses.deployBlock, addresses.deployBlock)
        guard from <= anchor.number else { return .empty }
        let word = account.data.leftPadded(to: 32)
        async let collectedLogs = logsRPC.chunkedLogs(address: addresses.collect, topics: [MomentsABI.Events.collectedTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        async let claimedLogs = logsRPC.chunkedLogs(address: addresses.vesting, topics: [MomentsABI.Events.claimedTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        async let withdrawnLogs = logsRPC.chunkedLogs(address: addresses.collect, topics: [MomentsABI.Events.withdrawnTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        async let feesLogs = logsRPC.chunkedLogs(address: addresses.hook, topics: [MomentsABI.Events.feesWithdrawnTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        async let publishedLogs = logsRPC.chunkedLogs(address: addresses.factory, topics: [MomentsABI.Events.publishedTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        let (collected, claimed, withdrawn, fees, published) = await (collectedLogs, claimedLogs, withdrawnLogs, feesLogs, publishedLogs)
        return Self.history(collected: collected, claimed: claimed, withdrawn: withdrawn, feesWithdrawn: fees, published: published, anchor: anchor)
    }

    /// Pure half of `history`, so the parsers can be tested on canned logs.
    nonisolated static func history(collected: [Log], claimed: [Log], withdrawn: [Log], feesWithdrawn: [Log], published: [Log], anchor: BlockHeader) -> MomentsAccountHistory {
        var collects: [MomentCollectRecord] = []
        for log in collected {
            guard let e = MomentsABI.collected(log) else { continue }
            collects.append(MomentCollectRecord(hash: log.transactionHash, block: log.blockNumber, time: time(anchor: anchor, block: log.blockNumber), momentId: e.momentId, collector: e.collector,
                                                gross: e.gross, editions: Int(clamping: e.editions), firstRank: Int(clamping: e.firstRank), entitlement: e.entitlement,
                                                reserveIn: e.reserveIn, creatorIn: e.creatorIn, platformIn: e.platformIn))
        }
        var claims: [MomentClaimRecord] = []
        for log in claimed {
            guard let e = MomentsABI.claimed(log) else { continue }
            claims.append(MomentClaimRecord(hash: log.transactionHash, block: log.blockNumber, time: time(anchor: anchor, block: log.blockNumber), momentId: e.momentId, collectorAmount: e.collectorAmount, creatorAmount: e.creatorAmount))
        }
        var withdrawals: [MomentWithdrawalRecord] = []
        for log in withdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(anchor: anchor, block: log.blockNumber), momentId: e.momentId, kind: .proceeds, amount: e.amount))
        }
        for log in feesWithdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(anchor: anchor, block: log.blockNumber), momentId: e.momentId, kind: .poolFees, amount: e.amount))
        }
        var publishes: [MomentPublishRecord] = []
        for log in published {
            guard let e = MomentsABI.published(log) else { continue }
            publishes.append(MomentPublishRecord(hash: log.transactionHash, block: log.blockNumber, time: time(anchor: anchor, block: log.blockNumber), momentId: e.momentId, coin: e.coin))
        }
        return MomentsAccountHistory(
            collects: collects.sorted { $0.block > $1.block },
            claims: claims.sorted { $0.block > $1.block },
            withdrawals: withdrawals.sorted { $0.block > $1.block },
            publishes: publishes.sorted { $0.block > $1.block }
        )
    }

    /// Holder statistics for a Moment coin from its `Transfer` logs since publish. The pool and the other protocol
    /// addresses are reported apart from wallets (spec §12 containment: holder count + top-holder share).
    func holderStats(coin: Address, publishedAt: Int) async -> MomentHolderStats {
        guard isDeployed, let anchor = try? await logsRPC.block(.latest) else { return .empty }
        // Estimate the publish block from the anchor and Monad's block time (with slack), never before deployment.
        let age = max(0, anchor.timestamp - publishedAt)
        let back = UInt64((Double(age) / Self.blockSeconds * 1.25).rounded(.up)) + 2_000
        let from = max(addresses.deployBlock, anchor.number > back ? anchor.number - back : 0)
        let logs = await logsRPC.chunkedLogs(address: coin, topics: [MomentsABI.Events.transferTopic], fromBlock: from, toBlock: anchor.number)
        return Self.holderStats(transfers: logs, addresses: addresses, scannedTo: anchor.number)
    }

    /// Pure half of `holderStats`.
    nonisolated static func holderStats(transfers: [Log], addresses: MomentsAddresses, scannedTo: UInt64) -> MomentHolderStats {
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
            scannedTo: scannedTo
        )
    }
}
