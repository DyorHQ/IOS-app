import BigInt
import DyorKit
import SwiftUI

/// Set up a delta-neutral funding position: pick the Perpl market and its spot token, see the funding rate and who
/// pays whom right now, size the two legs, read every cost before anything is signed, and start the TWAP entry.
/// Numbers come from Perpl's contract (funding, margins) and live spot quotes; nothing here is estimated blind.
struct DeltaNeutralView: View {
    struct DashboardRequest: Identifiable, Hashable { let id = UUID(); let strategyID: String }
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var model = DeltaNeutralSetupModel()
    @State private var capitalText = "200"
    @State private var showAdvanced = false
    @State private var confirmStart = false
    /// A fresh request per open so the destination fires even when the same strategy is opened twice in a row.
    @State private var openRequest: DashboardRequest?
    @State private var startError: String?

    private var parameters: DeltaNeutral.Parameters { model.parameters }

    var body: some View {
        List {
            if !model.running.isEmpty { runningSection }
            marketSection
            fundingSection
            deploySection
            if let sizing = model.sizing { planSection(sizing) }
            costSection
            riskSection
            explainer
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Delta Neutral")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .safeAreaInset(edge: .bottom) { actionBar }
        .task { await model.load(env: env, address: session.address) }
        .task(id: session.address) { model.refreshRunning(owner: session.address) }
        .task(id: "\(model.market?.id ?? 0)-\(model.spot?.id.hex ?? "")-\(capitalText)-\(parameters.perpLeverage)-\(parameters.twapSlices)-\(parameters.marginBufferFraction)-\(parameters.topUpAUSDFromUSDC)") {
            model.parameters.spotCapitalUSD = Double(capitalText.replacingOccurrences(of: ",", with: ".")) ?? 0
            await model.preview(env: env, address: session.address)
        }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(20)); await model.refreshMarket(env: env, address: session.address) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dnStrategyChanged)) { _ in model.refreshRunning(owner: session.address) }
        .navigationDestination(item: $openRequest) { request in DNDashboardView(strategyID: request.strategyID) }
        .onChange(of: router.pendingDeltaNeutralID) { _, id in
            guard let id, !id.isEmpty else { return }
            router.pendingDeltaNeutralID = nil
            open(id)
        }
        .onAppear {
            if let id = router.pendingDeltaNeutralID, !id.isEmpty { router.pendingDeltaNeutralID = nil; open(id) }
        }
        .confirmationDialog("Start the delta-neutral position?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start: buy \(model.spot?.token.symbol ?? "") in \(parameters.twapSlices) slices, short \(model.market?.asset ?? "")-PERP") { start() }
        } message: {
            if let sizing = model.sizing, let market = model.market {
                Text("Buys \(sizing.notional.formatted(.currency(code: "USD"))) of \(model.spot?.token.symbol ?? "") with USDC and shorts \(NumberStyle.number(sizing.perpSize, maximumFractionDigits: 6)) \(market.asset) at \(NumberStyle.number(parameters.perpLeverage, maximumFractionDigits: 1))× with \(NumberStyle.number(sizing.requiredAUSD, maximumFractionDigits: 2)) AUSD of margin on Perpl. Each slice is a signed transaction; the app must stay open until the entry completes.")
            }
        }
    }

    // MARK: Sections

    private var runningSection: some View {
        Section("Your Positions") {
            ForEach(model.running) { s in
                Button { open(s.id) } label: {
                    HStack(spacing: 12) {
                        Circle().fill(s.status == .running ? Color.positive : s.status == .failed ? Color.negative : Color.attention).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.symbol) · \(s.status.title)").font(.subheadline.weight(.semibold))
                            Text("Long \(NumberStyle.number(s.spotHeldUnits, maximumFractionDigits: 6)) \(s.spotSymbol) · short \(NumberStyle.number(s.perpShortSize, maximumFractionDigits: 6)) \(s.symbol)-PERP").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var marketSection: some View {
        Section {
            if model.markets.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(model.loadError ?? "Loading Perpl markets…").foregroundStyle(.secondary) }
            } else {
                Picker("Perp market", selection: Binding(get: { model.market?.id ?? 0 }, set: { model.selectMarket(id: $0) })) {
                    ForEach(model.markets) { m in Text("\(m.asset)-PERP").tag(m.id) }
                }
                Picker("Spot leg", selection: Binding(get: { model.spot?.id ?? .zero }, set: { model.selectSpot(address: $0) })) {
                    ForEach(model.spotOptions) { option in Text(option.token.symbol).tag(option.id) }
                }
                if let spot = model.spot {
                    Text(spot.note).font(.caption).foregroundStyle(spot.isDerivative ? Color.attention : .secondary)
                }
                if let market = model.market {
                    LabeledContent("Perp mark", value: NumberStyle.number(market.mark))
                    if let spotPrice = model.spotPriceUSD {
                        LabeledContent("Spot price") {
                            HStack(spacing: 6) {
                                Text(NumberStyle.number(spotPrice)).monospacedDigit()
                                if market.mark > 0 {
                                    let basis = (market.mark - spotPrice) / spotPrice * 10_000
                                    Text("perp \(basis >= 0 ? "+" : "−")\(String(format: "%.1f", abs(basis))) bp").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Market")
        } footer: {
            Text("Only markets with a spot token on Monad can be hedged: BTC, ETH and MON. The spot leg is bought on the best of Kuru, Uniswap and Monday Trade; the short lives on Perpl.")
        }
    }

    private var fundingSection: some View {
        Section {
            if let market = model.market {
                let hourly = market.fundingRateHourly
                let direction = PerplFunding.direction(hourly: hourly)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Funding now").font(.caption).foregroundStyle(.secondary)
                        Text("\(hourly >= 0 ? "+" : "")\(NumberStyle.percent(hourly * 100, fractionDigits: 4, signed: false)) / hour")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(hourly > 0 ? Color.positive : hourly < 0 ? Color.negative : .secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Annualized").font(.caption).foregroundStyle(.secondary)
                        Text(NumberStyle.percent(PerplFunding.annualized(hourly: hourly) * 100, fractionDigits: 1)).font(.title3.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(hourly > 0 ? Color.positive : hourly < 0 ? Color.negative : .secondary)
                    }
                }
                .padding(.vertical, 4)
                Label {
                    Text(direction == .longsPayShorts ? "Longs pay shorts — your short EARNS funding." : direction == .shortsPayLongs ? "Shorts pay longs — a short would PAY funding right now." : "No funding this interval.")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: direction == .longsPayShorts ? "arrow.down.right.circle.fill" : direction == .shortsPayLongs ? "exclamationmark.triangle.fill" : "minus.circle")
                        .foregroundStyle(direction == .longsPayShorts ? Color.positive : direction == .shortsPayLongs ? Color.negative : .secondary)
                }
                LabeledContent("Per day", value: NumberStyle.percent(PerplFunding.daily(hourly: hourly) * 100, fractionDigits: 4))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    LabeledContent("Next settlement", value: model.countdown(at: ctx.date))
                }
                if market.fundingClampPct100k > 0 {
                    LabeledContent("Rate cap", value: "±\(NumberStyle.percent(PerplFunding.hourlyRate(pct100k: market.fundingClampPct100k) * 100, fractionDigits: 3, signed: false)) / hour")
                }
            } else {
                Text("Pick a market to see its funding.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Funding on Perpl")
        } footer: {
            Text("Read from the Exchange contract (`fundingRatePct100k`) and refreshed every 20 s. Perpl settles funding about once an hour (every 8 571 blocks); the rate is the interval's impact-price premium over the oracle, clamped by the contract. Positive: long positions pay short positions.")
        }
    }

    private var deploySection: some View {
        @Bindable var model = model
        return Section {
            HStack {
                Text("Spot capital")
                Spacer()
                TextField("200", text: $capitalText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 120)
                Text("USDC").foregroundStyle(.secondary)
            }
            if let balance = model.usdcBalance {
                LabeledContent("Wallet USDC", value: balance.formatted(.currency(code: "USD")))
            }
            Stepper(value: $model.parameters.perpLeverage, in: 1...min(3, model.market?.maxLeverage ?? 3), step: 0.5) {
                HStack { Text("Perp leverage"); Spacer(); Text("\(NumberStyle.number(model.parameters.perpLeverage, maximumFractionDigits: 1))×").monospacedDigit().foregroundStyle(.secondary) }
            }
            if let sizing = model.sizing {
                LabeledContent("Perp margin") {
                    Text("\(NumberStyle.number(sizing.requiredAUSD, maximumFractionDigits: 2)) AUSD").monospacedDigit()
                }
            }
            LabeledContent("AUSD available") {
                if model.balancesLoaded {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(NumberStyle.number(model.ausdAvailable, maximumFractionDigits: 2)) AUSD").monospacedDigit()
                        Text("\(NumberStyle.number(model.walletAUSD ?? 0, maximumFractionDigits: 2)) in wallet · \(NumberStyle.number(model.perplAccountBalance ?? 0, maximumFractionDigits: 2)) free on Perpl")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if model.balancesLoaded, model.ausdShortfall > 0 {
                Toggle(isOn: $model.parameters.topUpAUSDFromUSDC) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top up AUSD from USDC")
                        Text("Swaps about \(NumberStyle.number(model.ausdShortfall * 1.005, maximumFractionDigits: 2)) USDC → AUSD for the missing margin before depositing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { router.openSwap(tokenIn: .usdc, tokenOut: .ausd) } label: {
                    Label("Swap USDC → AUSD on Trade", systemImage: "arrow.left.arrow.right")
                }
            }
            Stepper(value: $model.parameters.twapSlices, in: 1...20) {
                HStack { Text("TWAP slices"); Spacer(); Text("\(model.parameters.twapSlices)").monospacedDigit().foregroundStyle(.secondary) }
            }
            Stepper(value: $model.parameters.twapIntervalSeconds, in: 10...900, step: 15) {
                HStack { Text("Slice interval"); Spacer(); Text("\(model.parameters.twapIntervalSeconds) s").monospacedDigit().foregroundStyle(.secondary) }
            }
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper(value: $model.parameters.spotSlippageBps, in: 5...500, step: 5) { row("Spot slippage", "\(model.parameters.spotSlippageBps) bp") }
                Stepper(value: $model.parameters.maxSpotImpactBps, in: 5...500, step: 5) { row("Max spot impact / slice", "\(model.parameters.maxSpotImpactBps) bp") }
                Stepper(value: $model.parameters.perpSlippageBps, in: 5...500, step: 5) { row("Perp slippage", "\(model.parameters.perpSlippageBps) bp") }
                Stepper(value: $model.parameters.exitFundingHourly, in: -0.0002...0.0002, step: 0.00001) { row("Exit when funding ≤", NumberStyle.percent(model.parameters.exitFundingHourly * 100, fractionDigits: 3) + "/h") }
                Stepper(value: $model.parameters.exitAfterIntervals, in: 1...48) { row("…for", "\(model.parameters.exitAfterIntervals) intervals") }
                Stepper(value: $model.parameters.liquidationBufferPct, in: 2...50, step: 1) { row("Liquidation alert at", "\(Int(model.parameters.liquidationBufferPct))% away") }
                Stepper(value: $model.parameters.maxDeltaDriftPct, in: 0.5...20, step: 0.5) { row("Drift alert at", NumberStyle.percent(model.parameters.maxDeltaDriftPct, fractionDigits: 1, signed: false)) }
                Stepper(value: $model.parameters.takerFeeBps, in: 0...10, step: 0.1) { row("Perp taker fee", "\(String(format: "%.1f", model.parameters.takerFeeBps)) bp") }
                Stepper(value: $model.parameters.marginBufferFraction, in: 0...0.5, step: 0.01) { row("Margin buffer", "\(Int((model.parameters.marginBufferFraction * 100).rounded()))% of margin") }
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Deploy")
        } footer: {
            Text("The spot leg is paid in USDC. The perp leg is margined in AUSD, Perpl's collateral and quote asset: margin = notional ÷ leverage, plus a small buffer for the open fee. 1× is the safest: equal collateral on both sides. Above 2× a rally can liquidate the short faster than the spot gain can be moved across. The entry is time-weighted: each slice buys spot, then shorts exactly what it bought.")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func planSection(_ sizing: DeltaNeutral.Sizing) -> some View {
        Section {
            LabeledContent("Notional per leg", value: sizing.notional.formatted(.currency(code: "USD")))
            LabeledContent("Spot to buy", value: "\(NumberStyle.number(sizing.spotUnits, maximumFractionDigits: 6)) \(model.spot?.token.symbol ?? "") for \(NumberStyle.number(sizing.spotBudget, maximumFractionDigits: 2)) USDC")
            LabeledContent("Perp short", value: "\(NumberStyle.number(sizing.perpSize, maximumFractionDigits: 6)) \(model.market?.asset ?? "")-PERP")
            LabeledContent("Perp margin", value: "\(NumberStyle.number(sizing.perpMargin, maximumFractionDigits: 2)) AUSD + \(NumberStyle.number(sizing.marginBuffer, maximumFractionDigits: 2)) buffer")
            if sizing.spotLeftover >= 0.01 {
                LabeledContent("USDC left over (lot rounding)", value: sizing.spotLeftover.formatted(.currency(code: "USD")))
            }
            LabeledContent("Per slice", value: "\((sizing.spotBudget / Double(max(1, parameters.twapSlices))).formatted(.currency(code: "USD"))) · \(parameters.twapSlices) slices · ≈\(Int(Double(parameters.twapSlices - 1) * Double(parameters.twapIntervalSeconds) / 60)) min")
            if let account = model.perplAccountBalance {
                LabeledContent("Perpl balance", value: "\(NumberStyle.number(account, maximumFractionDigits: 2)) AUSD free")
            } else {
                LabeledContent("Perpl account", value: "not opened yet (opens with the first deposit, $10 minimum)")
            }
            if !sizing.isViable { InlineError(message: "Too small: the short would be below one lot on this market.") }
            ForEach(model.problems, id: \.self) { InlineError(message: $0) }
        } header: {
            Text("Plan")
        }
    }

    private var costSection: some View {
        Section {
            if let costs = model.costs, let projection = model.projection {
                LabeledContent("Spot entry (impact + venue fee)") { costText(costs.spotEntry, note: model.spotCostNote) }
                LabeledContent("Spot exit (assumed same)", value: costs.spotExit.formatted(.currency(code: "USD")))
                LabeledContent("Perp open fee (taker \(String(format: "%.1f", parameters.takerFeeBps)) bp)", value: costs.perpEntry.formatted(.currency(code: "USD")))
                LabeledContent("Perp close fee", value: "free")
                LabeledContent("Gas (≈ 6 transactions)", value: costs.gas.formatted(.currency(code: "USD")))
                LabeledContent("Round trip") { Text("\(costs.total.formatted(.currency(code: "USD"))) · \(String(format: "%.1f", costs.bps(of: model.sizing?.notional ?? 0))) bp").fontWeight(.semibold).monospacedDigit() }
                LabeledContent("Funding per hour") { Text(projection.perHour.formatted(.currency(code: "USD").precision(.fractionLength(4)))).monospacedDigit().foregroundStyle(projection.earning ? Color.positive : Color.negative) }
                LabeledContent("Per day", value: projection.perDay.formatted(.currency(code: "USD")))
                LabeledContent("Per 30 days", value: projection.per30Days.formatted(.currency(code: "USD")))
                LabeledContent("Breakeven") {
                    if let hours = projection.breakevenHours { Text(hours < 48 ? "\(NumberStyle.number(hours, maximumFractionDigits: 1)) hours" : "\(NumberStyle.number(hours / 24, maximumFractionDigits: 1)) days").monospacedDigit() }
                    else { Text("never at this rate").foregroundStyle(Color.negative) }
                }
            } else if model.previewing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quoting the first slice…").foregroundStyle(.secondary) }
            } else if let error = model.previewError {
                InlineError(message: error)
            } else {
                Text("Enter capital to see the costs.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Costs Before You Start")
        } footer: {
            Text("Spot costs come from a live quote of one slice against the perp mark. Perpl charges fees only to open (tier 1: 6.9 bp taker, 0.9 bp maker); closing is free. Funding figures assume the current rate holds — it is recomputed every hour and can flip.")
        }
    }

    private var riskSection: some View {
        Section {
            if let market = model.market, let sizing = model.sizing, sizing.isViable {
                let liq = PerplService.liquidationPrice(side: .short, entry: market.mark, size: sizing.perpSize, margin: sizing.perpMargin, premium: 0, maintenanceFraction: market.maintMarginFraction)
                LabeledContent("Short liquidation", value: liq.map { NumberStyle.number($0) } ?? "—")
                if let liq, market.mark > 0 {
                    LabeledContent("Distance", value: "+\(NumberStyle.number((liq - market.mark) / market.mark * 100, maximumFractionDigits: 1))% rally")
                }
                LabeledContent("Maintenance margin", value: NumberStyle.percent(market.maintMarginFraction * 100, fractionDigits: 1, signed: false))
                LabeledContent("Market max leverage", value: "\(Int(market.maxLeverage))×")
            }
            if let spot = model.spot, spot.isDerivative {
                Label("\(spot.token.symbol) is a derivative of \(model.market?.asset ?? ""): its own peg or yield adds basis the hedge does not cover.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.attention)
            }
        } header: {
            Text("Risk")
        } footer: {
            Text("The spot leg gains what the short loses on a rally, but the gain sits in your wallet while the short's margin sits on Perpl: the short can be liquidated before you move collateral across. Keep leverage low, watch the liquidation distance, and add margin from the strategy page when alerted.")
        }
    }

    private var explainer: some View {
        Section("How It Works") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Buy the asset on spot (in slices, to keep price impact low).")
                Text("2. Short the same size on Perpl after each slice, so you are never more than one slice away from neutral.")
                Text("3. Price moves cancel out; you collect funding every hour while longs pay shorts.")
                Text("4. When funding flips, you are notified; exit closes the short (free) and sells the spot back to USDC.")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let startError { InlineError(message: startError) }
            PrimaryButton(title: model.running.contains(where: { $0.marketId == model.market?.id && $0.status != .closed }) ? "Already running on this market" : "Start Delta-Neutral", image: "scale.balance",
                          isDisabled: !session.canSign || model.sizing?.isViable != true || !model.problems.isEmpty || model.costs == nil || model.running.contains(where: { $0.marketId == model.market?.id && $0.status != .closed })) {
                confirmStart = true
            }
            if !session.canSign { Text("Sign in with a wallet that can sign to run a strategy.").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func costText(_ usd: Double, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(usd.formatted(.currency(code: "USD"))).monospacedDigit()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func start() {
        guard let strategy = model.makeStrategy() else { startError = "The plan is incomplete."; return }
        startError = nil
        DNStore.upsert(strategy, owner: session.address)
        if !settings.notifyStrategy { settings.notifyStrategy = true }
        Task { _ = await Notifications.requestAuthorization() }
        Haptics.success()
        env.dnRunner.start(id: strategy.id, env: env)
        model.refreshRunning(owner: session.address)
        open(strategy.id)
    }

    /// Pushes the dashboard. Deferred a beat so a push requested while this screen is itself still being pushed
    /// (opening from a notification or the Strategy banner) is not dropped by the navigation stack.
    private func open(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(openRequest == nil ? 250 : 0))
            openRequest = DashboardRequest(strategyID: id)
        }
    }
}

/// Loads markets, sizes the legs, quotes one slice for the cost preview, and builds the strategy record.
@Observable
@MainActor
final class DeltaNeutralSetupModel {
    var parameters = DeltaNeutral.Parameters.default
    private(set) var markets: [PerpMarket] = []
    private(set) var market: PerpMarket?
    private(set) var spot: DeltaNeutral.SpotOption?
    private(set) var spotOptions: [DeltaNeutral.SpotOption] = []
    private(set) var spotPriceUSD: Double?
    private(set) var usdcBalance: Double?
    private(set) var walletAUSD: Double?
    private(set) var perplAccountBalance: Double?
    private(set) var head: UInt64 = 0
    private(set) var headAt = Date()
    private(set) var running: [DNStrategy] = []
    private(set) var loadError: String?
    private(set) var sizing: DeltaNeutral.Sizing?
    private(set) var costs: DeltaNeutral.CostEstimate?
    private(set) var projection: DeltaNeutral.Projection?
    private(set) var spotCostNote: String?
    private(set) var previewing = false
    private(set) var previewError: String?
    /// Problems from the live quote (one slice already above the impact cap). Parameter and funding problems are
    /// derived properties, so they track the balances the moment they load instead of racing the first quote.
    private(set) var quoteProblems: [String] = []
    private var sliceAmount: BigUInt = 0

    var balancesLoaded: Bool { usdcBalance != nil }
    var ausdAvailable: Double { (walletAUSD ?? 0) + (perplAccountBalance ?? 0) }
    /// AUSD that must be on Perpl before the first short: margin plus buffer, or Perpl's $10 opening minimum.
    var ausdNeeded: Double { max(sizing?.requiredAUSD ?? 0, perplAccountBalance == nil ? 10 : 0) }
    /// AUSD still missing after the wallet and the free Perpl balance are counted.
    var ausdShortfall: Double { sizing == nil ? 0 : max(0, ausdNeeded - ausdAvailable) }
    /// USDC the run needs: the spot budget, plus the AUSD shortfall when the user opted to swap for it.
    var usdcNeeded: Double { (sizing?.spotBudget ?? 0) + (ausdShortfall > 0 && parameters.topUpAUSDFromUSDC ? ausdShortfall * 1.005 : 0) }

    var parameterProblems: [String] { market.map { parameters.problems(marketMaxLeverage: $0.maxLeverage) } ?? [] }
    var fundingProblems: [String] {
        guard let sizing, sizing.isViable, balancesLoaded else { return [] }
        var out: [String] = []
        if ausdShortfall > 0, !parameters.topUpAUSDFromUSDC {
            out.append("Not enough AUSD for the perp margin: it needs \(NumberStyle.number(ausdNeeded, maximumFractionDigits: 2)) AUSD and you have \(NumberStyle.number(ausdAvailable, maximumFractionDigits: 2)) (wallet + free Perpl balance). Swap USDC → AUSD on Trade, or turn on “Top up AUSD from USDC”.")
        }
        if let usdc = usdcBalance, usdc + 0.000001 < usdcNeeded {
            out.append("Not enough USDC: this plan needs \(usdcNeeded.formatted(.currency(code: "USD"))) and the wallet holds \(usdc.formatted(.currency(code: "USD"))).")
        }
        return out
    }
    var problems: [String] { parameterProblems + fundingProblems + quoteProblems }

    func load(env: AppEnvironment, address: Address?) async {
        do {
            let list = try await env.perpl.markets(ids: DeltaNeutral.hedgeableMarketIds)
            markets = list.filter { $0.mark > 0 }
            if market == nil, let first = markets.first { selectMarket(id: first.id) }
            loadError = nil
        } catch {
            loadError = describe(error)
        }
        await refreshMarket(env: env, address: address)
        refreshRunning(owner: address)
    }

    /// Re-reads the market (funding, mark), the block head, the spot price and the wallet's balances.
    func refreshMarket(env: AppEnvironment, address: Address?) async {
        guard let current = market else { return }
        if let fresh = try? await env.perpl.markets(ids: [current.id]).first {
            market = fresh
            if let i = markets.firstIndex(where: { $0.id == fresh.id }) { markets[i] = fresh }
        }
        if let block = try? await env.rpc.blockNumber() { head = block; headAt = Date() }
        if let spot, let price = try? await env.prices.prices(for: [spot.token])[spot.token.address]?.usd { spotPriceUSD = price }
        await refreshBalances(env: env, address: address)
    }

    /// Wallet USDC (spot leg), wallet AUSD and the free Perpl balance (perp leg).
    func refreshBalances(env: AppEnvironment, address: Address?) async {
        guard let address else { usdcBalance = nil; walletAUSD = nil; perplAccountBalance = nil; return }
        if let usdc = (try? await ERC20.balances(of: [.usdc], owner: address, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] {
            usdcBalance = Amount.units(usdc, decimals: 6)
        }
        if let collateral = try? await env.perpl.collateral(of: address) { walletAUSD = PerplService.fromCNS(collateral.wallet) }
        perplAccountBalance = (try? await env.perpl.account(address)).map { PerplService.fromCNS($0.balance) }
    }

    func refreshRunning(owner: Address?) { running = DNStore.active(owner: owner) }

    func selectMarket(id: Int) {
        guard let m = markets.first(where: { $0.id == id }) else { return }
        market = m
        spotOptions = DeltaNeutral.spotOptions(for: id)
        spot = spotOptions.first
        spotPriceUSD = nil
        costs = nil; projection = nil
    }

    func selectSpot(address: Address) {
        guard let option = spotOptions.first(where: { $0.id == address }) else { return }
        spot = option
        spotPriceUSD = nil
        costs = nil; projection = nil
    }

    /// Countdown to the next funding settlement, from the last block read and its wall-clock time.
    func countdown(at date: Date) -> String {
        guard let market, head > 0 else { return "—" }
        let elapsedBlocks = UInt64(max(0, date.timeIntervalSince(headAt)) / PerplFunding.assumedBlockSeconds)
        let seconds = max(0, Int(PerplFunding.secondsToNextSettlement(startBlock: market.fundingStartBlock, head: head + elapsedBlocks)))
        return String(format: "≈ %02d:%02d", seconds / 60, seconds % 60)
    }

    /// Sizes the legs and quotes one slice so the cost preview is real.
    func preview(env: AppEnvironment, address: Address?) async {
        guard let market, let spot, parameters.spotCapitalUSD > 0 else { sizing = nil; costs = nil; projection = nil; quoteProblems = []; return }
        let s = DeltaNeutral.sizing(parameters: parameters, price: market.mark, lotDecimals: market.lotDecimals)
        sizing = s
        quoteProblems = []
        guard s.isViable, parameterProblems.isEmpty else { costs = nil; projection = nil; return }
        previewing = true
        previewError = nil
        defer { previewing = false }
        let perSlice = Amount.raw(s.spotBudget / Double(max(1, parameters.twapSlices)), decimals: 6)
        sliceAmount = perSlice
        let request = SwapRequest(tokenIn: .usdc, tokenOut: spot.token, amountIn: perSlice, slippageBps: parameters.spotSlippageBps, account: address ?? Address(literal: "0x000000000000000000000000000000000000dEaD"))
        let outcome = await env.swap.quotes(for: request)
        guard let quote = outcome.best else {
            previewError = outcome.errors.values.first ?? "No venue can route USDC → \(spot.token.symbol) right now."
            costs = nil; projection = nil
            return
        }
        // Effective price paid vs the perp mark: what the hedge really costs, venue fee and impact included.
        let units = Amount.units(quote.amountOut, decimals: spot.token.decimals)
        let paid = Amount.units(perSlice, decimals: 6)
        let effective = units > 0 ? paid / units : 0
        let costBps = market.mark > 0 && effective > 0 ? (effective - market.mark) / market.mark * 10_000 : 0
        // The venue's own impact estimate is only meaningful when positive (a tiny probe slice can round below zero).
        let impactNote = (quote.priceImpactBps ?? 0) > 0 ? " · impact \(quote.priceImpactBps!) bp" : ""
        spotCostNote = "\(quote.venue.displayName) · \(String(format: "%.1f", costBps)) bp vs mark" + impactNote
        let gasUSD = 6 * 0.02 * ((try? await env.prices.prices(for: [.mon]))?[Monad.native]?.usd ?? 0)
        let c = DeltaNeutral.costs(notional: s.notional, spotImpactBpsPerSlice: max(0, costBps), perpFeeBps: parameters.takerFeeBps, gasUSD: gasUSD)
        costs = c
        projection = DeltaNeutral.projection(notional: s.notional, hourlyRate: market.fundingRateHourly, costs: c)
        if let quoteImpact = quote.priceImpactBps, quoteImpact > parameters.maxSpotImpactBps {
            quoteProblems = ["One slice already exceeds your max impact (\(quoteImpact) bp): use more slices or less capital."]
        }
    }

    func makeStrategy() -> DNStrategy? {
        guard let market, let spot, let sizing, sizing.isViable, problems.isEmpty, sliceAmount > 0 else { return nil }
        return DNStrategy(marketId: market.id, symbol: market.asset, priceDecimals: market.priceDecimals, lotDecimals: market.lotDecimals, spot: spot, parameters: parameters, sizing: sizing, sliceAmountIn: sliceAmount)
    }
}
