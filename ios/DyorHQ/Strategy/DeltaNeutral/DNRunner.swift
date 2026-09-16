import BigInt
import DyorKit
import Foundation
import Observation

/// Executes delta-neutral strategies while the app is in the foreground: the TWAP entry (spot slice → matching perp
/// short, repeated), margin funding, and the exit (close the short, sell the spot in slices). Every step is written
/// to the strategy record the moment it lands, so leaving the app mid-run loses nothing — `resume` picks up at the
/// next slice. All transactions are signed by the session wallet on this device; nothing runs while the app is closed.
@Observable
@MainActor
final class DNRunner {
    /// The strategy id currently being executed, if any.
    private(set) var runningID: String?
    private(set) var stepLabel: String?
    private var task: Task<Void, Never>?
    private var cancelRequested = false

    var isRunning: Bool { task != nil }

    enum RunnerError: LocalizedError {
        case readOnly, walletMissing, noQuote(String), impactTooHigh(Double, Int), sliceBelowLot, perpNotFilled, insufficientUSDC(Double), insufficientAUSD(Double), positionExists
        var errorDescription: String? {
            switch self {
            case .readOnly: return "Sign in with a wallet that can sign to run a strategy."
            case .walletMissing: return "The wallet is not available."
            case .noQuote(let why): return "No spot route: \(why)"
            case .impactTooHigh(let bps, let cap): return "Slice skipped: price impact \(String(format: "%.1f", bps)) bp is above your \(cap) bp cap. It retries next interval."
            case .sliceBelowLot: return "The slice bought less than one Perpl lot; the hedge waits for the next slice."
            case .perpNotFilled: return "Perpl did not fill the short (no liquidity inside the slippage bound)."
            case .insufficientUSDC(let need): return "Not enough USDC: this run needs about \(need.formatted(.currency(code: "USD"))) more."
            case .insufficientAUSD(let need): return "Not enough AUSD for the perp margin: about \(NumberStyle.number(need, maximumFractionDigits: 2)) AUSD more is needed in the wallet or free on Perpl. Swap USDC → AUSD on Trade (or deposit on Perps), then retry."
            case .positionExists: return "You already hold a position on this Perpl market. Close it first so the strategy's accounting stays exact."
            }
        }
    }

    // MARK: Lifecycle

    /// Continues any entering / exiting strategy after a relaunch.
    func resume(env: AppEnvironment) {
        guard task == nil, let owner = env.session.address else { return }
        if let pending = DNStore.strategies(owner: owner).first(where: { ($0.status == .entering && !$0.paused) || $0.status == .exiting }) {
            start(id: pending.id, env: env)
        }
    }

    /// Starts (or resumes) the strategy's current phase in the background of the UI.
    func start(id: String, env: AppEnvironment) {
        guard task == nil else { return }
        cancelRequested = false
        runningID = id
        task = Task { [weak self, weak env] in
            defer { Task { @MainActor in self?.task = nil; self?.runningID = nil; self?.stepLabel = nil } }
            guard let self, let env else { return }
            await self.run(id: id, env: env)
        }
    }

    /// Stops after the current on-chain step; the strategy stays where it is (paused entry, or exiting to be retried).
    func cancel() { cancelRequested = true }

    private func run(id: String, env: AppEnvironment) async {
        guard let owner = env.session.address, var s = DNStore.find(id: id, owner: owner) else { return }
        switch s.status {
        case .entering, .failed where !s.entryComplete:
            await enter(&s, env: env, owner: owner)
        case .exiting, .failed:
            await exit(&s, env: env, owner: owner)
        default:
            break
        }
    }

    // MARK: Entry

    private func enter(_ s: inout DNStrategy, env: AppEnvironment, owner: Address) async {
        guard let wallet = env.session.wallet else { fail(&s, RunnerError.readOnly, owner: owner); return }
        s.status = .entering
        s.paused = false
        s.lastError = nil
        DNStore.upsert(s, owner: owner)

        // 1. Perp margin first: the account must exist and hold the strategy's margin before the first short.
        do {
            try await ensureCollateral(&s, env: env, owner: owner, wallet: wallet)
        } catch {
            fail(&s, error, owner: owner)
            return
        }

        // 2. Slices: hedge anything a previous attempt left unhedged, buy the slice, then short what it bought.
        //    A buy counts the moment it lands, so a retry after a failed short never buys the same slice twice.
        while s.slicesDone < s.slices, !cancelRequested {
            if let next = s.nextSliceAt, next > Date() {
                stepLabel = "Next slice \(next.formatted(date: .omitted, time: .standard))"
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                if cancelRequested { break }
            }
            do {
                try await hedgeUnhedged(&s, env: env, owner: owner, wallet: wallet)
                try await buySlice(&s, env: env, owner: owner, wallet: wallet)
                try await hedgeUnhedged(&s, env: env, owner: owner, wallet: wallet)
            } catch let error as RunnerError {
                // Recoverable: skipped slice → wait one interval and retry the same slice.
                switch error {
                case .impactTooHigh, .noQuote, .sliceBelowLot, .perpNotFilled:
                    s.log(error.localizedDescription)
                    s.nextSliceAt = Date().addingTimeInterval(TimeInterval(s.parameters.twapIntervalSeconds))
                    DNStore.upsert(s, owner: owner)
                    continue
                default:
                    fail(&s, error, owner: owner)
                    return
                }
            } catch {
                fail(&s, error, owner: owner)
                return
            }
        }

        if cancelRequested {
            s.paused = true
            s.log("Entry paused after \(s.slicesDone) of \(s.slices) slices.")
            DNStore.upsert(s, owner: owner)
            return
        }
        // 3. Top up the hedge for any spot dust the slices left unhedged (a full lot or more).
        do {
            try await hedgeUnhedged(&s, env: env, owner: owner, wallet: wallet)
        } catch {
            fail(&s, error, owner: owner)
            return
        }
        s.status = .running
        s.nextSliceAt = nil
        s.log("Entry complete: \(NumberStyle.number(s.spotAcquiredUnits, maximumFractionDigits: 6)) \(s.spotSymbol) bought, \(NumberStyle.number(s.perpShortSize, maximumFractionDigits: 6)) \(s.symbol) shorted.")
        DNStore.upsert(s, owner: owner)
        if env.settings.notifyStrategy {
            Notifications.strategy(title: "Delta-neutral \(s.symbol) is live", body: "Long \(NumberStyle.number(s.spotAcquiredUnits, maximumFractionDigits: 6)) \(s.spotSymbol), short \(NumberStyle.number(s.perpShortSize, maximumFractionDigits: 6)) \(s.symbol)-PERP. Collecting funding while longs pay shorts.", strategyID: s.id)
        }
    }

    /// Makes sure the Perpl account exists and holds at least the strategy's margin plus its fee buffer (and Perpl's
    /// $10 opening minimum). The margin is AUSD — Perpl's collateral — taken from the wallet; USDC is only swapped
    /// for a shortfall when the strategy was started with "Top up AUSD from USDC" on.
    private func ensureCollateral(_ s: inout DNStrategy, env: AppEnvironment, owner: Address, wallet: any Wallet) async throws {
        stepLabel = "Checking Perpl collateral"
        let account = try await env.perpl.account(owner)
        if let account {
            let markets = try await env.perpl.markets(ids: [s.marketId])
            let positions = try await env.perpl.positions(account, markets: markets)
            if s.perpShortSize == 0, positions.contains(where: { $0.perpId == s.marketId }) { throw RunnerError.positionExists }
        }
        let balance = account.map { PerplService.fromCNS($0.balance) } ?? 0
        let need = max(s.perpMargin * (1 + max(0, s.parameters.marginBufferFraction)), account == nil ? 10 : 0)
        guard balance < need else { return }
        let shortfall = need - balance
        let (walletAUSD, _) = try await env.perpl.collateral(of: owner)
        var haveAUSD = PerplService.fromCNS(walletAUSD)
        if haveAUSD < shortfall {
            let missing = shortfall - haveAUSD
            guard s.parameters.topUpAUSDFromUSDC else { throw RunnerError.insufficientAUSD(missing) }
            // Opted in: swap USDC → AUSD for the difference (plus 0.5% for the route), then re-read.
            let usdcNeeded = missing * 1.005
            stepLabel = "Swapping USDC → AUSD for margin"
            let amountIn = Amount.raw(usdcNeeded, decimals: Token.usdc.decimals)
            let usdcBalance = (try? await ERC20.balances(of: [.usdc], owner: owner, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] ?? 0
            guard usdcBalance >= amountIn else { throw RunnerError.insufficientUSDC(usdcNeeded) }
            let request = SwapRequest(tokenIn: .usdc, tokenOut: .ausd, amountIn: amountIn, slippageBps: s.parameters.spotSlippageBps, account: owner)
            let outcome = await env.swap.quotes(for: request)
            guard outcome.best != nil else { throw RunnerError.noQuote(outcome.errors.values.first ?? "USDC → AUSD") }
            let (_, hash, skipped) = try await swap(outcome, owner: owner, impactCap: nil, env: env, wallet: wallet) { "Swapping USDC → AUSD for margin on \($0)" }
            for note in skipped { s.log(note) }
            s.log("Swapped \(NumberStyle.number(usdcNeeded, maximumFractionDigits: 2)) USDC → AUSD for margin", hash: hash)
            DNStore.upsert(s, owner: owner)
            haveAUSD = PerplService.fromCNS(try await env.perpl.collateral(of: owner).wallet)
        }
        let deposit = min(haveAUSD, max(shortfall, account == nil ? 10 : 0))
        guard deposit > 0 else { throw RunnerError.insufficientAUSD(shortfall) }
        stepLabel = account == nil ? "Opening Perpl account" : "Depositing margin"
        let plan = env.perpl.depositPlan(amountCNS: PerplService.toCNS(deposit), hasAccount: account != nil)
        let hash = try await send(plan, env: env, wallet: wallet)
        s.collateralDepositedUSD += deposit
        s.log("Deposited \(NumberStyle.number(deposit, maximumFractionDigits: 2)) AUSD to Perpl", hash: hash)
        DNStore.upsert(s, owner: owner)
    }

    /// Runs a plan one step at a time so a slow confirmation never fails the strategy: a step whose receipt is late
    /// is waited on (up to five more minutes) before the next step is sent. Approvals the allowance already covers
    /// are skipped by the sender.
    private func send(_ steps: [TransactionStep], env: AppEnvironment, wallet: any Wallet) async throws -> Data {
        var last: Data?
        for step in steps {
            do {
                last = try await env.sender.run([step], from: wallet) { _ in }
            } catch TransactionError.timedOut(let hash) {
                stepLabel = "Waiting for confirmation: \(step.label)"
                let receipt = try await env.rpc.waitForReceipt(hash, timeout: 300)
                guard receipt.success else { throw TransactionError.reverted(hash) }
                last = hash
            } catch TransactionError.rejected(let reason) where reason == "Nothing to send." {
                continue
            }
        }
        guard let hash = last else { throw TransactionError.rejected("Nothing to send.") }
        return hash
    }

    /// Executes a swap on the best-ranked venue and falls back to the next one when a venue rejects the transaction
    /// before it is sent (a stale route, an emptied book level, a venue-specific limit). A transaction that was
    /// sent is never re-routed: its outcome is final and the balances tell the truth.
    private func swap(_ outcome: QuoteResult, owner: Address, impactCap: Int?, env: AppEnvironment, wallet: any Wallet,
                      label: (String) -> String) async throws -> (quote: VenueQuote, hash: Data, skipped: [String]) {
        var skipped: [String] = []
        var lastError: Error?
        for quote in outcome.quotes {
            if let cap = impactCap, let impact = quote.priceImpactBps, impact > cap { continue }
            stepLabel = label(quote.venue.displayName)
            do {
                let steps = try await quote.build(owner)
                let hash = try await send(steps, env: env, wallet: wallet)
                return (quote, hash, skipped)
            } catch let error as TransactionError {
                // `.rejected` is the pre-send simulation saying no; anything else means a transaction went out.
                guard case .rejected = error else { throw error }
                lastError = error
                skipped.append("\(quote.venue.displayName) rejected the swap before sending: \(describe(error)) Trying the next venue.")
            } catch {
                lastError = error
                skipped.append("\(quote.venue.displayName) rejected the swap before sending: \(describe(error)) Trying the next venue.")
            }
        }
        throw lastError ?? RunnerError.noQuote("no venue could execute this swap")
    }

    /// One TWAP slice's spot buy, measured by the wallet's balance delta. It is counted (and persisted) the moment
    /// it lands; the matching short follows in `hedgeUnhedged`.
    private func buySlice(_ s: inout DNStrategy, env: AppEnvironment, owner: Address, wallet: any Wallet) async throws {
        let index = s.slicesDone + 1
        let spot = s.spotTokenModel
        let amountIn = s.sliceAmount
        guard amountIn > 0 else { s.slicesDone += 1; return }
        stepLabel = "Slice \(index)/\(s.slices): quoting \(spot.symbol)"

        let usdcBalance = (try? await ERC20.balances(of: [.usdc], owner: owner, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] ?? 0
        guard usdcBalance >= amountIn else { throw RunnerError.insufficientUSDC(Amount.units(amountIn - usdcBalance, decimals: 6)) }

        let request = SwapRequest(tokenIn: .usdc, tokenOut: spot, amountIn: amountIn, slippageBps: s.parameters.spotSlippageBps, account: owner)
        let outcome = await env.swap.quotes(for: request)
        guard let best = outcome.best else { throw RunnerError.noQuote(outcome.errors.values.first ?? "no venue can route this pair right now") }
        if let impact = best.priceImpactBps, impact > s.parameters.maxSpotImpactBps { throw RunnerError.impactTooHigh(Double(impact), s.parameters.maxSpotImpactBps) }

        let before = try await spotBalance(spot, owner: owner, env: env)
        let slices = s.slices
        let (quote, hash, skipped) = try await swap(outcome, owner: owner, impactCap: s.parameters.maxSpotImpactBps, env: env, wallet: wallet) { venue in
            "Slice \(index)/\(slices): buying \(spot.symbol) on \(venue)"
        }
        for note in skipped { s.log(note) }
        let after = try await spotBalance(spot, owner: owner, env: env)
        let acquiredRaw = after > before ? after - before : 0
        let acquired = Amount.units(acquiredRaw, decimals: spot.decimals)
        let spent = Amount.units(amountIn, decimals: 6)
        s.spotAcquiredUnits += acquired
        s.spotSpentUSD += spent
        s.spotImpactCostUSD += spent * Double(max(0, quote.priceImpactBps ?? 0)) / 10_000
        s.slicesDone += 1
        s.nextSliceAt = s.slicesDone < s.slices ? Date().addingTimeInterval(TimeInterval(s.parameters.twapIntervalSeconds)) : nil
        s.log("Slice \(index): bought \(NumberStyle.number(acquired, maximumFractionDigits: 6)) \(spot.symbol) for \(NumberStyle.number(spent, maximumFractionDigits: 2)) USDC via \(quote.route)", hash: hash)
        DNStore.upsert(s, owner: owner)
    }

    /// Shorts whatever spot is not yet hedged: the acquired units rounded down to the lot, never beyond the target.
    /// Dust below one lot waits for the next slice.
    private func hedgeUnhedged(_ s: inout DNStrategy, env: AppEnvironment, owner: Address, wallet: any Wallet) async throws {
        let size = DeltaNeutral.hedgeSize(acquiredUnits: s.spotAcquiredUnits, alreadyShort: s.perpShortSize, targetSize: s.targetPerpSize, lotDecimals: s.lotDecimals)
        guard size > 0 else { return }
        guard let market = try await env.perpl.markets(ids: [s.marketId]).first else { throw RunnerError.noQuote("Perpl market unavailable") }
        stepLabel = "Slice \(max(1, min(s.slicesDone, s.slices)))/\(s.slices): shorting \(NumberStyle.number(size, maximumFractionDigits: 6)) \(s.symbol)"
        try await short(&s, size: size, market: market, env: env, owner: owner, wallet: wallet)
    }

    /// A reduce-nothing market short (marketable IOC limit at the slippage bound) placed on chain with the wallet,
    /// sized to the lot. The filled size is read back from the position so partial fills are recorded exactly.
    private func short(_ s: inout DNStrategy, size: Double, market: PerpMarket, env: AppEnvironment, owner: Address, wallet: any Wallet) async throws {
        let before = try await shortSize(market: market, owner: owner, env: env)
        let input = OrderInput(market: market, side: .short, kind: .market, size: size, leverage: s.parameters.perpLeverage, reduceOnly: false, slippageBps: s.parameters.perpSlippageBps)
        let hash = try await send(env.perpl.orderPlan(input), env: env, wallet: wallet)
        let after = try await shortSize(market: market, owner: owner, env: env)
        let filled = max(0, after - before)
        guard filled > 0 else { throw RunnerError.perpNotFilled }
        let notional = filled * market.mark
        s.perpShortSize = after
        s.perpEntryNotional += notional
        s.perpEntryFeeUSD += notional * s.parameters.takerFeeBps / 10_000
        s.log("Shorted \(NumberStyle.number(filled, maximumFractionDigits: 6)) \(s.symbol)-PERP at ≈\(NumberStyle.number(market.mark)) (\(NumberStyle.number(s.parameters.perpLeverage, maximumFractionDigits: 1))×)", hash: hash)
        DNStore.upsert(s, owner: owner)
    }

    // MARK: Exit

    /// Unwinds: close the short (free on Perpl), then sell the spot back to USDC in slices.
    func beginExit(id: String, env: AppEnvironment) {
        guard let owner = env.session.address, var s = DNStore.find(id: id, owner: owner) else { return }
        s.status = .exiting
        s.paused = false
        s.lastError = nil
        s.log("Exit requested.")
        DNStore.upsert(s, owner: owner)
        start(id: id, env: env)
    }

    private func exit(_ s: inout DNStrategy, env: AppEnvironment, owner: Address) async {
        guard let wallet = env.session.wallet else { fail(&s, RunnerError.readOnly, owner: owner); return }
        s.status = .exiting
        DNStore.upsert(s, owner: owner)
        do {
            // 1. Close the short.
            if let market = try await env.perpl.markets(ids: [s.marketId]).first, let account = try await env.perpl.account(owner),
               let position = try await env.perpl.positions(account, markets: [market]).first(where: { $0.perpId == s.marketId && $0.side == .short }) {
                stepLabel = "Closing the \(s.symbol) short"
                let balanceBefore = PerplService.fromCNS(account.balance)
                let hash = try await send(env.perpl.closePositionPlan(market: market, position: position, slippageBps: s.parameters.perpSlippageBps), env: env, wallet: wallet)
                if let after = try await env.perpl.account(owner) {
                    // Whatever settled into the balance beyond the margin is realized P&L incl. funding.
                    let settled = PerplService.fromCNS(after.balance) - balanceBefore
                    s.fundingRealizedAtExit = position.premium
                    s.log("Closed the short: \(NumberStyle.number(position.size, maximumFractionDigits: 6)) \(s.symbol) · settled \(settled.formatted(.currency(code: "USD").sign(strategy: .always()))) to the Perpl balance", hash: hash)
                } else {
                    s.log("Closed the short", hash: hash)
                }
                s.perpShortSize = 0
                DNStore.upsert(s, owner: owner)
            }
            // 2. Sell the spot in slices.
            let spot = s.spotTokenModel
            var remaining = try await spotBalance(spot, owner: owner, env: env)
            let target = Amount.raw(max(0, s.spotHeldUnits), decimals: spot.decimals)
            remaining = min(remaining, target)
            if spot.isNative { // keep gas back
                let gasBuffer = BigUInt(2) * BigUInt(10).power(16)
                remaining = remaining > gasBuffer ? remaining - gasBuffer : 0
            }
            let slices = DeltaNeutral.twapSchedule(totalIn: remaining, slices: s.parameters.twapSlices, interval: TimeInterval(s.parameters.twapIntervalSeconds), start: Date())
            for slice in slices where !cancelRequested {
                if slice.notBefore > Date() {
                    stepLabel = "Next sell slice \(slice.notBefore.formatted(date: .omitted, time: .standard))"
                    try? await Task.sleep(for: .seconds(max(1, slice.notBefore.timeIntervalSinceNow)))
                    if cancelRequested { break }
                }
                stepLabel = "Selling \(spot.symbol) slice \(slice.index + 1)/\(slices.count)"
                let request = SwapRequest(tokenIn: spot, tokenOut: .usdc, amountIn: slice.amountIn, slippageBps: s.parameters.spotSlippageBps, account: owner)
                let outcome = await env.swap.quotes(for: request)
                guard outcome.best != nil else { throw RunnerError.noQuote(outcome.errors.values.first ?? "\(spot.symbol) → USDC") }
                let usdcBefore = (try? await ERC20.balances(of: [.usdc], owner: owner, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] ?? 0
                let total = slices.count
                let (quote, hash, skipped) = try await swap(outcome, owner: owner, impactCap: nil, env: env, wallet: wallet) { venue in
                    "Selling \(spot.symbol) slice \(slice.index + 1)/\(total) on \(venue)"
                }
                for note in skipped { s.log(note) }
                let usdcAfter = (try? await ERC20.balances(of: [.usdc], owner: owner, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] ?? usdcBefore
                let proceeds = Amount.units(usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0, decimals: 6)
                let sold = Amount.units(slice.amountIn, decimals: spot.decimals)
                s.spotSoldUnits += sold
                s.spotProceedsUSD += proceeds
                s.spotImpactCostUSD += proceeds * Double(max(0, quote.priceImpactBps ?? 0)) / 10_000
                s.log("Sold \(NumberStyle.number(sold, maximumFractionDigits: 6)) \(spot.symbol) for \(NumberStyle.number(proceeds, maximumFractionDigits: 2)) USDC via \(quote.route)", hash: hash)
                DNStore.upsert(s, owner: owner)
            }
            if cancelRequested {
                s.log("Exit paused; tap Exit again to finish selling the spot.")
                DNStore.upsert(s, owner: owner)
                return
            }
            s.status = .closed
            s.exitedAt = Date()
            s.log("Exit complete.")
            DNStore.upsert(s, owner: owner)
            if env.settings.notifyStrategy {
                Notifications.strategy(title: "Delta-neutral \(s.symbol) closed", body: "The short is closed and the spot is back in USDC. Open the strategy for the final accounting.", strategyID: s.id)
            }
        } catch {
            fail(&s, error, owner: owner)
        }
    }

    // MARK: Helpers

    private func fail(_ s: inout DNStrategy, _ error: Error, owner: Address) {
        s.status = .failed
        s.lastError = describe(error)
        s.log("Stopped: \(describe(error))")
        DNStore.upsert(s, owner: owner)
        if NotificationHub.shared.owner == owner {
            Notifications.strategy(kind: .risk, title: "Delta-neutral \(s.symbol) needs attention", body: describe(error), strategyID: s.id)
        }
    }

    private func spotBalance(_ token: Token, owner: Address, env: AppEnvironment) async throws -> BigUInt {
        if token.isNative { return try await env.rpc.balance(of: owner) }
        return try await ERC20.balances(of: [token], owner: owner, rpc: env.rpc, multicall: env.multicall)[token.address] ?? 0
    }

    private func shortSize(market: PerpMarket, owner: Address, env: AppEnvironment) async throws -> Double {
        guard let account = try await env.perpl.account(owner) else { return 0 }
        return try await env.perpl.positions(account, markets: [market]).first { $0.perpId == market.id && $0.side == .short }?.size ?? 0
    }
}
