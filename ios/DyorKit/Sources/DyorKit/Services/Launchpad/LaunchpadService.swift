import BigInt
import Foundation

/// The launchpad client: every read comes straight from the contracts through Multicall3, and every write is
/// a `TransactionStep` plan for `TransactionSender`. A port of the web app's `launchpad.ts` / `actions.ts`;
/// the derivations (price, market cap, progress) are identical so both apps agree to the wei.
public actor LaunchpadService {
    /// Where `eth_getLogs` goes on mainnet: rpc1.monad.xyz allows 1 000 blocks per request against 100 on rpc.monad.xyz.
    public static let defaultLogsRPC = URL(string: "https://rpc1.monad.xyz")!
    /// `LaunchpadFactory.MAX_EXEMPTIONS`.
    public static let maxExemptions = 32
    /// Monad block time, used to estimate event timestamps from block numbers.
    public static let blockSeconds = 0.4

    public let rpc: RPCClient
    /// The endpoint used for event history; a local fork keeps logs on the same node.
    public let logsRPC: RPCClient
    public private(set) var addresses: LaunchpadAddresses
    let multicall: Multicall
    private var pairCache: [Address: PairInfo] = [:]

    public init(rpc: RPCClient, addresses: LaunchpadAddresses, logsRPC: RPCClient? = nil) {
        self.rpc = rpc
        self.addresses = addresses
        let text = rpc.url.absoluteString
        let local = text.contains("127.0.0.1") || text.contains("localhost")
        self.logsRPC = logsRPC ?? (local ? rpc : RPCClient(url: Self.defaultLogsRPC))
        multicall = Multicall(rpc: rpc)
    }

    /// Swaps in the deployed addresses once they are known. Cached pair metadata survives; it is chain data.
    public func setAddresses(_ addresses: LaunchpadAddresses) {
        self.addresses = addresses
    }

    public var isDeployed: Bool { addresses.isDeployed }

    // MARK: - Pair assets

    /// Symbol and decimals of a pair asset; native MON needs no read. Cached for the life of the service.
    public func pairInfo(_ address: Address) async throws -> PairInfo {
        try await pairInfos([address])[address] ?? .mon
    }

    private func pairInfos(_ tokens: [Address]) async throws -> [Address: PairInfo] {
        var out: [Address: PairInfo] = [:]
        var missing: [Address] = []
        for token in Set(tokens) {
            if token.isZero {
                out[token] = .mon
            } else if let cached = pairCache[token] {
                out[token] = cached
            } else {
                missing.append(token)
            }
        }
        guard !missing.isEmpty else { return out }
        missing.sort { $0.hex < $1.hex }
        let calls = missing.flatMap { [LaunchpadABI.call($0, LaunchpadABI.Token.symbol, returns: "string"), LaunchpadABI.call($0, LaunchpadABI.Token.decimals, returns: "uint8")] }
        let results = try await multicall.readAll(calls)
        for (i, token) in missing.enumerated() {
            let info = PairInfo(address: token, symbol: results[2 * i][0].string, decimals: LaunchpadABI.int(results[2 * i + 1][0]), isNative: false)
            pairCache[token] = info
            out[token] = info
        }
        return out
    }

    // MARK: - Reads

    /// Factory policy, launch template 0 and the economics of native MON plus `extraPairTokens` (the ERC-20
    /// pairs the owner approved). Nil until the contracts are deployed.
    public func protocolInfo(extraPairTokens: [Address] = []) async throws -> ProtocolInfo? {
        guard addresses.isDeployed else { return nil }
        let factory = addresses.factory
        typealias F = LaunchpadABI.Factory
        let policy = try await multicall.readAll([
            LaunchpadABI.call(factory, F.launchFee, returns: "uint256"),
            LaunchpadABI.call(factory, F.launchConfigCount, returns: "uint256"),
            LaunchpadABI.call(factory, F.maxCreatorTaxBps, returns: "uint16"),
            LaunchpadABI.call(factory, F.whitelistEnabled, returns: "bool"),
            LaunchpadABI.call(factory, F.getLaunchFeePolicy, returns: "(address,uint16)"),
            LaunchpadABI.call(factory, F.launchCount, returns: "uint256"),
        ])
        let configId: BigUInt = 0
        let hasConfig = policy[1][0].uint > 0
        let pairTokens = [Address.zero] + extraPairTokens
        let configCalls: [ContractCall] = hasConfig ? [LaunchpadABI.call(factory, F.getLaunchConfig, [.uint(configId)], returns: LaunchpadABI.launchConfigTuple)] : []
        // Economics and the Monday-only flag are read for every pair: the create screen uses `mondayOnly` to force
        // the Monday graduation venue (and disable the picker) for aBIL, matching the factory's `PairRequiresMonday`.
        let econCalls = pairTokens.map { LaunchpadABI.call(factory, F.pairTokenEconomics, [.address($0)], returns: "uint256,uint256,uint8,bool") }
        let mondayOnlyCalls = pairTokens.map { LaunchpadABI.call(factory, F.pairMondayOnly, [.address($0)], returns: "bool") }
        let calls = configCalls + econCalls + mondayOnlyCalls
        async let economics = multicall.readAll(calls)
        async let infos = pairInfos(pairTokens)
        let (results, pairs) = try await (economics, infos)
        let config = hasConfig ? LaunchpadABI.LaunchConfig(results[0][0]) : nil
        let offset = hasConfig ? 1 : 0
        let mondayOffset = offset + pairTokens.count
        let pairEconomics = pairTokens.enumerated().map { i, token in
            let values = results[offset + i]
            let mondayOnly = results[mondayOffset + i][0].bool
            return PairEconomics(pair: pairs[token] ?? .mon, phantomQuote: values[0].uint, graduationThreshold: values[1].uint, approved: values[3].bool, mondayOnly: mondayOnly)
        }
        return ProtocolInfo(
            launchFee: policy[0][0].uint,
            configId: configId,
            supply: config?.supply ?? 0,
            curveFeeBps: config?.curveFeeBps ?? 0,
            poolFeeBps: config?.poolFeeBps ?? 0,
            snipeSchedule: config?.snipeTaxSchedule ?? [],
            configEnabled: config?.enabled ?? false,
            maxCreatorTaxBps: LaunchpadABI.int(policy[2][0]),
            whitelistEnabled: policy[3][0].bool,
            protocolFeeShareBps: LaunchpadABI.int(policy[4][0][1]),
            launchCount: LaunchpadABI.int(policy[5][0]),
            pairs: pairEconomics
        )
    }

    /// The newest `limit` launches, newest first. Empty until the contracts are deployed.
    public func launches(limit: Int = 48) async throws -> [Launch] {
        guard addresses.isDeployed else { return [] }
        return try await launches(limit: limit, factory: addresses.factory)
    }

    /// Launches recorded by a specific factory — the live one or a retired one whose history still counts.
    public func launches(limit: Int = 48, factory: Address) async throws -> [Launch] {
        guard !factory.isZero, limit > 0 else { return [] }
        let total = LaunchpadABI.int(try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.launchCount, returns: "uint256")])[0][0])
        guard total > 0 else { return [] }
        let offset = max(0, total - limit)
        let page = try await multicall.readAll([LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunches, [.uint(offset), .uint(total - offset)], returns: "address[]")])[0][0].elements.map(\.address)
        guard !page.isEmpty else { return [] }
        let records = try await multicall.readAll(page.map { LaunchpadABI.call(factory, LaunchpadABI.Factory.getLaunchedToken, [.address($0)], returns: LaunchpadABI.launchedTokenTuple) })
            .map { LaunchpadABI.LaunchRecord($0[0]) }
        return try await hydrate(records).reversed()
    }

    /// One launch with its curve state, or nil when `token` was not launched here (or nothing is deployed).
    public func launch(token: Address) async throws -> LaunchDetail? {
        guard addresses.isDeployed else { return nil }
        let factory = addresses.factory
        typealias F = LaunchpadABI.Factory
        typealias C = LaunchpadABI.Curve
        let record = LaunchpadABI.LaunchRecord(try await multicall.readAll([LaunchpadABI.call(factory, F.getLaunchedToken, [.address(token)], returns: LaunchpadABI.launchedTokenTuple)])[0][0])
        guard record.exists, let info = try await hydrate([record]).first else { return nil }
        let curve = record.curve
        // Like the web app, "graduated" here includes refund mode: the pool key is reported for both.
        let graduated = record.phase.rawValue >= LaunchPhase.graduated.rawValue
        var calls: [ContractCall] = [
            LaunchpadABI.call(curve, C.feeBps, returns: "uint16"),
            LaunchpadABI.call(curve, C.snipeTaxSchedule, returns: "uint16[]"),
            LaunchpadABI.call(curve, C.getReserves, returns: "uint256,uint256"),
            LaunchpadABI.call(curve, C.sellableTokens, returns: "uint256"),
            LaunchpadABI.call(curve, C.phantomQuote, returns: "uint256"),
            LaunchpadABI.call(curve, C.reservedTokens, returns: "uint256"),
            LaunchpadABI.call(curve, C.swept, returns: "bool"),
            LaunchpadABI.call(factory, F.stuckSince, [.address(token)], returns: "uint256"),
            LaunchpadABI.call(factory, F.poolKeyOf, [.address(token)], returns: LaunchpadABI.poolKeyTuple),
        ]
        let readsHook = graduated && !addresses.hook.isZero
        if readsHook {
            calls.append(LaunchpadABI.call(addresses.hook, LaunchpadABI.Hook.pendingFees, [.bytes(record.poolId), .address(record.pairToken)], returns: "uint256"))
            calls.append(LaunchpadABI.call(addresses.hook, LaunchpadABI.Hook.pendingCreatorTax, [.bytes(record.poolId), .address(record.pairToken)], returns: "uint256"))
        }
        let readsQueue = info.holderFeeSharing && !addresses.holderFeeSharing.isZero
        if readsQueue {
            calls.append(LaunchpadABI.call(addresses.holderFeeSharing, LaunchpadABI.Sharing.queuedRewards, [.address(token)], returns: "uint256,uint256"))
        }
        let r = try await multicall.readAll(calls)
        return LaunchDetail(
            launch: info,
            feeBps: LaunchpadABI.int(r[0][0]),
            snipeSchedule: r[1][0].elements.map(LaunchpadABI.int),
            quoteReserve: r[2][0].uint,
            tokenReserve: r[2][1].uint,
            sellableTokens: r[3][0].uint,
            phantomQuote: r[4][0].uint,
            reservedTokens: r[5][0].uint,
            swept: r[6][0].bool,
            stuckSince: LaunchpadABI.int(r[7][0]),
            poolKey: graduated ? LaunchpadABI.poolKey(r[8][0]) : nil,
            hookPendingFees: readsHook ? r[9][0].uint : 0,
            hookPendingTax: readsHook ? r[10][0].uint : 0,
            queuedRewards: readsQueue ? r[readsHook ? 11 : 9][0].uint : 0
        )
    }

    /// Balances, allowance, snipe-tax status and claimables of `account` for one launch, in one round trip.
    public func accountView(_ launch: Launch, account: Address) async throws -> LaunchAccountView {
        let native = launch.pair.isNative
        var calls: [ContractCall] = [
            LaunchpadABI.call(launch.token, LaunchpadABI.Token.balanceOf, [.address(account)], returns: "uint256"),
            LaunchpadABI.call(launch.curve, LaunchpadABI.Curve.currentSnipeTaxBps, [.address(account)], returns: "uint256"),
            native
                ? LaunchpadABI.call(Multicall.address, LaunchpadABI.Multicall3.getEthBalance, [.address(account)], returns: "uint256")
                : LaunchpadABI.call(launch.pairToken, LaunchpadABI.Token.balanceOf, [.address(account)], returns: "uint256"),
        ]
        let readsAllowance = !native
        if readsAllowance { calls.append(LaunchpadABI.call(launch.pairToken, LaunchpadABI.Token.allowance, [.address(account), .address(launch.curve)], returns: "uint256")) }
        let readsRewards = launch.holderFeeSharing && !addresses.holderFeeSharing.isZero
        if readsRewards { calls.append(LaunchpadABI.call(addresses.holderFeeSharing, LaunchpadABI.Sharing.pendingRewards, [.address(launch.token), .address(account)], returns: "uint256")) }
        let readsEscrow = !addresses.escrow.isZero
        if readsEscrow {
            calls.append(native
                ? LaunchpadABI.call(addresses.escrow, LaunchpadABI.Escrow.balanceOf, [.address(account)], returns: "uint256")
                : LaunchpadABI.call(addresses.escrow, LaunchpadABI.Escrow.balanceOfToken, [.address(account), .address(launch.pairToken)], returns: "uint256"))
        }
        let r = try await multicall.readAll(calls)
        var index = 3
        func next() -> BigUInt {
            defer { index += 1 }
            return r[index][0].uint
        }
        let allowance = readsAllowance ? next() : 0
        let rewards = readsRewards ? next() : 0
        let escrow = readsEscrow ? next() : 0
        return LaunchAccountView(tokenBalance: r[0][0].uint, pairBalance: r[2][0].uint, allowance: allowance, snipeTaxBps: LaunchpadABI.int(r[1][0]), pendingRewards: rewards, escrowBalance: escrow)
    }

    /// `BondingCurve.quoteBuy`: previews a buy exactly as the contract would settle it for `recipient`
    /// (the snipe tax depends on who receives the tokens).
    public func quoteBuy(curve: Address, quoteIn: BigUInt, recipient: Address) async throws -> BuyQuote {
        let raw = try await rpc.ethCall(CallRequest(to: curve, data: LaunchpadABI.calldata(LaunchpadABI.Curve.quoteBuy, [.uint(quoteIn), .address(recipient)])))
        return LaunchpadABI.buyQuote(try ABI.decode(raw, "uint256,uint256,uint256,uint256,uint256,uint256"))
    }

    public func quoteSell(curve: Address, tokensIn: BigUInt) async throws -> SellQuote {
        let raw = try await rpc.ethCall(CallRequest(to: curve, data: LaunchpadABI.calldata(LaunchpadABI.Curve.quoteSell, [.uint(tokensIn)])))
        return LaunchpadABI.sellQuote(try ABI.decode(raw, "uint256,uint256,uint256"))
    }

    /// The terms hash a launch must carry (`LaunchInput.expectedEconomics`). Read it right before submitting.
    public func previewLaunchEconomics(configId: BigUInt, pairToken: Address) async throws -> Data {
        guard addresses.isDeployed else { throw LaunchpadError.notDeployed }
        let raw = try await rpc.ethCall(CallRequest(to: addresses.factory, data: LaunchpadABI.calldata(LaunchpadABI.Factory.previewLaunchEconomics, [.uint(configId), .address(pairToken)])))
        return try ABI.decode(raw, "bytes32")[0].bytes
    }

    /// Whether `account` may launch (true unless the whitelist is on and it is not listed).
    public func canLaunch(account: Address) async throws -> Bool {
        guard addresses.isDeployed else { return false }
        let raw = try await rpc.ethCall(CallRequest(to: addresses.factory, data: LaunchpadABI.calldata(LaunchpadABI.Factory.canLaunch, [.address(account)])))
        return try ABI.decode(raw, "bool")[0].bool
    }

    /// The token a launch transaction created, read from its `TokenLaunched` event. Nil while pending or when
    /// the transaction emitted no launch.
    public func launchResult(transaction hash: Data) async throws -> LaunchResult? {
        guard let logs = try await rpc.transactionLogs(hash) else { return nil }
        for log in logs where log.topics.first == LaunchpadABI.Events.launchedTopic && (addresses.factory.isZero || log.address == addresses.factory) {
            if let event = LaunchpadABI.launched(log) { return LaunchResult(token: event.token, curve: event.curve, deployer: event.deployer) }
        }
        return nil
    }

    // MARK: - Hydration

    /// Token metadata and live curve state for a page of records, in one multicall (plus one PoolManager read
    /// for graduated launches, and one metadata read for pair assets not seen before).
    private func hydrate(_ records: [LaunchpadABI.LaunchRecord]) async throws -> [Launch] {
        guard !records.isEmpty else { return [] }
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        let pairs = try await pairInfos(records.map(\.pairToken))
        var calls: [ContractCall] = []
        for r in records {
            calls += [
                LaunchpadABI.call(r.token, T.name, returns: "string"),
                LaunchpadABI.call(r.token, T.symbol, returns: "string"),
                LaunchpadABI.call(r.token, T.getTokenInfo, returns: "address,string,string,\(LaunchpadABI.socialsTuple)"),
                LaunchpadABI.call(r.curve, C.price, returns: "uint256"),
                LaunchpadABI.call(r.curve, C.realQuoteReserve, returns: "uint256"),
                LaunchpadABI.call(r.curve, C.completed, returns: "bool"),
                LaunchpadABI.call(r.curve, C.rescued, returns: "bool"),
                LaunchpadABI.call(r.curve, C.launchedAt, returns: "uint64"),
                LaunchpadABI.call(r.token, T.totalSupply, returns: "uint256"),
            ]
        }
        let stride = 9
        let results = try await multicall.readAll(calls)
        let livePrices = await poolPrices(for: records)
        return records.enumerated().map { i, r in
            let base = i * stride
            let info = LaunchpadABI.TokenInfo(results[base + 2])
            let curvePrice = results[base + 3][0].uint
            let realQuoteReserve = results[base + 4][0].uint
            let supply = results[base + 8][0].uint
            let graduated = r.phase == .graduated
            let price = livePrices[r.token] ?? curvePrice
            return Launch(
                token: r.token, curve: r.curve, deployer: r.deployer, creatorFeeRecipient: r.creatorFeeRecipient, pairToken: r.pairToken,
                graduationThreshold: r.graduationThreshold, creatorTaxBps: r.creatorTaxBps, poolFeeBps: r.poolFeeBps, tickSpacing: r.tickSpacing,
                holderFeeSharing: r.holderFeeSharing, graduationVenue: r.graduationVenue, phase: r.phase, sweptQuote: r.sweptQuote, sweptTokens: r.sweptTokens, sweptAt: r.sweptAt, poolId: r.poolId,
                name: results[base][0].string, symbol: results[base + 1][0].string, logo: info.logo, description: info.description, socials: info.socials,
                pair: pairs[r.pairToken] ?? .mon,
                price: price,
                realQuoteReserve: graduated ? r.sweptQuote : realQuoteReserve,
                completed: results[base + 5][0].bool,
                rescued: results[base + 6][0].bool,
                launchedAt: LaunchpadABI.int(results[base + 7][0]),
                supply: supply,
                marketCap: LaunchpadMath.marketCap(price: price, supply: supply),
                progressBps: LaunchpadMath.progressBps(phase: r.phase, realQuoteReserve: realQuoteReserve, sweptQuote: r.sweptQuote, threshold: r.graduationThreshold)
            )
        }
    }

    /// Live pool prices for graduated launches, keyed by token. Any failure leaves the curve's final price in place.
    private func poolPrices(for records: [LaunchpadABI.LaunchRecord]) async -> [Address: BigUInt] {
        guard !addresses.poolManager.isZero else { return [:] }
        let graduated = records.filter { $0.phase == .graduated }
        guard !graduated.isEmpty else { return [:] }
        let calls = graduated.map { LaunchpadABI.call(addresses.poolManager, LaunchpadABI.PoolManager.extsload, [.bytes(LaunchpadABI.slot0(of: $0.poolId))], returns: "bytes32") }
        guard let results = try? await multicall.read(calls) else { return [:] }
        var out: [Address: BigUInt] = [:]
        for (record, result) in zip(graduated, results) {
            guard case .success(let values) = result, let price = LaunchpadMath.poolPrice(slot0: values[0].bytes, token: record.token, pairToken: record.pairToken) else { continue }
            out[record.token] = price
        }
        return out
    }

    // MARK: - Transaction plans

    /// Approve the pair asset for the curve when it is an ERC-20, then `buy`. Native MON rides on `value`.
    public func buyPlan(launch: Launch, quoteIn: BigUInt, minTokensOut: BigUInt, recipient: Address) -> [TransactionStep] {
        var steps: [TransactionStep] = []
        if !launch.pair.isNative {
            steps.append(.approve(token: launch.pairToken, spender: launch.curve, amount: quoteIn, label: "Approve \(launch.pair.symbol)"))
        }
        let data = LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(quoteIn), .uint(minTokensOut), .address(recipient)])
        steps.append(.call(TransactionRequest(to: launch.curve, data: data, value: launch.pair.isNative ? quoteIn : 0), label: "Buy $\(launch.symbol)"))
        return steps
    }

    /// Approve the token for the curve, then `sell`.
    public func sellPlan(launch: Launch, tokensIn: BigUInt, minQuoteOut: BigUInt, recipient: Address) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Curve.sell, [.uint(tokensIn), .uint(minQuoteOut), .address(recipient)])
        return [
            .approve(token: launch.token, spender: launch.curve, amount: tokensIn, label: "Approve $\(launch.symbol)"),
            .call(TransactionRequest(to: launch.curve, data: data), label: "Sell $\(launch.symbol)"),
        ]
    }

    /// `launchToken` on the factory, or `launchAndBuy` on the router when `initialBuy` is set (approving the
    /// pair asset for the router first when it is an ERC-20). `launchFee` is paid in MON on top of a native
    /// developer buy. `from` receives the developer buy.
    public func launchPlan(_ input: LaunchInput, launchFee: BigUInt, from: Address) -> [TransactionStep] {
        let params = LaunchpadABI.tokenParams(input)
        let exemptions: ABIValue = .array(input.exemptions.map { .address($0) })
        let label = "Launch $\(input.symbol)"
        guard input.initialBuy > 0 else {
            let data = LaunchpadABI.calldata(LaunchpadABI.Factory.launchToken, [params, .uint(input.configId), .address(input.pairToken), exemptions])
            return [.call(TransactionRequest(to: addresses.factory, data: data, value: launchFee), label: label)]
        }
        var steps: [TransactionStep] = []
        if !input.pairIsNative {
            steps.append(.approve(token: input.pairToken, spender: addresses.router, amount: input.initialBuy, label: "Approve developer buy"))
        }
        let data = LaunchpadABI.calldata(LaunchpadABI.Router.launchAndBuy, [
            params, .uint(input.configId), .address(input.pairToken), .uint(input.initialBuy), .uint(input.minTokensOut), .address(from), exemptions,
        ])
        steps.append(.call(TransactionRequest(to: addresses.router, data: data, value: input.pairIsNative ? launchFee + input.initialBuy : launchFee), label: label))
        return steps
    }

    /// `launchPlan` with the launch fee and the economics hash read from the factory first, so the input only
    /// needs what the form collected.
    public func launchPlan(_ input: LaunchInput, from: Address) async throws -> [TransactionStep] {
        guard addresses.isDeployed else { throw LaunchpadError.notDeployed }
        async let fee = multicall.readAll([LaunchpadABI.call(addresses.factory, LaunchpadABI.Factory.launchFee, returns: "uint256")])
        async let economics = previewLaunchEconomics(configId: input.configId, pairToken: input.pairToken)
        var filled = input
        filled.expectedEconomics = try await economics
        return launchPlan(filled, launchFee: try await fee[0][0].uint, from: from)
    }

    /// `HolderFeeSharing.claim(token)`: the caller's share of the fees routed to holders. With a `view`, the
    /// creator-fee escrow claim is appended when it holds anything, and the holder claim is skipped when
    /// nothing is pending (each claim reverts with `NothingToClaim` otherwise).
    public func claimRewardsPlan(launch: Launch, view: LaunchAccountView? = nil) -> [TransactionStep] {
        var steps: [TransactionStep] = []
        if view == nil || (view?.pendingRewards ?? 0) > 0 {
            let data = LaunchpadABI.calldata(LaunchpadABI.Sharing.claim, [.address(launch.token)])
            steps.append(.call(TransactionRequest(to: addresses.holderFeeSharing, data: data), label: "Claim holder rewards"))
        }
        if let view, view.escrowBalance > 0 {
            steps += claimEscrowPlan(launch: launch)
        }
        return steps
    }

    /// `FeeEscrow.claim()` / `claimToken(pair)`: creator fees (and the protocol's) held in escrow for the caller.
    public func claimEscrowPlan(launch: Launch) -> [TransactionStep] {
        let data = launch.pair.isNative
            ? LaunchpadABI.calldata(LaunchpadABI.Escrow.claim)
            : LaunchpadABI.calldata(LaunchpadABI.Escrow.claimToken, [.address(launch.pairToken)])
        return [.call(TransactionRequest(to: addresses.escrow, data: data), label: "Claim creator fees")]
    }

    /// The caller's claimable fee-escrow balances — native MON plus each queried pair token. Creator fees (and, for
    /// the treasury address, protocol fees) accrue here per recipient across ALL of that wallet's launches, so this
    /// is the true "claimable creator fees" figure, keyed by pair asset rather than by coin.
    public func escrowBalances(account: Address, pairTokens: [Address]) async throws -> EscrowBalances {
        guard addresses.isDeployed, !addresses.escrow.isZero else { return EscrowBalances(native: 0, tokens: [:]) }
        let tokens = Array(Set(pairTokens.filter { !$0.isZero }))
        var calls: [ContractCall] = [LaunchpadABI.call(addresses.escrow, LaunchpadABI.Escrow.balanceOf, [.address(account)], returns: "uint256")]
        for token in tokens { calls.append(LaunchpadABI.call(addresses.escrow, LaunchpadABI.Escrow.balanceOfToken, [.address(account), .address(token)], returns: "uint256")) }
        let r = try await multicall.readAll(calls)
        var byToken: [Address: BigUInt] = [:]
        for (i, token) in tokens.enumerated() { byToken[token] = r[i + 1][0].uint }
        return EscrowBalances(native: r[0][0].uint, tokens: byToken)
    }

    /// Sweeps the caller's escrow: the native balance (when `native` is true) and each listed token, in one plan —
    /// so a creator withdraws their fees across every launch in a single confirmation.
    public func claimEscrowPlan(native: Bool, tokens: [Address]) -> [TransactionStep] {
        var steps: [TransactionStep] = []
        if native { steps.append(.call(TransactionRequest(to: addresses.escrow, data: LaunchpadABI.calldata(LaunchpadABI.Escrow.claim)), label: "Claim MON fees")) }
        for token in tokens where !token.isZero {
            steps.append(.call(TransactionRequest(to: addresses.escrow, data: LaunchpadABI.calldata(LaunchpadABI.Escrow.claimToken, [.address(token)])), label: "Claim fees"))
        }
        return steps
    }

    /// `LaunchpadFactory.graduate(token)`: retries a stuck migration. Anyone may call it.
    public func graduatePlan(launch: Launch) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Factory.graduate, [.address(launch.token)])
        return [.call(TransactionRequest(to: addresses.factory, data: data), label: "Graduate")]
    }

    /// `LaunchpadFactory.graduateFallback(token)`, the audit's rescue for a stuck Monday graduation: it retries the
    /// creator's venue first and, only if Monday still fails, graduates on Uniswap v4 right away (no rescue delay).
    /// Anyone may call it; a Monday-only quote asset needs the owner's `allowV4Fallback` first.
    public func graduateFallbackPlan(launch: Launch) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Factory.graduateFallback, [.address(launch.token)])
        return [.call(TransactionRequest(to: addresses.factory, data: data), label: "Graduate on Uniswap v4")]
    }

    /// `MemeHook.sweepPoolFees(poolId, currency)`: pays out the fees the hook collected for a graduated pool.
    public func sweepPoolFeesPlan(launch: Launch, currency: Address? = nil) -> [TransactionStep] {
        let data = LaunchpadABI.calldata(LaunchpadABI.Hook.sweepPoolFees, [.bytes(LaunchpadABI.word(launch.poolId)), .address(currency ?? launch.pairToken)])
        return [.call(TransactionRequest(to: addresses.hook, data: data), label: "Distribute pool fees")]
    }

    // MARK: - Display helpers

    /// Price in pair units per whole token, for display.
    public nonisolated static func priceNumber(_ launch: Launch) -> Double {
        Amount.units(launch.price, decimals: launch.pair.decimals)
    }
}

/// What a launch transaction created, from its `TokenLaunched` event.
public struct LaunchResult: Hashable, Sendable {
    public let token: Address
    public let curve: Address
    public let deployer: Address

    public init(token: Address, curve: Address, deployer: Address) {
        self.token = token
        self.curve = curve
        self.deployer = deployer
    }
}

public extension LaunchpadMath {
    /// `price × supply / 1e18`: market cap in quote wei.
    static func marketCap(price: BigUInt, supply: BigUInt) -> BigUInt {
        price * supply / BigUInt(10).power(18)
    }

    /// Progress to graduation in basis points: 10 000 once graduated, else raised / threshold with the raise
    /// capped at the threshold.
    static func progressBps(phase: LaunchPhase, realQuoteReserve: BigUInt, sweptQuote: BigUInt, threshold: BigUInt) -> Int {
        if phase == .graduated { return 10_000 }
        if threshold == 0 { return 0 }
        let raised = realQuoteReserve > threshold ? threshold : realQuoteReserve
        return Int(clamping: raised * bps / threshold)
    }

    /// Converts a PoolManager slot0 word into quote wei per 1e18 token wei, the scale `BondingCurve.price`
    /// uses, so graduated launches keep the same price field. Nil when the pool is uninitialised.
    static func poolPrice(slot0 value: Data, token: Address, pairToken: Address) -> BigUInt? {
        let sqrtPriceX96 = BigUInt(value) & ((BigUInt(1) << 160) - 1)
        if sqrtPriceX96 == 0 { return nil }
        let e36 = BigUInt(10).power(36)
        let tokenDecimals = BigUInt(10).power(18)
        // price1Per0 = (sqrtPriceX96 / 2^96)^2, scaled by 1e36 for precision.
        let price1Per0E36 = (sqrtPriceX96 * sqrtPriceX96 * e36) >> 192
        let tokenIsCurrency0 = BigUInt(token.data) < BigUInt(pairToken.data)
        if tokenIsCurrency0 { return price1Per0E36 * tokenDecimals / e36 } // currency1 is the quote
        if price1Per0E36 == 0 { return nil }
        return e36 * tokenDecimals / price1Per0E36 // currency1 is the token, so quote per token = 1 / price
    }
}
