import BigInt
import Foundation

/* The wallet's history as the screens read it: five scans kept on the device (`HistoryStore`), each refreshed
   incrementally, and turned into the records the Portfolio, the activity feeds, My Launchpad, My Moments and the Send
   sheet show — swaps, curve fills, fees received, Moments collects and proceeds, the tokens that ever paid the wallet.
   `cached` builds them from what is held, with no network; `refresh` reads on within a budget and builds them again.
   Every record's time is estimated from the head the entry last read, so a cached history keeps its times offline. */

/// The wallet's scans. Every DyorHQ event names the wallet as an indexed topic, so each scan is one filter.
public enum WalletHistoryScans {
    /// How far back the transfer scans read at least: 30 days at Monad's pace — further, to the wallet's first
    /// transaction, once that is known (`WalletHistoryService`), so every swap the wallet ever made counts.
    public static let transferDays: TimeInterval = 30 * 86_400
    static let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    public static var transferBlocks: UInt64 { BlockClock.blocks(in: transferDays, secondsPerBlock: BlockClock.fallbackSecondsPerBlock) }
    public static var transferFloor: HistoryScan.Floor { .blocks(transferBlocks) }

    public static let transfersInId = "transfers-in"
    public static let transfersOutId = "transfers-out"
    public static let launchpadId = "launchpad"
    public static let feeSharingId = "fee-sharing"
    public static let momentsId = "moments"

    /// Every ERC-20 `Transfer` into the wallet: swaps' received legs, and every token that ever paid it.
    public static func transfersIn(wallet: Address, floor: HistoryScan.Floor = transferFloor) -> HistoryScan {
        HistoryScan(id: transfersInId, query: LogsQuery(addresses: [], topics: [[transferTopic], nil, [wallet.data.leftPadded(to: 32)]]), floor: floor)
    }

    /// Every ERC-20 `Transfer` out of the wallet: swaps' spent legs.
    public static func transfersOut(wallet: Address, floor: HistoryScan.Floor = transferFloor) -> HistoryScan {
        HistoryScan(id: transfersOutId, query: LogsQuery(addresses: [], topics: [[transferTopic], [wallet.data.leftPadded(to: 32)]]), floor: floor)
    }

    /// The wallet's curve fills (`CurveBuy` / `CurveSell` index the trader first) and the creator fees an escrow paid it
    /// or it claimed (the escrow indexes the recipient first), on every launchpad stack, from the first escrow's block.
    /// No address filter: a curve is one of hundreds; the records are matched to the stacks' curves and escrows.
    public static func launchpad(wallet: Address) -> HistoryScan {
        let events = LaunchpadABI.Events.self
        return HistoryScan(id: launchpadId,
                           query: LogsQuery(addresses: [], topics: [[events.buyTopic, events.sellTopic, events.escrowPaidTopic, events.escrowPaidTokenTopic, events.escrowClaimedTopic, events.escrowClaimedTokenTopic],
                                                                      [wallet.data.leftPadded(to: 32)]]),
                           floor: .block(LaunchpadAddresses.feeHistoryStart))
    }

    /// Holder rewards the wallet claimed from fee sharing (`Claimed(token, account, amount)` indexes the account second)
    /// on every stack.
    public static func feeSharing(wallet: Address, stacks: [LaunchpadAddresses]) -> HistoryScan {
        HistoryScan(id: feeSharingId, query: LogsQuery(addresses: unique(stacks.map(\.holderFeeSharing)), topics: [[LaunchpadABI.Events.sharingClaimedTopic], nil, [wallet.data.leftPadded(to: 32)]]),
                    floor: .block(LaunchpadAddresses.feeHistoryStart))
    }

    /// Everything the wallet did on Moments, in every cohort: collects, vesting claims, proceeds and pool-fee
    /// withdrawals, publishes. Each event indexes the wallet second; the emitting contract says which cohort.
    public static func moments(wallet: Address, cohorts: [MomentsAddresses]) -> HistoryScan {
        let events = MomentsABI.Events.self
        let deployed = cohorts.filter(\.isDeployed)
        let contracts = unique(deployed.flatMap { [$0.factory, $0.collect, $0.vesting, $0.hook] }.filter { !$0.isZero })
        return HistoryScan(id: momentsId, query: LogsQuery(addresses: contracts, topics: [[events.collectedTopic, events.claimedTopic, events.withdrawnTopic, events.feesWithdrawnTopic, events.publishedTopic], nil,
                                                                                           [wallet.data.leftPadded(to: 32)]]),
                           floor: .block(deployed.map(\.deployBlock).min() ?? 0))
    }

    static func unique(_ list: [Address]) -> [Address] {
        var seen = Set<Address>()
        return list.filter { !$0.isZero && seen.insert($0).inserted }
    }
}

/// How far one scan has got.
public struct HistoryStatus: Sendable, Equatable {
    /// Every block from the floor to the head read.
    public let complete: Bool
    /// How much of them was, 0 to 1.
    public let progress: Double
    /// The last refresh reached the chain (false: it couldn't, and nothing moved).
    public let reachedChain: Bool
    public let updatedAt: Date?
    /// The scan's window at the last refresh: the oldest block it reads, and the head.
    public let floor: UInt64?
    public let head: UInt64?

    init(_ entry: HistoryEntry) {
        complete = entry.complete
        progress = entry.progress
        reachedChain = entry.reachedChain
        updatedAt = entry.updatedAt
        floor = entry.floor
        head = entry.head
    }

    init(complete: Bool, progress: Double, reachedChain: Bool, updatedAt: Date?, floor: UInt64?, head: UInt64?) {
        self.complete = complete
        self.progress = progress
        self.reachedChain = reachedChain
        self.updatedAt = updatedAt
        self.floor = floor
        self.head = head
    }

    public static let none = HistoryStatus(.empty)

    /// The same state, said not to have reached the chain: a scan left behind when rounds of reading stop short.
    func unreached() -> HistoryStatus {
        HistoryStatus(complete: complete, progress: progress, reachedChain: false, updatedAt: updatedAt, floor: floor, head: head)
    }
}

/// The wallet's history as the screens read it, from the five scans.
public struct WalletHistorySnapshot: Sendable {
    /// The head the records' times are estimated from; nil before any scan read the chain.
    public var anchor: BlockHeader?
    public var swaps: [SwapRecord]
    public var launch: LaunchpadWalletHistory
    public var feeIncome: LaunchpadFeeIncome
    public var moments: MomentsAccountHistory
    /// Every `Transfer` into the wallet, for what it holds (`WalletTokenDiscovery.held`).
    public var transfersIn: [Log]
    /// Each scan's state, by its id.
    public var status: [String: HistoryStatus]

    public static let empty = WalletHistorySnapshot(anchor: nil, swaps: [], launch: .empty, feeIncome: LaunchpadFeeIncome(paid: [:], claimed: [:], rewardsClaimed: [:], complete: false),
                                                    moments: .empty, transfersIn: [], status: [:])

    public func status(_ id: String) -> HistoryStatus { status[id] ?? .none }
    /// Whether every scan has read its whole window.
    public var complete: Bool { WalletHistoryScans.ids.allSatisfy { status($0).complete } }
    /// Whether any scan is still behind, with the chain reachable: history is still filling in.
    public var filling: Bool { WalletHistoryScans.ids.contains { let s = status($0); return !s.complete && s.reachedChain } }
    /// How much of every scan's window has been read, 0 to 1.
    public var progress: Double { WalletHistoryScans.ids.reduce(0) { $0 + status($1).progress } / Double(WalletHistoryScans.ids.count) }
    /// Whether the last refresh of some scan couldn't reach the chain.
    public var unreachable: Bool { WalletHistoryScans.ids.contains { !status($0).reachedChain } }

    /// The same history, every scan still behind said not to have reached the chain: what the app publishes when
    /// rounds of reading stop short (`HistoryModel`), so a screen says the rest couldn't be read, with Retry, rather
    /// than that it is still being read. Scans that read their whole window keep their state.
    public func stalled() -> WalletHistorySnapshot {
        var copy = self
        for id in WalletHistoryScans.ids where !status(id).complete { copy.status[id] = status(id).unreached() }
        return copy
    }
}

public extension WalletHistoryScans {
    static let ids = [transfersInId, transfersOutId, launchpadId, feeSharingId, momentsId]
}

/// Builds the wallet's history from the store, and refreshes it.
public actor WalletHistoryService {
    private let store: HistoryStore
    private let swapHistory: SwapHistoryService
    private let clock: BlockClock
    private let stacks: @Sendable () async -> [LaunchpadAddresses]
    private let cohorts: [MomentsAddresses]
    /// Swaps reconstructed from the same transfer logs are kept: the one-sided ones cost transaction reads.
    private var swapCache: [String: (fingerprint: String, swaps: [SwapRecord])] = [:]
    /// What the swap reconstruction looked up per transaction, by wallet (`SwapHistoryService.TransactionFacts`).
    private var swapFacts: [String: [Data: SwapHistoryService.TransactionFacts]] = [:]
    /// The block of a wallet's first transaction (`RPCClient.firstTransactionBlock`): nil when it has sent none; throws
    /// when it couldn't be read, to be asked again.
    private let firstActivity: @Sendable (Address) async throws -> UInt64?
    /// What `firstActivity` answered, by wallet: a block, or none (not kept: a wallet that sends its first
    /// transaction later is asked again).
    private var firstBlocks: [String: UInt64] = [:]

    /// `stacks`: every launchpad stack whose fills and fees count (the live one and the retired ones); `cohorts`: every
    /// Moments cohort, the live one first; `firstActivity`: the wallet's first transaction's block, for the transfer
    /// scans to read back to (nil, the default, keeps them to their window).
    public init(store: HistoryStore, swapHistory: SwapHistoryService, clock: BlockClock, stacks: @escaping @Sendable () async -> [LaunchpadAddresses], cohorts: [MomentsAddresses],
                firstActivity: @escaping @Sendable (Address) async throws -> UInt64? = { _ in nil }) {
        self.store = store
        self.swapHistory = swapHistory
        self.clock = clock
        self.stacks = stacks
        self.cohorts = cohorts
        self.firstActivity = firstActivity
    }

    public var history: HistoryStore { store }

    /// The scans for `wallet`.
    public func scans(wallet: Address) async -> [HistoryScan] {
        let stacks = await stacks()
        let floor = await transferFloor(wallet)
        return [WalletHistoryScans.transfersIn(wallet: wallet, floor: floor), WalletHistoryScans.transfersOut(wallet: wallet, floor: floor), WalletHistoryScans.launchpad(wallet: wallet),
                WalletHistoryScans.feeSharing(wallet: wallet, stacks: stacks), WalletHistoryScans.moments(wallet: wallet, cohorts: cohorts)]
    }

    /// How far back the transfer scans read for `wallet`: to its first transaction when that is older than the usual
    /// window (`WalletHistoryScans.transferDays`), so every swap it ever made counts; the window alone when it never
    /// sent one, or until its first transaction's block can be read.
    private func transferFloor(_ wallet: Address) async -> HistoryScan.Floor {
        let key = wallet.hex.lowercased()
        if let first = firstBlocks[key] { return .earliest(block: first, blocks: WalletHistoryScans.transferBlocks) }
        guard let first = try? await firstActivity(wallet) else { return WalletHistoryScans.transferFloor }
        firstBlocks[key] = first
        return .earliest(block: first, blocks: WalletHistoryScans.transferBlocks)
    }

    /// The history from what is held, with no scan: instant. `curves`: the curves whose fills count (every stack's
    /// launches); `decimals`: the tokens' decimals, for telling a swap's legs apart.
    public func cached(wallet: Address, curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        var entries: [String: HistoryEntry] = [:]
        for scan in await scans(wallet: wallet) { entries[scan.id] = await store.cached(scan, wallet: wallet) }
        return await snapshot(wallet: wallet, entries: entries, curves: curves, decimals: decimals)
    }

    /// Reads on in every scan, each within `budget`, all at once through the gate, and builds the history again.
    /// Forgets everything held for `wallet` (an erase of this device's data): the store's entries and what was
    /// built from them here.
    public func forget(wallet: Address) async {
        swapCache[wallet.hex] = nil
        swapFacts[wallet.hex] = nil
        await store.forget(wallet: wallet)
    }

    public func refresh(wallet: Address, budget: LogsBudget, curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        let scans = await scans(wallet: wallet)
        let entries = await withTaskGroup(of: (String, HistoryEntry).self) { group in
            for scan in scans { group.addTask { [store] in (scan.id, await store.refresh(scan, wallet: wallet, budget: budget)) } }
            var out: [String: HistoryEntry] = [:]
            for await (id, entry) in group { out[id] = entry }
            return out
        }
        return await snapshot(wallet: wallet, entries: entries, curves: curves, decimals: decimals)
    }

    private func snapshot(wallet: Address, entries: [String: HistoryEntry], curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        let stacks = await stacks()
        let secondsPerBlock = await clock.secondsPerBlock()
        // The newest head any scan read anchors every record's time.
        let anchor = entries.values.compactMap(\.anchor).max { $0.number < $1.number }
        var status: [String: HistoryStatus] = [:]
        for (id, entry) in entries { status[id] = HistoryStatus(entry) }
        let transfersIn = entries[WalletHistoryScans.transfersInId]?.logs ?? []
        let transfersOut = entries[WalletHistoryScans.transfersOutId]?.logs ?? []
        let launchpadLogs = entries[WalletHistoryScans.launchpadId]?.logs ?? []
        let sharingLogs = entries[WalletHistoryScans.feeSharingId]?.logs ?? []
        let momentsLogs = entries[WalletHistoryScans.momentsId]?.logs ?? []
        guard let anchor else { return WalletHistorySnapshot(anchor: nil, swaps: [], launch: .empty, feeIncome: WalletHistorySnapshot.empty.feeIncome, moments: .empty, transfersIn: transfersIn, status: status) }

        let swaps = await swaps(wallet: wallet, outgoing: transfersOut, incoming: transfersIn, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals)
        let launch = Self.launch(launchpadLogs, sharing: sharingLogs, stacks: stacks, curves: curves, anchor: anchor, secondsPerBlock: secondsPerBlock)
        let income = Self.feeIncome(launchpadLogs, sharing: sharingLogs, stacks: stacks,
                                    complete: (entries[WalletHistoryScans.launchpadId]?.complete ?? false) && (entries[WalletHistoryScans.feeSharingId]?.complete ?? false))
        let moments = Self.moments(momentsLogs, cohorts: cohorts, anchor: anchor, secondsPerBlock: secondsPerBlock)
        return WalletHistorySnapshot(anchor: anchor, swaps: swaps, launch: launch, feeIncome: income, moments: moments, transfersIn: transfersIn, status: status)
    }

    private func swaps(wallet: Address, outgoing: [Log], incoming: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int]) async -> [SwapRecord] {
        // The logs the swaps were built from and the decimals that weigh their legs, not the head: the same give the
        // same swaps, timed from the newest head.
        let fingerprint = "\(outgoing.count)-\(incoming.count)-\(outgoing.last?.id ?? "")-\(incoming.last?.id ?? "")-\(decimals.hashValue)"
        if let cached = swapCache[wallet.hex], cached.fingerprint == fingerprint {
            return cached.swaps.map { $0.timed(anchor: anchor, secondsPerBlock: secondsPerBlock) }
        }
        // What was looked up per transaction last time is kept: a round that added a few logs looks up the new ones only.
        let (swaps, facts) = await swapHistory.reconstruct(wallet: wallet, outgoing: outgoing, incoming: incoming, anchor: anchor, secondsPerBlock: secondsPerBlock,
                                                          decimals: decimals, limit: 2_000, facts: swapFacts[wallet.hex] ?? [:])
        swapFacts[wallet.hex] = facts
        // A sale into MON whose MON couldn't be read this time is read again at the next build, not kept.
        if !swaps.contains(where: \.boughtNativeUnknown) { swapCache[wallet.hex] = (fingerprint, swaps) }
        return swaps
    }

    /// The launchpad records from the launchpad and fee-sharing scans: fills on the stacks' curves, and fees from their
    /// escrows and fee-sharing contracts only (an unrelated contract may emit an event of the same shape).
    nonisolated static func launch(_ logs: [Log], sharing: [Log], stacks: [LaunchpadAddresses], curves: Set<Address>, anchor: BlockHeader, secondsPerBlock: Double) -> LaunchpadWalletHistory {
        let events = LaunchpadABI.Events.self
        let escrows = Set(stacks.map(\.escrow))
        let sharings = Set(stacks.map(\.holderFeeSharing))
        func those(_ topic: Data, of set: Set<Address>? = nil) -> [Log] { logs.filter { $0.topics.first == topic && (set == nil || set!.contains($0.address)) } }
        return LaunchpadService.walletHistory(buys: those(events.buyTopic), sells: those(events.sellTopic),
                                              escrowNative: those(events.escrowClaimedTopic, of: escrows), escrowToken: those(events.escrowClaimedTokenTopic, of: escrows),
                                              sharing: sharing.filter { sharings.contains($0.address) },
                                              paid: those(events.escrowPaidTopic, of: escrows), paidToken: those(events.escrowPaidTokenTopic, of: escrows),
                                              anchor: anchor, secondsPerBlock: secondsPerBlock, curves: curves)
    }

    /// What the wallet received in launchpad fees, from the same scans (`LaunchpadService.feeIncome`).
    nonisolated static func feeIncome(_ logs: [Log], sharing: [Log], stacks: [LaunchpadAddresses], complete: Bool) -> LaunchpadFeeIncome {
        let escrows = Set(stacks.map(\.escrow))
        let sharings = Set(stacks.map(\.holderFeeSharing))
        let income = LaunchpadService.feeIncome(escrowLogs: logs.filter { escrows.contains($0.address) }, sharingLogs: sharing.filter { sharings.contains($0.address) })
        return LaunchpadFeeIncome(paid: income.paid, claimed: income.claimed, rewardsClaimed: income.rewardsClaimed, complete: complete)
    }

    /// The Moments records from the Moments scan, each cohort's from its own contracts.
    nonisolated static func moments(_ logs: [Log], cohorts: [MomentsAddresses], anchor: BlockHeader, secondsPerBlock: Double) -> MomentsAccountHistory {
        let events = MomentsABI.Events.self
        var histories: [MomentsAccountHistory] = []
        for cohort in cohorts where cohort.isDeployed {
            func those(_ topic: Data, from contract: Address) -> [Log] { logs.filter { $0.address == contract && $0.topics.first == topic } }
            histories.append(MomentsService.history(collected: those(events.collectedTopic, from: cohort.collect), claimed: those(events.claimedTopic, from: cohort.vesting),
                                                    withdrawn: those(events.withdrawnTopic, from: cohort.collect), feesWithdrawn: those(events.feesWithdrawnTopic, from: cohort.hook),
                                                    published: those(events.publishedTopic, from: cohort.factory), anchor: anchor, secondsPerBlock: secondsPerBlock, factory: cohort.factory))
        }
        return MomentsAccountHistory.merged(histories)
    }

    /// The logs of the Moments scan for one cohort, for its creator earnings (`MomentsService.creatorEarnings(account:logs:)`).
    public func momentsLogs(wallet: Address, cohort: MomentsAddresses) async -> (published: [Log], withdrawn: [Log], feesWithdrawn: [Log], complete: Bool) {
        let entry = await store.cached(WalletHistoryScans.moments(wallet: wallet, cohorts: cohorts), wallet: wallet)
        let events = MomentsABI.Events.self
        func those(_ topic: Data, from contract: Address) -> [Log] { entry.logs.filter { $0.address == contract && $0.topics.first == topic } }
        return (those(events.publishedTopic, from: cohort.factory), those(events.withdrawnTopic, from: cohort.collect), those(events.feesWithdrawnTopic, from: cohort.hook), entry.complete)
    }
}
