import BigInt
import Foundation

/* What a creator earned from the Moments they published, read from the chain without an indexer. A creator's USDC is
   pull-only: the collect contract holds their share of every collect (and, after an expiry, their share of the reserve)
   until they withdraw it, and the hook holds their share of the pool's trading fees once the Moment graduated. What is
   still held is a contract read (`creatorClaimable`, `creatorAccrued`); what was withdrawn is the sum of `Withdrawn` /
   `FeesWithdrawn` naming them. Everything credited to the creator is one or the other, so for every Moment
   `fromCollectors + tradingFees == claimed + unclaimed`. */

/// A creator's USDC from one Moment they published, in USDC units (6 decimals).
public struct MomentCreatorEarnings: Sendable, Hashable, Identifiable {
    public let key: MomentKey
    /// Withdrawn from the collect contract (`Withdrawn`).
    public let proceedsWithdrawn: BigUInt
    /// Still held by the collect contract (`ledger.creatorClaimable`).
    public let proceedsUnclaimed: BigUInt
    /// Withdrawn from the hook (`FeesWithdrawn`).
    public let feesWithdrawn: BigUInt
    /// Still held by the hook (`creatorAccrued`).
    public let feesUnclaimed: BigUInt
    public var id: MomentKey { key }

    public init(key: MomentKey, proceedsWithdrawn: BigUInt, proceedsUnclaimed: BigUInt, feesWithdrawn: BigUInt, feesUnclaimed: BigUInt) {
        self.key = key
        self.proceedsWithdrawn = proceedsWithdrawn
        self.proceedsUnclaimed = proceedsUnclaimed
        self.feesWithdrawn = feesWithdrawn
        self.feesUnclaimed = feesUnclaimed
    }

    /// The creator's share of the Moment's collects, and of its reserve if it expired: withdrawn or not.
    public var fromCollectors: BigUInt { proceedsWithdrawn + proceedsUnclaimed }
    /// The creator's share of the pool's trading fees: withdrawn or not.
    public var tradingFees: BigUInt { feesWithdrawn + feesUnclaimed }
    public var claimed: BigUInt { proceedsWithdrawn + feesWithdrawn }
    public var unclaimed: BigUInt { proceedsUnclaimed + feesUnclaimed }
}

/// The Moments a wallet published, in one cohort or several, with what each earned it.
public struct MomentsCreatorEarnings: Sendable, Hashable {
    public let moments: [MomentCreatorEarnings]
    /// The publishes and the withdrawals were read to the head. False: a Moment or a withdrawal may be missing, so the
    /// totals are not shown as complete.
    public let complete: Bool

    public init(moments: [MomentCreatorEarnings], complete: Bool) {
        self.moments = moments
        self.complete = complete
    }

    public static let none = MomentsCreatorEarnings(moments: [], complete: true)

    public var fromCollectors: BigUInt { moments.reduce(0) { $0 + $1.fromCollectors } }
    public var tradingFees: BigUInt { moments.reduce(0) { $0 + $1.tradingFees } }
    public var claimed: BigUInt { moments.reduce(0) { $0 + $1.claimed } }
    public var unclaimed: BigUInt { moments.reduce(0) { $0 + $1.unclaimed } }

    /// Both cohorts' Moments, complete only when both are.
    public static func + (a: MomentsCreatorEarnings, b: MomentsCreatorEarnings) -> MomentsCreatorEarnings {
        MomentsCreatorEarnings(moments: a.moments + b.moments, complete: a.complete && b.complete)
    }
}

public extension MomentsService {
    /// What the account earned from every Moment it published on this cohort (`MomentCreatorEarnings`). The Moments come
    /// from the factory's `Published` events naming it as the creator, so none is missed however many were published;
    /// their balances are read in one multicall, and the withdrawals naming it are summed for those Moments only (a
    /// platform or treasury withdrawal is never a creator's). Throws when the balances can't be read; a scan that
    /// couldn't be read to the head makes `complete` false.
    func creatorEarnings(account: Address) async throws -> MomentsCreatorEarnings {
        guard isDeployed else { return .none }
        let head = try await logsRPC.blockNumber()
        let from = addresses.deployBlock
        guard from <= head else { return .none }
        let word = account.data.leftPadded(to: 32)
        let rpc = logsRPC
        let hook = addresses.hook
        async let publishedRead = rpc.chunkedLogsReport(address: addresses.factory, topics: [MomentsABI.Events.publishedTopic, nil, word], fromBlock: from, toBlock: head)
        async let withdrawnRead = rpc.chunkedLogsReport(address: addresses.collect, topics: [MomentsABI.Events.withdrawnTopic, nil, word], fromBlock: from, toBlock: head)
        async let feesRead: (logs: [Log], complete: Bool) = hook.isZero
            ? ([], true)
            : rpc.chunkedLogsReport(address: hook, topics: [MomentsABI.Events.feesWithdrawnTopic, nil, word], fromBlock: from, toBlock: head)
        let (published, withdrawn, fees) = await (publishedRead, withdrawnRead, feesRead)
        let complete = published.complete && withdrawn.complete && fees.complete

        let ids = Self.createdIds(published.logs, account: account, factory: addresses.factory)
        guard !ids.isEmpty else { return MomentsCreatorEarnings(moments: [], complete: complete) }
        var calls: [ContractCall] = ids.map { MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint($0)], returns: MomentsABI.ledgerTuple) }
        if !hook.isZero { calls += ids.map { MomentsABI.call(hook, MomentsABI.Hook.creatorAccrued, [.uint($0)], returns: "uint256") } }
        let values = try await multicall.readAll(calls)
        let held = ids.enumerated().map { i, id in
            (id: id, proceeds: MomentsABI.ledger(values[i][0]).creatorClaimable, fees: hook.isZero ? BigUInt(0) : values[ids.count + i][0].uint)
        }
        return MomentsCreatorEarnings(moments: Self.creatorEarnings(held: held, withdrawn: withdrawn.logs, feesWithdrawn: fees.logs, account: account, factory: addresses.factory),
                                      complete: complete)
    }

    /// The ids of the Moments `account` published on `factory`, from its `Published` logs, oldest first, each once.
    nonisolated static func createdIds(_ published: [Log], account: Address, factory: Address) -> [BigUInt] {
        var seen = Set<BigUInt>()
        return published.compactMap { log -> BigUInt? in
            guard log.address == factory, let event = MomentsABI.published(log), event.creator == account, seen.insert(event.momentId).inserted else { return nil }
            return event.momentId
        }
        .sorted()
    }

    /// Pure half of `creatorEarnings`: what each created Moment still holds for the creator (`held`), and the
    /// withdrawals naming them summed for those Moments. A log read twice counts once.
    nonisolated static func creatorEarnings(held: [(id: BigUInt, proceeds: BigUInt, fees: BigUInt)], withdrawn: [Log], feesWithdrawn: [Log], account: Address,
                                            factory: Address) -> [MomentCreatorEarnings] {
        let created = Set(held.map(\.id))
        var seen = Set<String>()
        func sums(_ logs: [Log], topic: Data) -> [BigUInt: BigUInt] {
            var out: [BigUInt: BigUInt] = [:]
            for log in logs where log.topics.first == topic {
                guard let event = MomentsABI.withdrawn(log), event.beneficiary == account, created.contains(event.momentId),
                      seen.insert("\(log.address.hex)-\(log.transactionHash.hexString)-\(log.logIndex)").inserted else { continue }
                out[event.momentId, default: 0] += event.amount
            }
            return out
        }
        let proceeds = sums(withdrawn, topic: MomentsABI.Events.withdrawnTopic)
        let fees = sums(feesWithdrawn, topic: MomentsABI.Events.feesWithdrawnTopic)
        return held.map { item in
            MomentCreatorEarnings(key: MomentKey(factory: factory, id: item.id), proceedsWithdrawn: proceeds[item.id] ?? 0, proceedsUnclaimed: item.proceeds,
                                  feesWithdrawn: fees[item.id] ?? 0, feesUnclaimed: item.fees)
        }
    }
}

public extension RetiredMoments {
    /// What the account earned from the Moments it published on this retired cohort (`MomentsService.creatorEarnings`).
    func creatorEarnings(account: Address) async throws -> MomentsCreatorEarnings {
        try await service.creatorEarnings(account: account)
    }
}
