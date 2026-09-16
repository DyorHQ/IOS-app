import BigInt
import Foundation

/// A wallet that can sign a raw 32-byte digest — what a Permit2 collect needs. Both the Privy embedded wallet and an
/// imported local wallet provide it in the app.
public protocol MomentsPermitSigner: Sendable {
    var address: Address { get }
    /// Returns the 65-byte `[r ‖ s ‖ v]` signature as `0x`-hex with `v` as 27/28.
    func signDigest(_ digest: Data) async throws -> String
}

/// The Moments client: every read comes straight from the contracts through Multicall3, every write is a
/// `TransactionStep` plan for `TransactionSender`. A port of the web app's `moments/reads.ts` + `actions.ts`; the
/// derivations are identical so both clients agree to the wei.
public actor MomentsService {
    public let rpc: RPCClient
    /// Where event history is read; a local fork keeps logs on the same node.
    public let logsRPC: RPCClient
    public let addresses: MomentsAddresses
    let multicall: Multicall
    public static let blockSeconds = 0.4

    public init(rpc: RPCClient, addresses: MomentsAddresses, logsRPC: RPCClient? = nil) {
        self.rpc = rpc
        self.addresses = addresses
        let text = rpc.url.absoluteString
        let local = text.contains("127.0.0.1") || text.contains("localhost")
        self.logsRPC = logsRPC ?? (local ? rpc : RPCClient(url: LaunchpadService.defaultLogsRPC))
        multicall = Multicall(rpc: rpc)
    }

    public nonisolated var isDeployed: Bool { addresses.isDeployed }

    public enum MomentsError: Error, LocalizedError, Equatable {
        case notDeployed
        case unknownMoment
        case notCollecting(String)
        case signerRequired

        public var errorDescription: String? {
            switch self {
            case .notDeployed: return "Moments are not live on this network yet."
            case .unknownMoment: return "That Moment does not exist."
            case .notCollecting(let why): return why
            case .signerRequired: return "Sign in with a wallet that can sign to collect."
            }
        }
    }

    // MARK: - Policy

    public func policy() async throws -> MomentPolicy? {
        guard isDeployed else { return nil }
        let f = addresses.factory
        let values = try await multicall.readAll([
            MomentsABI.call(f, MomentsABI.Factory.policy, returns: MomentsABI.policyFlat),
            MomentsABI.call(f, MomentsABI.Factory.momentCount, returns: "uint256"),
            MomentsABI.call(f, MomentsABI.Factory.publishingPaused, returns: "bool"),
            MomentsABI.call(f, MomentsABI.Factory.externalBaseURI, returns: "string"),
        ])
        let p = values[0]
        return MomentPolicy(
            threshold: p[0].uint, minPrice: p[1].uint, creatorBps: MomentsABI.int(p[2]), platformBps: MomentsABI.int(p[3]), reserveBps: MomentsABI.int(p[4]),
            maxCreatorAllocBps: MomentsABI.int(p[5]), expiryCreatorBps: MomentsABI.int(p[6]), royaltyBps: MomentsABI.int(p[7]), platform: p[8].address, treasury: p[9].address,
            momentCount: MomentsABI.int(values[1][0]), publishingPaused: values[2][0].bool, externalBaseURI: values[3][0].string
        )
    }

    // MARK: - Moments

    /// The newest Moments first.
    public func moments(limit: Int = 48) async throws -> [MomentInfo] {
        guard isDeployed, limit > 0 else { return [] }
        let total = MomentsABI.int(try await multicall.readAll([MomentsABI.call(addresses.factory, MomentsABI.Factory.momentCount, returns: "uint256")])[0][0])
        guard total > 0 else { return [] }
        let first = max(1, total - limit + 1)
        let ids = stride(from: total, through: first, by: -1).map { BigUInt($0) }
        let raws = try await multicall.readAll(ids.map { MomentsABI.call(addresses.factory, MomentsABI.Factory.getMoment, [.uint($0)], returns: MomentsABI.momentTuple) })
        let moments = zip(ids, raws).map { MomentsABI.moment(id: $0, $1[0]) }
        return try await hydrate(moments)
    }

    /// One Moment with the supply identity, or nil when the id is out of range.
    public func moment(id: BigUInt) async throws -> MomentDetail? {
        guard isDeployed, id > 0 else { return nil }
        let head = try await multicall.readAll([
            MomentsABI.call(addresses.factory, MomentsABI.Factory.momentCount, returns: "uint256"),
        ])
        guard id <= head[0][0].uint else { return nil }
        let raw = try await multicall.readAll([MomentsABI.call(addresses.factory, MomentsABI.Factory.getMoment, [.uint(id)], returns: MomentsABI.momentTuple)])[0][0]
        let m = MomentsABI.moment(id: id, raw)
        guard let info = try await hydrate([m]).first else { return nil }
        let extras = try await multicall.readAll([
            MomentsABI.call(addresses.collect, MomentsABI.Collect.supplyCheck, [.uint(id)], returns: "uint256,uint256,uint256,uint256,uint256"),
            MomentsABI.call(m.coin, MomentsABI.Coin.totalSupply, returns: "uint256"),
            MomentsABI.call(addresses.factory, MomentsABI.Factory.externalBaseURI, returns: "string"),
        ])
        let s = extras[0]
        let supply = MomentDetail.Supply(entitlements: s[0].uint, creatorAlloc: s[1].uint, remainderPool: s[2].uint, impliedPool: s[3].uint, collects: MomentsABI.int(s[4]))
        let base = extras[2][0].string
        return MomentDetail(info: info, supply: supply, coinTotalSupply: extras[1][0].uint, externalURL: base.isEmpty ? "" : base + String(id))
    }

    /// A refreshed `MomentInfo` for an id (the detail page polls this).
    public func info(id: BigUInt) async throws -> MomentInfo? {
        guard isDeployed, id > 0 else { return nil }
        let raw = try await multicall.read([MomentsABI.call(addresses.factory, MomentsABI.Factory.getMoment, [.uint(id)], returns: MomentsABI.momentTuple)])[0]
        guard case .success(let values) = raw else { return nil }
        return try await hydrate([MomentsABI.moment(id: id, values[0])]).first
    }

    /// The Moment id of a coin, 0 when the address is not a Moment coin.
    public func momentId(coin: Address) async throws -> BigUInt {
        guard isDeployed else { return 0 }
        return try await multicall.readAll([MomentsABI.call(addresses.factory, MomentsABI.Factory.momentIdByCoin, [.address(coin)], returns: "uint256")])[0][0].uint
    }

    /// Moment ids for many token addresses at once (only the ones that are Moment coins are returned).
    public func momentIds(coins: [Address]) async throws -> [Address: BigUInt] {
        guard isDeployed, !coins.isEmpty else { return [:] }
        let unique = Array(Set(coins))
        let values = try await multicall.readAll(unique.map { MomentsABI.call(addresses.factory, MomentsABI.Factory.momentIdByCoin, [.address($0)], returns: "uint256") })
        var out: [Address: BigUInt] = [:]
        for (coin, value) in zip(unique, values) where value[0].uint > 0 { out[coin] = value[0].uint }
        return out
    }

    /// Previews a collect exactly as the contract would settle it. Throws `notCollecting` with a readable reason
    /// when the Moment can't be collected.
    public func quote(id: BigUInt, quantity: Int) async throws -> CollectQuote {
        guard isDeployed else { throw MomentsError.notDeployed }
        let call = MomentsABI.call(addresses.collect, MomentsABI.Collect.quote, [.uint(id), .uint(quantity)], returns: MomentsABI.quoteTuple)
        do {
            let data = try await rpc.ethCall(CallRequest(from: nil, to: call.to, data: call.data, value: 0))
            let values = try ABI.decode(data, call.returnTypes)
            return MomentsABI.quote(values[0])
        } catch let error as RPCError {
            throw MomentsError.notCollecting(Self.collectReason(error))
        }
    }

    /// Custom-error selectors of `MomentCollect`, as sentences.
    static func collectReason(_ error: RPCError) -> String {
        if let data = error.data, let bytes = Data(hex: data), bytes.count >= 4 {
            switch bytes.prefix(4).hexString {
            case ABI.selector("CollectWindowClosed()").hexString: return "The collect window has closed."
            case ABI.selector("NotCollecting()").hexString: return "This Moment is no longer collecting."
            case ABI.selector("BadQuantity()").hexString: return "Choose between 1 and \(MomentsConstants.maxBatch) editions."
            case ABI.selector("UnknownMoment()").hexString: return "That Moment does not exist."
            default: break
            }
        }
        return RevertReason.describe(error)
    }

    // MARK: - Account

    public func accountView(_ info: MomentInfo, account: Address) async throws -> MomentAccountView {
        guard isDeployed else { throw MomentsError.notDeployed }
        let m = info.moment
        let id = m.id
        let usdc = addresses.usdc
        let values = try await multicall.readAll([
            try ERC20.balanceOf(usdc, account),
            try ERC20.allowance(usdc, owner: account, spender: addresses.permit2),
            try ERC20.allowance(usdc, owner: account, spender: addresses.collect),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.entitlement, [.uint(id), .address(account)], returns: "uint256"),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimed, [.uint(id), .address(account)], returns: "uint256"),
            MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimable, [.uint(id), .address(account)], returns: "uint256,uint256"),
            MomentsABI.call(m.coin, MomentsABI.Coin.balanceOf, [.address(account)], returns: "uint256"),
            MomentsABI.call(m.nft, MomentsABI.NFT.balanceOf, [.address(account)], returns: "uint256"),
            MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint(id)], returns: MomentsABI.ledgerTuple),
            MomentsABI.call(addresses.hook, MomentsABI.Hook.creatorAccrued, [.uint(id)], returns: "uint256"),
            MomentsABI.call(addresses.hook, MomentsABI.Hook.platformAccrued, [.uint(id)], returns: "uint256"),
        ])
        let nftBalance = MomentsABI.int(values[7][0])
        async let idsRead: [BigUInt] = nftBalance > 0
            ? (try multicall.readAll([MomentsABI.call(m.nft, MomentsABI.NFT.tokensOfOwner, [.address(account), .uint(0), .uint(50)], returns: "uint256[]")])[0][0].elements.map(\.uint))
            : []
        async let monRead = rpc.balance(of: account)
        let (nftIds, mon) = try await (idsRead, monRead)
        let ledger = MomentsABI.ledger(values[8][0])
        let isCreator = m.creator == account
        let isPlatform = m.platform == account
        let isTreasury = m.treasury == account
        return MomentAccountView(
            usdcBalance: values[0][0].uint, monBalance: mon, permit2Allowance: values[1][0].uint, collectAllowance: values[2][0].uint,
            entitlement: values[3][0].uint, claimed: values[4][0].uint, claimableCollector: values[5][0].uint, claimableCreator: values[5][1].uint,
            coinBalance: values[6][0].uint, nftBalance: nftBalance, nftIds: nftIds,
            creatorProceeds: isCreator ? ledger.creatorClaimable : 0, creatorFees: isCreator ? values[9][0].uint : 0,
            platformProceeds: isPlatform ? ledger.platformClaimable : 0, platformFees: isPlatform ? values[10][0].uint : 0,
            treasuryProceeds: isTreasury ? ledger.treasuryClaimable : 0
        )
    }

    /// Every Moment the account has a stake in: pending (not graduated), claimable now, still vesting, claimed.
    public func portfolio(account: Address, limit: Int = 200) async throws -> MomentPortfolio {
        let moments = try await self.moments(limit: limit)
        return try await portfolio(account: account, moments: moments)
    }

    /// Same, over an already-loaded list of Moments (saves the board re-read).
    public func portfolio(account: Address, moments: [MomentInfo]) async throws -> MomentPortfolio {
        guard isDeployed, !moments.isEmpty else { return .empty }
        var calls: [ContractCall] = []
        for info in moments {
            let id = info.id
            calls += [
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.entitlement, [.uint(id), .address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimed, [.uint(id), .address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.claimable, [.uint(id), .address(account)], returns: "uint256,uint256"),
                MomentsABI.call(info.moment.nft, MomentsABI.NFT.balanceOf, [.address(account)], returns: "uint256"),
                MomentsABI.call(info.moment.coin, MomentsABI.Coin.balanceOf, [.address(account)], returns: "uint256"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.creatorClaimed, [.uint(id)], returns: "uint256"),
            ]
        }
        let results = try await multicall.readAll(calls)
        let stride = 6
        var rows: [MomentPortfolioRow] = []
        var pending: BigUInt = 0, claimableTotal: BigUInt = 0, vesting: BigUInt = 0, claimed: BigUInt = 0
        for (i, info) in moments.enumerated() {
            let entitlement = results[i * stride][0].uint
            let claimedAmount = results[i * stride + 1][0].uint
            let claimableCollector = results[i * stride + 2][0].uint
            let claimableCreator = results[i * stride + 2][1].uint
            let nftBalance = MomentsABI.int(results[i * stride + 3][0])
            let coinBalance = results[i * stride + 4][0].uint
            let creatorClaimed = results[i * stride + 5][0].uint
            let isCreator = info.moment.creator == account
            let alloc = isCreator ? info.moment.creatorAllocation : 0
            guard entitlement > 0 || nftBalance > 0 || coinBalance > 0 || alloc > 0 else { continue }
            // `promised` is what this account will be able to claim in total: its collects plus, for the creator, the allocation.
            let promised = entitlement + alloc
            let claimedTotal = claimedAmount + (isCreator ? creatorClaimed : 0)
            let row = MomentPortfolioRow(moment: info, entitlement: promised, claimed: claimedTotal, claimableCollector: claimableCollector, claimableCreator: claimableCreator, nftBalance: nftBalance, coinBalance: coinBalance, isCreator: isCreator)
            rows.append(row)
            if !info.graduated {
                pending += promised
            } else {
                claimableTotal += row.claimable
                vesting += row.vesting
                claimed += claimedTotal
            }
        }
        return MomentPortfolio(rows: rows, pending: pending, claimable: claimableTotal, vesting: vesting, claimed: claimed)
    }

    /// Distinct NFT holders and the largest one, from `ownerOf` over every edition (editions are few and on-chain).
    public func nftHolders(nft: Address, editions: Int) async -> (holders: Int, topHolder: Address?, topCount: Int) {
        guard editions > 0 else { return (0, nil, 0) }
        let ids = (1...min(editions, 400)).map { BigUInt($0) }
        guard let owners = try? await multicall.read(ids.map { MomentsABI.call(nft, MomentsABI.NFT.ownerOf, [.uint($0)], returns: "address") }) else { return (0, nil, 0) }
        var counts: [Address: Int] = [:]
        for case .success(let values) in owners { counts[values[0].address, default: 0] += 1 }
        let top = counts.max { $0.value < $1.value }
        return (counts.count, top?.key, top?.value ?? 0)
    }

    /// The `Published` event of a publish transaction; nil while pending or when the transaction published nothing.
    public func publishResult(transaction hash: Data) async throws -> MomentPublishResult? {
        guard let logs = try await rpc.transactionLogs(hash) else { return nil }
        for log in logs where log.topics.first == MomentsABI.Events.publishedTopic && log.address == addresses.factory {
            if let event = MomentsABI.published(log) { return MomentPublishResult(momentId: event.momentId, creator: event.creator, coin: event.coin, nft: event.nft) }
        }
        return nil
    }

    // MARK: - Plans (writes)

    public func publishPlan(_ input: MomentPublishInput) -> [TransactionStep] {
        var salt = [UInt8](repeating: 0, count: 32)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        let data = MomentsABI.calldata(MomentsABI.Factory.publish, [MomentsABI.publishParams(input, salt: Data(salt))])
        return [.call(TransactionRequest(to: addresses.factory, data: data), label: "Publish \(input.symbol)")]
    }

    /// Collects `quantity` editions with a Permit2 signature: Permit2 is approved once for USDC (unlimited, the
    /// canonical pattern; the step is skipped when the allowance already covers it), then the collect itself
    /// carries a signed transfer for up to `price × quantity`. The contract only ever pulls the quoted gross.
    public func collectPlan(momentId: BigUInt, quantity: Int, price: BigUInt, signer: any MomentsPermitSigner, symbol: String) async throws -> [TransactionStep] {
        guard isDeployed else { throw MomentsError.notDeployed }
        let maxGross = price * BigUInt(quantity)
        let permit = Permit2Signature.Permit(token: addresses.usdc, amount: maxGross, nonce: Permit2Signature.randomNonce(), deadline: BigUInt(Int(Date().timeIntervalSince1970) + 30 * 60))
        let digest = try Permit2Signature.digest(permit: permit, spender: addresses.collect, permit2: addresses.permit2, chainId: Monad.chainId)
        guard let signature = Data(hex: try await signer.signDigest(digest)), signature.count == 65 else { throw TransactionError.rejected("The wallet returned an unreadable signature.") }
        let data = MomentsABI.calldata(MomentsABI.Collect.collectWithPermit2, [.uint(momentId), .uint(quantity), MomentsABI.permit(token: permit.token, amount: permit.amount, nonce: permit.nonce, deadline: permit.deadline), .bytes(signature)])
        let maxUint = (BigUInt(1) << 256) - 1
        return [
            .approve(token: addresses.usdc, spender: addresses.permit2, amount: maxUint, label: "Approve USDC for Permit2"),
            .call(TransactionRequest(to: addresses.collect, data: data), label: "Collect \(quantity) \(quantity == 1 ? "edition" : "editions") of \(symbol)"),
        ]
    }

    /// The plain-approval path: an exact USDC approval of the collect contract, then `collect`.
    public func collectWithApprovalPlan(momentId: BigUInt, quantity: Int, gross: BigUInt, symbol: String) -> [TransactionStep] {
        let data = MomentsABI.calldata(MomentsABI.Collect.collect, [.uint(momentId), .uint(quantity)])
        return [
            .approve(token: addresses.usdc, spender: addresses.collect, amount: gross, label: "Approve USDC"),
            .call(TransactionRequest(to: addresses.collect, data: data), label: "Collect \(quantity) \(quantity == 1 ? "edition" : "editions") of \(symbol)"),
        ]
    }

    public func claimPlan(momentId: BigUInt, symbol: String) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claim, [.uint(momentId)])), label: "Claim \(symbol)")]
    }

    public func claimAllPlan(momentIds: [BigUInt]) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.vesting, data: MomentsABI.calldata(MomentsABI.Vesting.claimAll, [.array(momentIds.map { .uint($0) })])), label: "Claim \(momentIds.count) \(momentIds.count == 1 ? "Moment" : "Moments")")]
    }

    public func withdrawCreatorProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawCreator, [.uint(momentId)])), label: "Withdraw creator proceeds")]
    }

    public func withdrawPlatformProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawPlatform, [.uint(momentId)])), label: "Withdraw platform proceeds")]
    }

    public func withdrawTreasuryProceedsPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.withdrawTreasury, [.uint(momentId)])), label: "Withdraw treasury share")]
    }

    public func withdrawCreatorFeesPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawCreator, [.uint(momentId)])), label: "Withdraw creator fees")]
    }

    public func withdrawPlatformFeesPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.hook, data: MomentsABI.calldata(MomentsABI.Hook.withdrawPlatform, [.uint(momentId)])), label: "Withdraw platform fees")]
    }

    public func retryGraduationPlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.graduation, data: MomentsABI.calldata(MomentsABI.Graduation.graduate, [.uint(momentId)])), label: "Retry graduation")]
    }

    public func expirePlan(momentId: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.collect, data: MomentsABI.calldata(MomentsABI.Collect.expire, [.uint(momentId)])), label: "Expire Moment")]
    }

    public func buybackPlan(momentId: BigUInt, minCoinOut: BigUInt) -> [TransactionStep] {
        [.call(TransactionRequest(to: addresses.buyback, data: MomentsABI.calldata(MomentsABI.Buyback.execute, [.uint(momentId), .uint(minCoinOut)])), label: "Run buyback")]
    }

    // MARK: - Hydration

    /// Ledger, NFT and coin metadata, entitlements and graduation for a page of Moments in one multicall, then the
    /// pool state of the graduated ones.
    private func hydrate(_ moments: [Moment]) async throws -> [MomentInfo] {
        guard !moments.isEmpty else { return [] }
        var calls: [ContractCall] = []
        for m in moments {
            calls += [
                MomentsABI.call(addresses.collect, MomentsABI.Collect.ledger, [.uint(m.id)], returns: MomentsABI.ledgerTuple),
                MomentsABI.call(m.nft, MomentsABI.NFT.totalMinted, returns: "uint256"),
                MomentsABI.call(m.nft, MomentsABI.NFT.closed, returns: "bool"),
                MomentsABI.call(m.nft, MomentsABI.NFT.provenance, returns: MomentsABI.provenanceTuple),
                MomentsABI.call(m.coin, MomentsABI.Coin.name, returns: "string"),
                MomentsABI.call(m.coin, MomentsABI.Coin.symbol, returns: "string"),
                MomentsABI.call(addresses.vesting, MomentsABI.Vesting.totalEntitlement, [.uint(m.id)], returns: "uint256"),
                MomentsABI.call(addresses.graduation, MomentsABI.Graduation.isGraduated, [.uint(m.id)], returns: "bool"),
            ]
        }
        let results = try await multicall.readAll(calls)
        let stride = 8
        var partial: [(Moment, MomentLedger, Int, Bool, MomentProvenance, String, String, BigUInt, Bool)] = []
        for (i, m) in moments.enumerated() {
            let base = i * stride
            partial.append((m, MomentsABI.ledger(results[base][0]), MomentsABI.int(results[base + 1][0]), results[base + 2][0].bool, MomentsABI.provenance(results[base + 3][0]),
                            results[base + 4][0].string, results[base + 5][0].string, results[base + 6][0].uint, results[base + 7][0].bool))
        }
        let graduatedIds = partial.filter { $0.8 }.map { $0.0.id }
        let pools = try await self.pools(ids: graduatedIds)
        return partial.map { m, ledger, editions, closed, provenance, name, symbol, entitlements, graduated in
            MomentInfo(
                moment: m, name: name, symbol: symbol, provenance: provenance, ledger: ledger, editions: editions, closed: closed, entitlements: entitlements,
                graduated: graduated, progressBps: MomentsMath.progressBps(reserve: ledger.reserve, threshold: m.threshold, state: graduated ? .graduated : ledger.state),
                pool: pools[m.id]
            )
        }
    }

    /// Pool state for graduated Moments: the graduation record, locked liquidity, accrued hook fees, buyback state,
    /// and the live sqrt price read straight from the PoolManager's storage.
    private func pools(ids: [BigUInt]) async throws -> [BigUInt: MomentPool] {
        guard !ids.isEmpty else { return [:] }
        var calls: [ContractCall] = [
            MomentsABI.call(addresses.buyback, MomentsABI.Buyback.minInterval, returns: "uint256"),
            MomentsABI.call(addresses.buyback, MomentsABI.Buyback.minAmount, returns: "uint256"),
        ]
        for id in ids {
            calls += [
                MomentsABI.call(addresses.graduation, MomentsABI.Graduation.record, [.uint(id)], returns: MomentsABI.recordTuple),
                MomentsABI.call(addresses.locker, MomentsABI.Locker.liquidityOf, [.uint(id)], returns: "uint128"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.creatorAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.platformAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.hook, MomentsABI.Hook.buybackAccrued, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.buyback, MomentsABI.Buyback.carry, [.uint(id)], returns: "uint256"),
                MomentsABI.call(addresses.buyback, MomentsABI.Buyback.lastRun, [.uint(id)], returns: "uint64"),
            ]
        }
        let results = try await multicall.readAll(calls)
        let interval = MomentsABI.int(results[0][0])
        let minAmount = results[1][0].uint
        let stride = 7
        var records: [(BigUInt, MomentsABI.GraduationRecord, BigUInt, BigUInt, BigUInt, BigUInt, BigUInt, Int)] = []
        for (i, id) in ids.enumerated() {
            let base = 2 + i * stride
            records.append((id, MomentsABI.record(results[base][0]), results[base + 1][0].uint, results[base + 2][0].uint, results[base + 3][0].uint, results[base + 4][0].uint, results[base + 5][0].uint, MomentsABI.int(results[base + 6][0])))
        }
        // Live prices: one extsload per pool, batched; a failed read falls back to the opening price.
        let priceReads = try? await multicall.read(records.map { MomentsABI.call(addresses.poolManager, MomentsABI.PoolManager.extsload, [.bytes(MomentsABI.slot0(of: $0.1.key.id))], returns: "bytes32") })
        var out: [BigUInt: MomentPool] = [:]
        for (i, entry) in records.enumerated() {
            let (id, record, liquidity, creator, platform, buyback, carry, lastRun) = entry
            let key = record.key
            let usdcIs0 = key.currency0 == addresses.usdc
            var sqrtPrice = record.sqrtPriceX96
            if let priceReads, case .success(let values) = priceReads[i] {
                let live = BigUInt(values[0].bytes) & ((BigUInt(1) << 160) - 1)
                if live > 0 { sqrtPrice = live }
            }
            out[id] = MomentPool(
                key: key, poolId: key.id, usdcIs0: usdcIs0, sqrtPriceX96: sqrtPrice, openingSqrtPriceX96: record.sqrtPriceX96, liquidity: liquidity, seedLiquidity: record.liquidity,
                reserveSeed: record.reserve, poolCoins: record.poolCoins, graduatedAt: record.at, usdcPerCoin: MomentsMath.usdcPerCoin(sqrtPriceX96: sqrtPrice, usdcIs0: usdcIs0),
                creatorFees: creator, platformFees: platform, buybackFees: buyback, buybackCarry: carry, lastBuyback: lastRun, buybackInterval: interval, buybackMin: minAmount
            )
        }
        return out
    }

    /// Estimated timestamp of `block` from the latest block and Monad's 0.4 s block time.
    nonisolated static func time(anchor: BlockHeader, block: UInt64) -> Date {
        let delta = Double(anchor.number > block ? anchor.number - block : 0) * blockSeconds
        return Date(timeIntervalSince1970: TimeInterval(anchor.timestamp)).addingTimeInterval(-delta)
    }
}
