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

    private(set) var balances: [String: BigUInt] = [:]
    private(set) var loadingBalances = false

    private(set) var quote: AuroraQuote?
    private(set) var quoting = false
    private(set) var quoteError: String?
    private var quoteTask: Task<Void, Never>?

    enum Phase: Equatable { case idle, signing, submitting, bridging(AuroraSwapStatus), done(String), settling(String), failed(String) }
    private(set) var phase: Phase = .idle
    /// Invalidates a running poll when the user starts over, so a stale poll can't overwrite a fresh state.
    private var pollGeneration = 0
    // The bridge in flight, captured at signing time for the completion record + notification.
    private var pendingHash: String?
    private var pendingUsd: Double?
    private var pendingInSymbol: String?

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

    // MARK: Loading

    func load() async {
        guard isConfigured else { loadError = AuroraError.notConfigured.errorDescription; return }
        guard tokens.isEmpty else { return }
        loadingTokens = true; defer { loadingTokens = false }
        do {
            tokens = try await env.aurora.tokens().filter { EVMChain.byAuroraId($0.blockchain) != nil }
            if fromToken == nil { fromToken = preferred(on: fromChain) }
            if toToken == nil { toToken = preferred(on: toChain) }
            await loadBalances()
        } catch { loadError = describe(error) }
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

    // MARK: Balances

    func loadBalances() async {
        guard let owner = env.session.address else { return }
        loadingBalances = true; defer { loadingBalances = false }
        balances = await env.chainBalances.balances(owner: owner, chain: fromChain, tokens: tokens(on: fromChain))
    }

    var fromBalanceRaw: BigUInt? { fromToken.flatMap { balances[$0.assetId] } }
    var fromBalanceText: String? {
        guard let token = fromToken, let raw = fromBalanceRaw else { return nil }
        return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
    }

    func useMax() { usePercent(1) }

    /// Fill the amount with a fraction of the from-chain balance, in EXACT units (not a display-rounded string) so
    /// "Max" is never above balance nor silently under.
    func usePercent(_ fraction: Double) {
        guard let token = fromToken, let raw = fromBalanceRaw, raw > 0 else { return }
        let amount = fraction >= 1 ? raw : raw * BigUInt(Int((fraction * 10000).rounded())) / 10000
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

    /// Slippage the app requests on every quote (basis points). 1% is a safe default for cross-chain settlement.
    let slippageBps = 100
    var slippageText: String { "\(NumberStyle.number(Double(slippageBps) / 100, maximumFractionDigits: 2))%" }

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

    func execute() async {
        guard let wallet = env.session.wallet else { phase = .failed("Sign in to bridge."); return }
        guard let from = fromToken, let amount = amountRaw, let quote, let deposit = quote.depositAddress, let depositAddr = Address(deposit) else {
            phase = .failed("Get a quote first."); return
        }
        if env.settings.requireBiometrics, !(await BiometricGate.authenticate(reason: "Confirm bridge")) { return }
        phase = .signing
        // Send EXACTLY what Aurora quoted (`amountIn`) to the deposit address — never a re-parsed value — so the
        // deposit always matches the quote. `amount` is only the fallback if the quote didn't echo a parsable amountIn.
        let sendAmount = BigUInt(quote.amountIn) ?? amount
        do {
            let request: TransactionRequest
            if from.isNative {
                request = TransactionRequest(to: depositAddr, value: sendAmount)
            } else if let contract = from.contractAddress.flatMap(Address.init) {
                request = TransactionRequest(to: contract, data: try ERC20.transferCalldata(to: depositAddr, amount: sendAmount))
            } else { phase = .failed("This source token can't be bridged."); return }

            pendingHash = nil; pendingUsd = quote.amountOutUsd.flatMap(Double.init) ?? quote.amountInUsd.flatMap(Double.init); pendingInSymbol = from.symbol
            let hash = try await env.sender(for: fromChain).send(request, from: wallet)
            pendingHash = hash.hexString
            phase = .submitting
            _ = try? await env.aurora.submitDeposit(txHash: hash.hexString, depositAddress: deposit, memo: quote.depositMemo)
            ActivityLog.record(ActivityRecord(
                kind: .send, title: "Bridge \(from.symbol) → \(toToken?.symbol ?? "")",
                subtitle: "\(amountText) \(from.symbol) · \(fromChain.name) → \(toChain.name)",
                hash: hash, section: "wallet", usd: pendingUsd), owner: env.session.address)
            pollGeneration += 1
            await poll(deposit: deposit, memo: quote.depositMemo, generation: pollGeneration)
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
                switch state.status {
                case .success:
                    let out = state.swapDetails?.amountOutFormatted.map { "\($0) \(toToken?.symbol ?? "")" } ?? expectedOut ?? ""
                    recordCompletion(usd: state.swapDetails?.amountOutUsd.flatMap(Double.init))
                    resetQuote() // the deposit address is consumed — a new bridge must re-quote
                    phase = .done(out)
                    Task { await loadBalances() }
                    return
                case .refunded:
                    resetQuote()
                    phase = .failed("Bridge refunded — \(state.swapDetails?.refundReason ?? "the swap couldn't complete"). Your funds were returned on \(fromChain.name).")
                    return
                case .failed:
                    resetQuote()
                    phase = .failed(state.swapDetails?.refundReason ?? "The bridge failed.")
                    return
                default:
                    phase = .bridging(state.status)
                }
            } catch {
                guard generation == pollGeneration else { return } // started over during the failed request
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

    /// Persist a completed bridge (for Portfolio volume) and post the completion notification. Idempotent per tx hash.
    private func recordCompletion(usd: Double?) {
        let value = usd ?? pendingUsd ?? 0
        if let hash = pendingHash {
            BridgeStore.record(BridgeRecord(id: hash, usd: value, fromChain: fromChain.name, toChain: toChain.name,
                                            inSymbol: pendingInSymbol ?? "", outSymbol: toToken?.symbol ?? "", time: Date()),
                               owner: env.session.address)
        }
        Notifications.bridge(amount: "\(amountText) \(pendingInSymbol ?? "")", from: fromChain.name, to: toChain.name)
    }

    /// Return to a clean state to start another bridge, keeping the entered amount and re-quoting it (so a
    /// pre-broadcast failure like "no gas" can be retried without retyping).
    func reset() {
        pollGeneration += 1 // stop any poll still running from the previous bridge
        phase = .idle
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
