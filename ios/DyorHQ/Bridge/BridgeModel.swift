import BigInt
import DyorKit
import Foundation
import Observation

/// Drives the cross-chain Bridge: the same DyorHQ wallet address moves funds between an EVM source chain and Monad
/// (either direction) via Aurora Intents. The app quotes, signs the deposit on the source chain itself, tells Aurora,
/// then polls until the funds land. Exactly one side is always Monad.
@Observable
@MainActor
final class BridgeModel {
    private let env: AppEnvironment

    private(set) var tokens: [AuroraToken] = []
    private(set) var loadingTokens = false
    private(set) var loadError: String?

    var fromChain: EVMChain
    var toChain: EVMChain
    var fromToken: AuroraToken?
    var toToken: AuroraToken?
    var amountText = ""

    /// Wallet balances keyed by Aurora `assetId` (globally unique across chains), covering every supported source
    /// chain — so the source picker can rank assets by what the user actually holds, on any chain.
    private(set) var balances: [String: BigUInt] = [:]
    private(set) var loadingBalances = false
    private var didLoadBalances = false

    private(set) var quote: AuroraQuote?
    private(set) var quoting = false
    private(set) var quoteError: String?
    private var quoteTask: Task<Void, Never>?

    enum Phase: Equatable { case idle, signing, submitting, bridging(AuroraSwapStatus), done(String), settling(String), failed(String) }
    private(set) var phase: Phase = .idle
    /// Invalidates a running poll when the user starts over, so a stale poll can't overwrite a fresh state.
    private var pollGeneration = 0
    // The bridge in flight, captured at signing time for the completion record + notification — so a record always
    // describes the bridge that was actually sent, even if the form is somehow changed while a poll is still running.
    private var pendingHash: String?
    private var pendingUsd: Double?
    private var pendingInSymbol: String?
    private var pendingOutSymbol: String?
    private var pendingFromName: String?
    private var pendingToName: String?
    private var pendingAmountText: String?
    // For confirming arrival by the destination balance itself — intent bridges often credit the funds before Aurora's
    // status indexer reports SUCCESS, so the poll also watches the destination token's balance climb past its baseline.
    private var pendingToToken: AuroraToken?
    private var pendingDestChain: EVMChain?
    private var pendingDestBaseline: BigUInt?
    private var pendingMinOut: BigUInt?
    /// The block-explorer URL the "View" link opens on a completed bridge — the source deposit tx as soon as it's
    /// signed, upgraded to the destination arrival tx once Aurora reports it, so the user can verify it on-chain.
    private(set) var completedTxURL: URL?

    init(env: AppEnvironment) {
        self.env = env
        // Default: bring funds in from a common L2 into Monad. Both sides are the same 0x address.
        fromChain = EVMChain.byAuroraId("base") ?? EVMChain.supported[0]
        toChain = env.bridgeMonad
    }

    var isConfigured: Bool { env.aurora.isConfigured }
    var monad: EVMChain { env.bridgeMonad }
    /// The chain the user chooses; the other side is pinned to Monad.
    var otherChain: EVMChain { fromChain.isMonad ? toChain : fromChain }
    var intoMonad: Bool { toChain.isMonad }
    /// EVM source chains other than Monad, in registry order.
    var selectableChains: [EVMChain] { EVMChain.supported.filter { !$0.isMonad } }

    func tokens(on chain: EVMChain) -> [AuroraToken] {
        tokens.filter { $0.blockchain == chain.auroraId }.sorted { stableRank($0) < stableRank($1) }
    }
    private func stableRank(_ t: AuroraToken) -> Int { ["USDC": 0, "USDT0": 1, "USDT": 2].first { $0.key == t.symbol }?.value ?? 3 }

    /// Every source-side asset (all supported chains except Monad), richest first: assets the user holds float to the
    /// top ordered by USD value, then the rest by a stable-first, alphabetical order. This is what the cross-chain
    /// source picker shows, so "100 USDT on Arbitrum" is the first thing the user sees.
    var sourceAssets: [AuroraToken] {
        tokens
            .filter { (EVMChain.byAuroraId($0.blockchain).map { !$0.isMonad }) ?? false }
            .sorted { a, b in
                let ha = held(a), hb = held(b)
                if ha != hb { return ha }                 // any holding ranks above no holding
                let va = balanceUSD(a), vb = balanceUSD(b)
                if va != vb { return va > vb }             // among holdings, richest by USD first
                let ra = stableRank(a), rb = stableRank(b)
                if ra != rb { return ra < rb }             // then the familiar stables
                if a.symbol != b.symbol { return a.symbol < b.symbol }
                return a.blockchain < b.blockchain
            }
    }

    // MARK: Loading

    /// The bridge's backend proxy serves a signed-in wallet only. RootView signs in as soon as the wallet can sign;
    /// this covers the moment right after launch before that sign-in has landed. Opening the screen is no tap for a
    /// signature, so it signs in only where that shows nothing (`Session.backgroundWallet`): a passkey account whose
    /// session is locked waits for `needsUnlock`'s button instead of a passkey prompt out of nowhere.
    private func ensureBackendSession() async {
        guard !env.social.isSignedIn, env.session.canSignWithoutPrompt,
              let address = env.session.address, let wallet = env.session.backgroundWallet else { return }
        await env.social.signIn(address: address, wallet: wallet)
    }

    /// A passkey account with no backend session and its passkey session locked: routes can't load until it unlocks.
    /// Once it does, RootView signs in to the backend and the view loads again.
    var needsUnlock: Bool { env.session.isPasskeyAccount && !env.session.canSignWithoutPrompt && !env.social.isSignedIn }

    /// Counts `load` calls: the view reloads when the account unlocks or its backend sign-in lands, and an earlier load
    /// may still be waiting on that sign-in (its task cancelled, which a joined sign-in doesn't notice). Only the newest
    /// writes, so a superseded one can't leave its "Cancelled." over a form that loaded.
    private var loadGeneration = 0

    func load() async {
        guard isConfigured else { loadError = AuroraError.notConfigured.errorDescription; return }
        guard tokens.isEmpty, !needsUnlock else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadingTokens = true
        defer { if generation == loadGeneration { loadingTokens = false } }
        loadError = nil
        await ensureBackendSession()
        do {
            let loaded = try await env.aurora.tokens().filter { EVMChain.byAuroraId($0.blockchain) != nil }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            tokens = loaded
            loadError = nil
            if fromToken == nil { fromToken = preferred(on: fromChain) }
            if toToken == nil { toToken = preferred(on: toChain) }
            await loadBalances()
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadError = describe(error)
        }
    }

    private func preferred(on chain: EVMChain) -> AuroraToken? {
        let list = tokens(on: chain)
        return list.first { $0.symbol == "USDC" } ?? list.first
    }

    // MARK: Selection

    /// Sets the non-Monad chain (Monad stays pinned to the other side) and resets its token + amount.
    func selectOtherChain(_ chain: EVMChain) {
        if intoMonad { fromChain = chain; fromToken = preferred(on: chain) }
        else { toChain = chain; toToken = preferred(on: chain) }
        resetQuote(); Task { await loadBalances() }
    }

    func flipDirection() {
        swap(&fromChain, &toChain)
        swap(&fromToken, &toToken)
        amountText = ""; resetQuote()
        Task { await loadBalances() }
    }

    func setFromToken(_ token: AuroraToken) { fromToken = token; resetQuote(); refreshQuoteSoon() }
    func setToToken(_ token: AuroraToken) { toToken = token; resetQuote(); refreshQuoteSoon() }

    /// Pick a source asset from the cross-chain list: this also switches the source chain to wherever the asset lives
    /// (choosing "USDT on Arbitrum" makes Arbitrum the source), keeping Monad pinned as the destination.
    func selectSourceAsset(_ token: AuroraToken) {
        guard let chain = EVMChain.byAuroraId(token.blockchain), !chain.isMonad else { return }
        fromChain = chain
        fromToken = token
        toChain = monad
        if toToken == nil || toToken?.blockchain != monad.auroraId { toToken = preferred(on: monad) }
        resetQuote(); refreshQuoteSoon()
    }

    // MARK: Balances

    /// Reads the wallet's balances across every supported chain at once (each chain independently, failures swallowed),
    /// so the source picker can rank by holdings. Runs once; pass `force` after a bridge lands to pick up the change.
    func loadBalances(force: Bool = false) async {
        guard let owner = env.session.address else { return }
        if didLoadBalances && !force { return }
        guard !loadingBalances else { return } // coalesce overlapping loads (first `load()` + a picker `.task`, etc.)
        loadingBalances = true; defer { loadingBalances = false }

        let balancer = env.chainBalances
        // Use the app's configured Monad endpoint for the Monad side; public RPCs for the rest.
        let plan: [(EVMChain, [AuroraToken])] = EVMChain.supported
            .map { $0.isMonad ? env.bridgeMonad : $0 }
            .compactMap { chain in
                let toks = tokens(on: chain)
                return toks.isEmpty ? nil : (chain, toks)
            }

        let merged = await withTaskGroup(of: [String: BigUInt].self) { group in
            for (chain, toks) in plan {
                group.addTask { await balancer.balances(owner: owner, chain: chain, tokens: toks) }
            }
            var acc: [String: BigUInt] = [:]
            for await part in group { acc.merge(part) { current, _ in current } }
            return acc
        }
        balances = merged
        // Don't latch on a total-failure empty result (every public RPC down): leave it un-latched so opening the
        // picker or switching chains retries, instead of showing an empty list for the rest of the session.
        didLoadBalances = !merged.isEmpty
    }

    // Per-asset balance access for the pickers (keyed by the globally-unique assetId).
    func held(_ token: AuroraToken) -> Bool { (balances[token.assetId] ?? 0) > 0 }
    func balanceRaw(_ token: AuroraToken) -> BigUInt? { balances[token.assetId] }
    /// The USD value of the held balance (0 when nothing held or no price), used only to rank the picker.
    func balanceUSD(_ token: AuroraToken) -> Double {
        guard let raw = balances[token.assetId], raw > 0, let price = token.price, price > 0 else { return 0 }
        let units = (Double(raw.description) ?? 0) / pow(10, Double(token.decimals))
        return units * price
    }
    /// A compact "0.097 USDC" for a picker row; nil when the wallet holds none of it.
    func balanceText(_ token: AuroraToken) -> String? {
        guard let raw = balances[token.assetId], raw > 0 else { return nil }
        return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
    }

    var fromBalanceRaw: BigUInt? { fromToken.flatMap { balances[$0.assetId] } }
    var fromBalanceText: String? {
        guard let token = fromToken, let raw = fromBalanceRaw else { return nil }
        return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
    }

    func useMax() { usePercent(1) }

    /// Fill the amount with a fraction of the from-chain balance. "Max" of a token is the EXACT balance, never above
    /// it nor silently under; a Max of the chain's native coin keeps its network fee back. A share below 100% is rounded
    /// down to six significant digits (`Amount.roundedDown`), so the field reads "0.559465" rather than 18 decimals.
    func usePercent(_ fraction: Double) {
        guard let token = fromToken, let raw = fromBalanceRaw, raw > 0 else { return }
        if fraction >= 1, token.isNative {
            Task { await useNativeMax(token, balance: raw) }
            return
        }
        let amount = fraction >= 1 ? raw : Amount.roundedDown(raw * BigUInt(Int((fraction * 10000).rounded())) / 10000, decimals: token.decimals)
        setAmount(amount, of: token)
    }

    /// Max of a native coin (MERA-PLAN §5): the balance less what the deposit transfer can be charged on the source
    /// chain — its gas estimate (to the quote's deposit address, or a stand-in until Aurora names one) × (2 × base fee
    /// + tip) with headroom, or the chain's fallback when its RPC can't answer. Zero when the fee takes it all.
    private func useNativeMax(_ token: AuroraToken, balance: BigUInt) async {
        let chain = fromChain
        let recipient = quote?.depositAddress.flatMap { Address($0) } ?? Self.feeProbeRecipient
        let amount = await env.sender(for: chain).maxValue(balance: balance, like: TransactionRequest(to: recipient, value: 1),
                                                           from: env.session.address, budget: NetworkFeeReserve.transferGasLimit)
        // The source, its balance or the form changed while the fee was read: that Max no longer applies.
        guard canEdit, fromChain == chain, fromToken?.assetId == token.assetId, fromBalanceRaw == balance else { return }
        // Rounded down: a sliver more stays back with the fee reserve, and the field stays readable.
        setAmount(Amount.roundedDown(amount, decimals: token.decimals), of: token)
    }

    /// An address with no code, to estimate a plain transfer before there is a deposit address.
    private static let feeProbeRecipient = Address(literal: "0x000000000000000000000000000000000000dEaD")

    private func setAmount(_ amount: BigUInt, of token: AuroraToken) {
        amountText = Amount.exact(amount, decimals: token.decimals)
        resetQuote()
        refreshQuoteSoon()
    }

    // MARK: Quote

    var amountRaw: BigUInt? {
        guard let token = fromToken, let raw = Amount.parse(amountText, decimals: token.decimals), raw > 0 else { return nil }
        return raw
    }

    /// The user's balance can't cover the amount they typed.
    var insufficient: Bool {
        guard let amount = amountRaw, let balance = fromBalanceRaw else { return false }
        return amount > balance
    }

    func amountChanged() { resetQuote(); refreshQuoteSoon() }

    private func refreshQuoteSoon() {
        quoteTask?.cancel()
        guard amountRaw != nil else { return }
        quoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.getQuote()
        }
    }

    func getQuote() async {
        guard let from = fromToken, let to = toToken, let owner = env.session.address, let amount = amountRaw else { return }
        quoting = true; quoteError = nil; defer { quoting = false }
        await ensureBackendSession()
        do {
            quote = try await env.aurora.quote(
                amount: String(amount), originAsset: from.assetId, destinationAsset: to.assetId,
                recipient: owner.checksummed, refundTo: owner.checksummed, slippageBps: slippageBps)
        } catch {
            quote = nil
            quoteError = humanize(describe(error))
        }
    }

    private func resetQuote() { quoteTask?.cancel(); quote = nil; quoteError = nil }

    /// Aurora returns some validation errors with raw smallest-unit amounts (e.g. "…try at least 150000"). Reformat
    /// any standalone large integer in an amount error into human units of the source token, so the user reads
    /// "0.15 USDC" instead of "150000".
    private func humanize(_ message: String) -> String {
        guard let token = fromToken,
              message.lowercased().contains("at least") || message.lowercased().contains("too low"),
              let regex = try? NSRegularExpression(pattern: #"\b\d{4,}\b"#) else { return message }
        let ns = message as NSString
        var result = message
        for match in regex.matches(in: message, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let value = BigUInt(ns.substring(with: match.range)) else { continue }
            let human = "\(NumberStyle.units(value, decimals: token.decimals)) \(token.symbol)"
            result = (result as NSString).replacingCharacters(in: match.range, with: human)
        }
        return result
    }

    var expectedOut: String? {
        guard let out = quote?.amountOutFormatted, let to = toToken else { return nil }
        return "\(out) \(to.symbol)"
    }

    /// Max slippage the app requests on every quote (basis points), user-adjustable via the slippage sheet. 1% is a
    /// safe default for cross-chain settlement. Changing it re-quotes, so the minimum-received and fee update at once.
    var slippageBps = 100 {
        didSet { guard slippageBps != oldValue else { return }; resetQuote(); refreshQuoteSoon() }
    }
    var slippageText: String { NumberStyle.basisPoints(slippageBps) }

    /// Total cost of the bridge (USD): input value minus output value — covers Aurora's protocol + withdraw fee, the
    /// route spread and the integrator fee, i.e. the one number a user needs to trust the flow.
    var feeText: String? {
        guard let q = quote, let inUsd = q.amountInUsd.flatMap(Double.init), let outUsd = q.amountOutUsd.flatMap(Double.init), inUsd > 0 else { return nil }
        let fee = max(0, inUsd - outUsd)
        let pct = fee / inUsd * 100
        let amount = fee < 0.01 ? "$\(NumberStyle.number(fee, maximumFractionDigits: 6))" : fee.formatted(.currency(code: "USD"))
        return "\(amount) · \(NumberStyle.number(pct, maximumFractionDigits: 2))%"
    }

    /// The guaranteed minimum the user receives after slippage (from the quote's `minAmountOut`).
    var minReceivedText: String? {
        guard let min = quote?.minAmountOut, let raw = BigUInt(min), let to = toToken else { return nil }
        return "\(NumberStyle.units(raw, decimals: to.decimals)) \(to.symbol)"
    }

    // MARK: Execute

    var isBusy: Bool {
        switch phase {
        case .signing, .submitting, .bridging: return true
        case .idle, .done, .settling, .failed: return false
        }
    }
    /// Only offer to bridge from a clean `.idle` state — once a deposit has been signed (`.done`/`.failed` from the
    /// poll path, `.signing`/`.submitting`/`.bridging` in flight) the primary button becomes "start over" (which
    /// resets and re-quotes), so the same real deposit can never be signed and sent twice.
    var canBridge: Bool {
        guard case .idle = phase else { return false }
        return fromToken != nil && toToken != nil && amountRaw != nil && !insufficient && quote?.depositAddress != nil
    }
    /// The form (chain/token/amount) is only editable from a clean `.idle` state. Once a deposit is signed — through the
    /// in-flight phases and the terminal `.done`/`.settling`/`.failed` (where a background poll may still be running) —
    /// the user must tap the primary to `reset()` first, so nothing can change the route while a bridge is settling.
    var canEdit: Bool { if case .idle = phase { return true }; return false }

    func execute() async {
        // A passkey account's bridge always asks (MERA-PLAN §3): one Face ID when the deposit is signed.
        guard let wallet = env.session.wallet(for: MeraSession.Action(.alwaysAsks(.bridge))) else { phase = .failed("Sign in to bridge."); return }
        guard let from = fromToken, let amount = amountRaw, let quote, let deposit = quote.depositAddress, let depositAddr = Address(deposit) else {
            phase = .failed("Get a quote first."); return
        }
        if env.settings.appLockApplies(to: env.session.account), !(await BiometricGate.authenticate(reason: "Confirm bridge")) { return }
        phase = .signing
        completedTxURL = nil
        // The quote is EXACT_INPUT for the amount the user typed, delivered back to the user's own address. Refuse to
        // sign anything else — a quote whose input amount, recipient or refund address differs from the request. This
        // catches a buggy or mismatched quote; it cannot prove the deposit address is Aurora's, because the request
        // echo arrives in the same response as that address: the address is trusted to Aurora and the aurora-proxy
        // Edge Function, and the review card shows it before the user confirms (security audit 2026-09-26, IOST-3).
        guard let quotedIn = BigUInt(quote.amountIn), quotedIn == amount else {
            phase = .failed("The bridge quote didn't match the amount you entered, so nothing was sent. Get a new quote.")
            return
        }
        guard let owner = env.session.address, let to = toToken,
              quote.request?.matches(amount: amount, originAsset: from.assetId, destinationAsset: to.assetId, owner: owner) == true else {
            phase = .failed("The bridge quote didn't match your request (amount, tokens or your address), so nothing was sent. Get a new quote.")
            return
        }
        let sendAmount = quotedIn
        do {
            let request: TransactionRequest
            if from.isNative {
                request = TransactionRequest(to: depositAddr, value: sendAmount)
            } else if let contract = from.contractAddress.flatMap(Address.init) {
                request = TransactionRequest(to: contract, data: try ERC20.transferCalldata(to: depositAddr, amount: sendAmount))
            } else { phase = .failed("This source token can't be bridged."); return }

            pendingHash = nil
            pendingUsd = quote.amountOutUsd.flatMap(Double.init) ?? quote.amountInUsd.flatMap(Double.init)
            pendingInSymbol = from.symbol
            pendingOutSymbol = toToken?.symbol
            pendingFromName = fromChain.name
            pendingToName = toChain.name
            pendingAmountText = amountText
            // Snapshot the destination balance now, before any credit, so the poll can confirm the arrival on-chain even
            // if Aurora's status lags. Uses the balance already loaded for the picker — no extra call on the send path.
            pendingToToken = toToken
            pendingDestChain = toChain
            pendingMinOut = quote.minAmountOut.flatMap { BigUInt($0) }
            pendingDestBaseline = toToken.flatMap { balances[$0.assetId] } ?? 0
            let hash = try await env.sender(for: fromChain).send(request, from: wallet)
            pendingHash = hash.hexString
            completedTxURL = fromChain.explorerTx(hash.hexString) // source deposit tx — a verifiable link straight away
            phase = .submitting
            _ = try? await env.aurora.submitDeposit(txHash: hash.hexString, depositAddress: deposit, memo: quote.depositMemo)
            // Bridge fee (USD) = the value the route consumed: input value − output value, when the quote priced both.
            let bridgeFeeUsd: Double? = {
                guard let inUsd = quote.amountInUsd.flatMap(Double.init), let outUsd = quote.amountOutUsd.flatMap(Double.init) else { return nil }
                return max(0, inUsd - outUsd)
            }()
            ActivityLog.record(ActivityRecord(
                kind: .bridge, title: "Bridge \(from.symbol) → \(toToken?.symbol ?? "")",
                subtitle: "\(amountText) \(from.symbol) · \(fromChain.name) → \(toChain.name)",
                hash: hash, section: "bridge", usd: pendingUsd, feeUsd: bridgeFeeUsd), owner: env.session.address)
            pollGeneration += 1
            await poll(deposit: deposit, memo: quote.depositMemo, generation: pollGeneration)
        } catch where env.session.isPasskeyAccount && isUserCancellation(error) {
            phase = .failed(TransactionRun.notSent)
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func poll(deposit: String, memo: String?, generation: Int) async {
        var consecutiveFailures = 0
        for _ in 0..<150 {
            guard generation == pollGeneration else { return } // the user started over — stop touching phase
            do {
                let state = try await env.aurora.status(depositAddress: deposit, depositMemo: memo)
                guard generation == pollGeneration else { return } // the user started over while this was in flight
                consecutiveFailures = 0
                // Once Aurora surfaces the destination-chain settlement tx, upgrade the "View" link from the source
                // deposit to the arrival tx — that's the on-chain proof the funds actually landed.
                if let ref = state.swapDetails?.destinationChainTxHashes?.last {
                    completedTxURL = ref.explorerUrl.flatMap(URL.init(string:)) ?? pendingDestChain?.explorerTx(ref.hash) ?? completedTxURL
                }
                switch state.status {
                case .success:
                    let out = state.swapDetails?.amountOutFormatted.map { "\($0) \(pendingOutSymbol ?? toToken?.symbol ?? "")" } ?? expectedOut ?? ""
                    recordCompletion(usd: state.swapDetails?.amountOutUsd.flatMap(Double.init))
                    resetQuote() // the deposit address is consumed — a new bridge must re-quote
                    phase = .done(out)
                    Task { await loadBalances(force: true) } // balances changed — refresh across chains
                    return
                case .refunded:
                    resetQuote()
                    // Correct the optimistic source-send row (same hash → replaces it) and tell the user, so the feed
                    // and notifications never leave a failed bridge looking like it succeeded.
                    correctBridge(title: "Bridge refunded", detail: "\(pendingInSymbol ?? "Funds") returned on \(fromChain.name)")
                    phase = .failed("Bridge refunded — \(state.swapDetails?.refundReason ?? "the swap couldn't complete"). Your funds were returned on \(fromChain.name).")
                    return
                case .failed:
                    resetQuote()
                    correctBridge(title: "Bridge failed", detail: state.swapDetails?.refundReason ?? "The bridge could not complete on \(toChain.name)")
                    phase = .failed(state.swapDetails?.refundReason ?? "The bridge failed.")
                    return
                default:
                    // Aurora still says "in progress", but the funds may already be on the destination — confirm by the
                    // balance itself so the screen doesn't spin forever after the credit has actually landed.
                    if await finishIfCredited(generation: generation) { return }
                    phase = .bridging(state.status)
                }
            } catch {
                guard generation == pollGeneration else { return } // started over during the failed request
                // Aurora's status read failed, but the credit may still have landed — check the balance before deciding.
                if await finishIfCredited(generation: generation) { return }
                // Don't stall silently: after several straight failures, tell the user it's still settling (and it's
                // recorded in Activity) rather than spinning forever on a status we can't read.
                consecutiveFailures += 1
                if consecutiveFailures >= 4 {
                    phase = .settling("Still settling — this can take a minute. It'll appear in your balance and Activity once it lands.")
                }
            }
            try? await Task.sleep(for: .seconds(4))
        }
        guard generation == pollGeneration else { return }
        // Past the polling window and still not terminal: the deposit is on its way; hand it off to Activity/balances.
        phase = .settling("Taking longer than usual — your funds are on their way. This will show in your balance and Activity when it lands.")
    }

    /// If the destination token's balance has climbed past its pre-bridge baseline by (about) the promised minimum, the
    /// funds have landed — finish the bridge even when Aurora's status indexer hasn't caught up yet. Returns whether it
    /// finished, so the caller stops polling.
    private func finishIfCredited(generation: Int) async -> Bool {
        guard let owner = env.session.address, let token = pendingToToken, let chain = pendingDestChain,
              let baseline = pendingDestBaseline, let minOut = pendingMinOut, minOut > 0 else { return false }
        let bals = await env.chainBalances.balances(owner: owner, chain: chain, tokens: [token])
        guard generation == pollGeneration else { return false } // the user started over while this read was in flight
        guard let now = bals[token.assetId], now > baseline else { return false }
        let credited = now - baseline
        // Require (about) the guaranteed minimum output to have arrived — a small tolerance for rounding, but enough
        // that unrelated dust can never trip a false "arrived".
        guard credited * 100 >= minOut * 95 else { return false }
        recordCompletion(usd: pendingUsd)
        resetQuote()
        phase = .done("\(NumberStyle.units(credited, decimals: token.decimals)) \(token.symbol)")
        Task { await loadBalances(force: true) }
        return true
    }

    /// Persist a completed bridge (for Portfolio volume) and post the completion notification. Idempotent per tx hash.
    /// Uses the route/amount captured at signing time, never the live form, so the record can't be corrupted by a
    /// later selection.
    private func recordCompletion(usd: Double?) {
        let value = usd ?? pendingUsd ?? 0
        let from = pendingFromName ?? fromChain.name
        let to = pendingToName ?? toChain.name
        if let hash = pendingHash {
            BridgeStore.record(BridgeRecord(id: hash, usd: value, fromChain: from, toChain: to,
                                            inSymbol: pendingInSymbol ?? "", outSymbol: pendingOutSymbol ?? "", time: Date()),
                               owner: env.session.address)
        }
        Notifications.bridge(amount: "\(pendingAmountText ?? amountText) \(pendingInSymbol ?? "")", from: from, to: to)
    }

    /// Replaces the optimistic source-send activity row (matched by the same source-tx hash) with a terminal-failure
    /// row and notifies — so a refunded or failed bridge is corrected in Recent Activity, the backend mirror, and
    /// platform volume (usd cleared) instead of lingering as a success.
    private func correctBridge(title: String, detail: String) {
        let hash = pendingHash.flatMap { Data(hex: $0) }
        Activity.record(ActivityRecord(kind: .bridge, title: title, subtitle: detail, hash: hash, section: "bridge"), owner: env.session.address)
    }

    /// Return to a clean state to start another bridge, keeping the entered amount and re-quoting it (so a
    /// pre-broadcast failure like "no gas" can be retried without retyping).
    func reset() {
        pollGeneration += 1 // stop any poll still running from the previous bridge
        phase = .idle
        completedTxURL = nil
        resetQuote()
        if amountRaw != nil { refreshQuoteSoon() }
    }
}

extension AuroraSwapStatus {
    /// A short user-facing label for the settlement stage.
    var label: String {
        switch self {
        case .pendingDeposit, .knownDepositTx: return "Confirming your deposit…"
        case .incompleteDeposit: return "Waiting for the full deposit…"
        case .processing: return "Bridging across chains…"
        case .success: return "Arrived"
        case .refunded: return "Refunded"
        case .failed: return "Failed"
        }
    }
}
