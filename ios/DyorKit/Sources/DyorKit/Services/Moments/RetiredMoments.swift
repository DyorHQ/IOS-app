import BigInt
import Foundation

/* Retired Moments cohorts (`MomentsAddresses.retiredMainnet`), CLAIM-ONLY. Cohorts 1 and 2 snapshotted the retired
   beneficiaries at publish (platform 0xf4D4…, treasury 0x5282… whose key leaked); cohort 3 pays the current fees wallet
   0x15ED… and treasury 0x5aDb…, and is retired because the v2 contracts replaced it (`MomentsAddresses.retirement`).
   Either way collecting, expiring, retrying a graduation, running a buyback, platform / treasury withdrawals and trading
   on a retired pool are all out of reach from here: on cohorts 1 and 2 each of them either pays the retired wallets or
   feeds a pool whose hook does, and the app serves no past cohort beyond what its people are owed. What stays is
   exactly that — vested coins, and the creator's own proceeds and pool fees. The service below is v1 (`generation`),
   so it never sends a v2-only getter to a retired cohort. */

/// The only writes a retired cohort allows.
public enum RetiredMomentAction: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// `vesting.claim(id)`: mints the caller's vested coins (its collects and, for the creator, the allocation).
    case claim
    /// `collect.withdrawCreator(id)`: the collect-time creator share, paid to the creator only.
    case withdrawCreatorProceeds
    /// `hook.withdrawCreator(id)`: the creator's share of the pool fees, paid to the creator only.
    case withdrawCreatorFees

    public var id: String { rawValue }
}

/// A retired Moment the wallet still has something in, keyed by (factory, id).
public struct RetiredMomentPosition: Sendable, Hashable, Identifiable {
    public let row: MomentPortfolioRow
    /// Collect-time creator share still to withdraw (non-zero only for the creator).
    public let creatorProceeds: BigUInt
    /// Pool fees still to withdraw (non-zero only for the creator).
    public let creatorFees: BigUInt
    /// When the position was read (unix seconds): a Moment past its deadline has missed graduation from then on.
    public let asOf: Int

    public init(row: MomentPortfolioRow, creatorProceeds: BigUInt, creatorFees: BigUInt, asOf: Int = Int(Date().timeIntervalSince1970)) {
        self.row = row
        self.creatorProceeds = creatorProceeds
        self.creatorFees = creatorFees
        self.asOf = asOf
    }

    public var info: MomentInfo { row.moment }
    public var key: MomentKey { row.moment.key }
    public var id: MomentKey { key }
    /// Vested coins claimable now (only a graduated Moment vests).
    public var claimable: BigUInt { info.graduated ? row.claimable : 0 }
    /// Creator USDC waiting: collect proceeds plus pool fees.
    public var creatorWithdrawable: BigUInt { creatorProceeds + creatorFees }
    /// Something to claim or hold: coins claimable or still vesting, creator withdrawals, editions or coins in the
    /// wallet, or coins promised by a Moment that may still graduate. The promise of a Moment that missed graduation
    /// (expired, or collecting past its deadline, which nothing in the app expires on a retired cohort) never vests,
    /// so on its own it does not count.
    public var isOpen: Bool {
        if claimable > 0 || creatorWithdrawable > 0 || row.nftBalance > 0 || row.coinBalance > 0 { return true }
        return !info.missedGraduation(at: asOf) && row.entitlement > row.claimed
    }
}

/// One retired cohort. Reads go through its own `MomentsService` (its contracts, and its deployment block for history
/// scans); the only transactions it can build are `RetiredMomentAction`s against its own vesting, collect and hook.
/// The service stays internal so nothing in the app can reach a collect / expire / retry / buyback / platform or
/// treasury plan for a retired Moment.
public struct RetiredMoments: Sendable {
    public let addresses: MomentsAddresses
    let service: MomentsService

    public init(rpc: RPCClient, addresses: MomentsAddresses, logsRPC: RPCClient? = nil) {
        self.addresses = addresses
        service = MomentsService(rpc: rpc, addresses: addresses, logsRPC: logsRPC)
    }

    public var factory: Address { addresses.factory }
    /// Why the cohort is retired (what its pages say).
    public var retirement: MomentsRetirement { addresses.retirement ?? .replaced }

    // MARK: Reads

    /// The cohort's Moments, newest first, read from the chain: every pinned one (`MomentLink.Cohort.finalMomentCount`,
    /// whose coins are `MomentsAddresses.retiredMainnetCoins`), always, by id, then up to `laterLimit` of the newest
    /// published after the pin — cohort 3's publishing is not paused (owner decision 2026-09-28). However many Moments
    /// are published after the pin, none can push a pinned one off the list and hide what its holders are owed.
    public func moments() async throws -> [MomentInfo] {
        try await service.moments(pinned: MomentLink.Cohort(factory: factory)?.finalMomentCount ?? 0, later: Self.laterLimit)
    }

    /// How many of the Moments published after a cohort's pin are read (`moments`).
    static let laterLimit = 100

    /// A refreshed `MomentInfo` for an id of THIS cohort.
    public func info(id: BigUInt) async throws -> MomentInfo? {
        try await service.info(id: id)
    }

    /// Fresh `MomentInfo`s for many ids of THIS cohort, in one read and one hydration (`MomentsService.infos`).
    public func infos(ids: [BigUInt]) async throws -> [MomentInfo] {
        try await service.infos(ids: ids)
    }

    /// The account's stake in one of this cohort's Moments; a Moment of another cohort is refused rather than read
    /// under the wrong contracts.
    public func accountView(_ info: MomentInfo, account: Address) async throws -> MomentAccountView {
        guard info.moment.factory == factory else { throw MomentsService.MomentsError.unknownMoment }
        return try await service.accountView(info, account: account)
    }

    /// The Moments of this cohort the account still has something in (see `RetiredMomentPosition.isOpen`).
    public func positions(account: Address, moments: [MomentInfo]? = nil) async throws -> [RetiredMomentPosition] {
        let list: [MomentInfo]
        if let moments { list = moments.filter { $0.moment.factory == factory } } else { list = try await self.moments() }
        guard !list.isEmpty else { return [] }
        let portfolio = try await service.portfolio(account: account, moments: list)
        return Self.positions(rows: portfolio.rows, moments: list, account: account)
    }

    /// Everything the account did on this cohort since its deployment block; every record carries this factory.
    public func history(account: Address) async -> MomentsAccountHistory {
        await service.history(account: account)
    }

    // MARK: The only writes

    public func plan(_ action: RetiredMomentAction, momentId: BigUInt, symbol: String) -> [TransactionStep] {
        Self.plan(action, momentId: momentId, symbol: symbol, addresses: addresses)
    }

    /// One call, no approval, no value: a vesting claim, or a creator withdrawal (the contracts pay `msg.sender` and
    /// only when it is the Moment's creator), always to this cohort's own contracts.
    static func plan(_ action: RetiredMomentAction, momentId: BigUInt, symbol: String, addresses: MomentsAddresses) -> [TransactionStep] {
        switch action {
        case .claim:
            return [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claim, [.uint(momentId)])), label: "Claim \(symbol)")]
        case .withdrawCreatorProceeds:
            return [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawCreator, [.uint(momentId)])), label: "Withdraw creator proceeds")]
        case .withdrawCreatorFees:
            return [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawCreator, [.uint(momentId)])), label: "Withdraw creator fees")]
        }
    }

    /// Pure half of `positions`. The portfolio rows are matched to their Moments by (factory, id); a Moment the
    /// account only created (no allocation, nothing collected or held) has no row, so its creator proceeds and pool
    /// fees get one here. `now` decides which Moments have missed graduation (`RetiredMomentPosition.isOpen`).
    static func positions(rows: [MomentPortfolioRow], moments: [MomentInfo], account: Address, now: Int = Int(Date().timeIntervalSince1970)) -> [RetiredMomentPosition] {
        let rowsByKey = Dictionary(rows.map { ($0.moment.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [RetiredMomentPosition] = []
        for info in moments {
            let isCreator = info.moment.creator == account
            let proceeds = isCreator ? info.ledger.creatorClaimable : 0
            let fees = isCreator ? (info.pool?.creatorFees ?? 0) : 0
            let row = rowsByKey[info.key]
                ?? (proceeds + fees > 0 ? MomentPortfolioRow(moment: info, entitlement: 0, claimed: 0, claimableCollector: 0, claimableCreator: 0, nftBalance: 0, coinBalance: 0, isCreator: true) : nil)
            guard let row else { continue }
            let position = RetiredMomentPosition(row: row, creatorProceeds: proceeds, creatorFees: fees, asOf: now)
            if position.isOpen { out.append(position) }
        }
        return out
    }
}
