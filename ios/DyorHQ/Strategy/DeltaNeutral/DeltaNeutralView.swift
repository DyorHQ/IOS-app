import BigInt
import DyorKit
import SwiftUI

/// Set up a delta-neutral funding position. Simple mode (the default) answers three questions on one screen — which
/// market pays, what this amount earns, what can go wrong — and keeps the proof behind ⓘ buttons and Details. Pro
/// mode shows every parameter and table. Numbers come from Perpl's contract and live spot quotes either way.
struct DeltaNeutralView: View {
    struct DashboardRequest: Identifiable, Hashable { let id = UUID(); let strategyID: String }
    enum DetailTopic: String, Identifiable { case funding, costs, risk; var id: String { rawValue } }

    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var model = DeltaNeutralSetupModel()
    @State private var capitalText = ""
    @State private var lastSuggested = ""
    @State private var showAdvanced = false
    @State private var showDetails = false
    @State private var showReceipt = false
    @State private var showIntro = false
    @State private var detail: DetailTopic?
    /// A fresh request per open so the destination fires even when the same strategy is opened twice in a row.
    @State private var openRequest: DashboardRequest?
    @State private var startError: String?

    private var parameters: DeltaNeutral.Parameters { model.parameters }
    private var pro: Bool { settings.proStrategies }
    private var alreadyRunning: Bool { model.running.contains { $0.marketId == model.market?.id && $0.status != .closed } }
    private var canStart: Bool { session.canSign && model.sizing?.isViable == true && model.problems.isEmpty && model.costs != nil && !alreadyRunning }
    private var previewKey: String {
        "\(model.market?.id ?? 0)-\(model.spot?.id.hex ?? "")-\(capitalText)-\(parameters.perpLeverage)-\(parameters.twapSlices)-\(parameters.twapIntervalSeconds)-\(parameters.marginBufferFraction)-\(parameters.topUpAUSDFromUSDC)-\(pro)"
    }

    var body: some View {
        List {
            if !model.running.isEmpty { runningSection }
            marketSection
            amountSection
            if pro {
                proMarketSection
                fundingSection
                proDeploySection
                if let sizing = model.sizing { planSection(sizing) }
                costSection
                riskSection
            } else {
                glanceSection
                detailsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Delta Neutral")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { modeMenu } }
        .safeAreaInset(edge: .bottom) { actionBar }
        .task {
            model.autoSlicing = !settings.proStrategies
            await model.load(env: env, address: session.address)
            if capitalText.isEmpty { suggestAmount(model.usdcBalance) }
        }
        .task(id: session.address) { model.refreshRunning(owner: session.address) }
        .task(id: previewKey) {
            model.parameters.spotCapitalUSD = Double(capitalText.replacingOccurrences(of: ",", with: ".")) ?? 0
            await model.preview(env: env, address: session.address)
        }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(20)); await model.refreshMarket(env: env, address: session.address) }
        }
        .onChange(of: model.usdcBalance) { _, usdc in suggestAmount(usdc) }
        .onReceive(NotificationCenter.default.publisher(for: .dnStrategyChanged)) { _ in model.refreshRunning(owner: session.address) }
        .navigationDestination(item: $openRequest) { request in DNDashboardView(strategyID: request.strategyID) }
        .onChange(of: router.pendingDeltaNeutralID) { _, id in
            guard let id, !id.isEmpty else { return }
            router.pendingDeltaNeutralID = nil
            open(id)
        }
        .onAppear {
            if let id = router.pendingDeltaNeutralID, !id.isEmpty { router.pendingDeltaNeutralID = nil; open(id) }
            if !settings.dnIntroSeen { showIntro = true }
        }
        .sheet(isPresented: $showIntro, onDismiss: { settings.dnIntroSeen = true }) { DNIntroSheet() }
        .sheet(isPresented: $showReceipt) { DNStartReceipt(model: model) { showReceipt = false; start() } }
        .sheet(item: $detail) { topic in DNDetailSheet(topic: topic, model: model) }
    }

    // MARK: Shared sections

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

    /// Markets ranked by what they pay a short right now; green pays, grey does not.
    private var marketSection: some View {
        Section {
            if model.markets.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(model.loadError ?? "Loading Perpl markets…").foregroundStyle(.secondary) }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.rankedMarkets) { m in
                            MarketChip(asset: m.asset, hourly: m.fundingRateHourly, selected: m.id == model.market?.id) { model.selectMarket(id: m.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        } header: {
            Text("Market")
        } footer: {
            if !pro { Text("Green pays shorts right now. Rates are Perpl's, refreshed every 20 s.") }
        }
    }

    private var amountSection: some View {
        Section {
            HStack {
                Text("Amount")
                Spacer()
                TextField("200", text: $capitalText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text("USDC").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([100, 250, 500], id: \.self) { amount in
                    Button("$\(amount)") { setAmount(Double(amount)) }.buttonStyle(.bordered).controlSize(.small)
                }
                if let usdc = model.usdcBalance, usdc >= 20 {
                    Button("Max") { setAmount(min(usdc.rounded(.down), 100_000)) }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                if let usdc = model.usdcBalance {
                    Text("Wallet \(usdc.formatted(.currency(code: "USD")))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Amount")
        } footer: {
            if !pro { Text("Buys this much of the asset with USDC. The matching short's margin comes from AUSD.") }
        }
    }

    // MARK: Simple mode

    private var glanceSection: some View {
        Section {
            HStack(alignment: .top) {
                earningsText
                Spacer(minLength: 8)
                info(.funding)
            }
            .padding(.vertical, 2)
            if let costs = model.costs, let projection = model.projection {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Costs \(costs.total.formatted(.currency(code: "USD"))) to enter and exit").font(.subheadline.weight(.medium))
                        Text(breakevenText(projection)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    info(.costs)
                }
            }
            if let market = model.market, let sizing = model.sizing, sizing.isViable {
                let liq = PerplService.liquidationPrice(side: .short, entry: market.mark, size: sizing.perpSize, margin: sizing.perpMargin, premium: 0, maintenanceFraction: market.maintMarginFraction)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let liq, market.mark > 0 {
                            Text("Liquidated only if \(market.asset) rallies \(NumberStyle.percent((liq - market.mark) / market.mark * 100, fractionDigits: 0))").font(.subheadline.weight(.medium))
                        } else {
                            Text("Liquidation price unavailable").font(.subheadline.weight(.medium))
                        }
                        Text("before you add margin. Lower leverage moves it further away.").font(.caption).foregroundStyle(.secondary)
                        leverageChips
                    }
                    Spacer(minLength: 8)
                    info(.risk)
                }
            }
            readinessRows
        } header: {
            Text("At a Glance")
        }
    }

    @ViewBuilder private var earningsText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let projection = model.projection {
                if projection.earning {
                    Text("You'd earn ≈ \(projection.perDay.formatted(.currency(code: "USD"))) a day")
                        .font(.title3.weight(.semibold)).foregroundStyle(Color.positive)
                    Text("\(NumberStyle.percent(projection.annualPct, fractionDigits: 1, signed: false)) a year at today's rate. It is recomputed every hour.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if projection.direction == .shortsPayLongs {
                    Text("Earns nothing right now").font(.title3.weight(.semibold)).foregroundStyle(Color.negative)
                    Text("Shorts are paying about \(abs(projection.perDay).formatted(.currency(code: "USD"))) a day at today's rate. Wait for the market to turn green.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Earns nothing this hour").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Funding is 0 this interval. Perpl recomputes it every hour.").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.previewing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quoting your entry…").foregroundStyle(.secondary) }
            } else if let error = model.previewError {
                InlineError(message: error)
            } else if model.sizing?.isViable == false {
                InlineError(message: "Too small: the short would be below one lot on this market.")
            } else {
                Text("Enter an amount to see what it earns.").foregroundStyle(.secondary)
            }
        }
    }

    private func breakevenText(_ projection: DeltaNeutral.Projection) -> String {
        guard let hours = projection.breakevenHours else { return "Pays for itself only once funding turns positive." }
        return hours < 48 ? "Pays for itself in about \(NumberStyle.number(hours, maximumFractionDigits: 1)) hours of funding." : "Pays for itself in about \(NumberStyle.number(hours / 24, maximumFractionDigits: 1)) days of funding."
    }

    private var leverageChips: some View {
        HStack(spacing: 6) {
            ForEach([1.0, 2.0], id: \.self) { leverage in
                Button("\(Int(leverage))×") { model.parameters.perpLeverage = leverage }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(parameters.perpLeverage == leverage ? Color.brand : Color.secondary)
            }
            if ![1.0, 2.0].contains(parameters.perpLeverage) {
                Text("\(NumberStyle.number(parameters.perpLeverage, maximumFractionDigits: 1))× (Pro)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var readinessRows: some View {
        if !session.canSign {
            Label("Sign in with a wallet that can sign to start.", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.subheadline).foregroundStyle(Color.attention)
        } else if let sizing = model.sizing, sizing.isViable {
            if !model.balancesLoaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking your balances…").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                let usdcHave = model.usdcBalance ?? 0
                let usdcOK = usdcHave + 0.000001 >= model.usdcNeeded
                readyRow(ok: usdcOK, text: usdcOK
                    ? "\(NumberStyle.number(model.usdcNeeded, maximumFractionDigits: 2)) USDC ready"
                    : "Need \(NumberStyle.number(model.usdcNeeded, maximumFractionDigits: 2)) USDC, you have \(NumberStyle.number(usdcHave, maximumFractionDigits: 2))")
                if model.ausdShortfall <= 0 {
                    readyRow(ok: true, text: "\(NumberStyle.number(model.ausdNeeded, maximumFractionDigits: 2)) AUSD ready for the margin")
                } else if parameters.topUpAUSDFromUSDC {
                    HStack {
                        readyRow(ok: true, text: "Converts ≈ \(NumberStyle.number(model.ausdShortfall * 1.005, maximumFractionDigits: 2)) USDC to AUSD when you start")
                        Spacer()
                        Button("Undo") { model.parameters.topUpAUSDFromUSDC = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack {
                        readyRow(ok: false, text: "Short \(NumberStyle.number(model.ausdShortfall, maximumFractionDigits: 2)) AUSD for the margin")
                        Spacer()
                        Button("Convert \(NumberStyle.number((model.ausdShortfall * 1.005).rounded(.up), maximumFractionDigits: 0)) USDC") { model.parameters.topUpAUSDFromUSDC = true }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            ForEach(model.parameterProblems + model.quoteProblems, id: \.self) { InlineError(message: $0) }
        }
    }

    private func readyRow(ok: Bool, text: String) -> some View {
        Label { Text(text).font(.subheadline) } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? Color.positive : Color.negative)
        }
    }

    private func info(_ topic: DetailTopic) -> some View {
        Button { detail = topic } label: {
            Image(systemName: "info.circle").font(.body).foregroundStyle(Color.brand)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More about \(topic.rawValue)")
    }

    private var detailsSection: some View {
        @Bindable var model = model
        return Section {
            DisclosureGroup(isExpanded: $showDetails) {
                if let sizing = model.sizing, let market = model.market, sizing.isViable {
                    LabeledContent("Buy", value: "\(NumberStyle.number(sizing.spotUnits, maximumFractionDigits: 6)) \(model.spot?.token.symbol ?? "") for \(NumberStyle.number(sizing.spotBudget, maximumFractionDigits: 2)) USDC")
                    LabeledContent("Short", value: "\(NumberStyle.number(sizing.perpSize, maximumFractionDigits: 6)) \(market.asset) at \(NumberStyle.number(parameters.perpLeverage, maximumFractionDigits: 1))×")
                    LabeledContent("Margin", value: "\(NumberStyle.number(sizing.requiredAUSD, maximumFractionDigits: 2)) AUSD")
                    LabeledContent("Entry", value: model.entryText)
                }
                Toggle(isOn: $model.parameters.autoExitOnFundingFlip) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exit automatically if funding turns against you")
                        Text("After \(parameters.exitAfterIntervals) hourly settlements at or below zero, while DyorHQ is open.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { showIntro = true } label: { Label("How it works", systemImage: "questionmark.circle") }
                Button { setPro(true) } label: { Label("Pro settings: slices, slippage, alerts", systemImage: "slider.horizontal.3") }
            } label: {
                Label("Details", systemImage: "list.bullet")
            }
        } footer: {
            Text("Entry, exit and the monitor run while DyorHQ is open. Nothing is delegated; every step is signed by your wallet.")
        }
    }

    // MARK: Pro mode

    private var proMarketSection: some View {
        Section {
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
        } header: {
            Text("Instruments")
        } footer: {
            Text("Only markets with a spot token on Monad can be hedged: BTC, ETH and MON. The spot leg is bought on the best of Kuru, Uniswap and Monday Trade; the short lives on Perpl.")
        }
    }

    private var fundingSection: some View {
        Section {
            DNSetupRows(model: model).funding
        } header: {
            Text("Funding on Perpl")
        }
    }

    private var proDeploySection: some View {
        @Bindable var model = model
        return Section {
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
            Toggle(isOn: $model.parameters.autoExitOnFundingFlip) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exit automatically on a funding flip")
                    Text("After the intervals set below, while the app is open.").font(.caption).foregroundStyle(.secondary)
                }
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
            LabeledContent("Per slice", value: "\((sizing.spotBudget / Double(max(1, parameters.twapSlices))).formatted(.currency(code: "USD"))) · \(model.entryText)")
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
            DNSetupRows(model: model).costs
        } header: {
            Text("Costs Before You Start")
        }
    }

    private var riskSection: some View {
        Section {
            DNSetupRows(model: model).risk
        } header: {
            Text("Risk")
        }
    }

    // MARK: Chrome

    private var modeMenu: some View {
        Menu {
            Button { setPro(!pro) } label: {
                Label(pro ? "Simple view" : "Pro view: every setting", systemImage: pro ? "rectangle.compress.vertical" : "slider.horizontal.3")
            }
            Button { showIntro = true } label: { Label("How it works", systemImage: "questionmark.circle") }
        } label: {
            Image(systemName: pro ? "slider.horizontal.3" : "ellipsis.circle")
        }
        .accessibilityLabel("Strategy options")
    }

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let startError { InlineError(message: startError) }
            PrimaryButton(title: alreadyRunning ? "Already running on this market" : "Start earning", image: "scale.balance", isDisabled: !canStart) {
                showReceipt = true
            }
            if !session.canSign { Text("Sign in with a wallet that can sign to start.").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: Actions

    private func setPro(_ on: Bool) {
        settings.proStrategies = on
        model.autoSlicing = !on
    }

    /// Prefills the amount once: half the wallet's USDC rounded to $10, between $20 and $500; $200 when unknown.
    private func suggestAmount(_ usdc: Double?) {
        guard capitalText.isEmpty || capitalText == lastSuggested else { return }
        let suggested: Double
        if let usdc, usdc >= 20 { suggested = min(500, max(20, (usdc * 0.5 / 10).rounded(.down) * 10)) } else { suggested = 200 }
        lastSuggested = String(Int(suggested))
        capitalText = lastSuggested
    }

    private func setAmount(_ value: Double) {
        capitalText = value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
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

/// One market in the ranked row: the asset and what a short earns a year at today's rate.
private struct MarketChip: View {
    let asset: String
    let hourly: Double
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(asset).font(.subheadline.weight(.semibold))
                Text(hourly == 0 ? "0% now" : "\(NumberStyle.percent(PerplFunding.annualized(hourly: hourly) * 100, fractionDigits: 1))/yr")
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : hourly > 0 ? Color.positive : hourly < 0 ? Color.negative : Color.secondary)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Color.brand : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(asset), \(hourly > 0 ? "pays shorts" : hourly < 0 ? "shorts pay" : "no funding")")
    }
}

/// Row builders shared by the Pro sections and the ⓘ detail sheets, so both show the same numbers.
@MainActor
struct DNSetupRows {
    let model: DeltaNeutralSetupModel

    @ViewBuilder var funding: some View {
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
                Text(direction == .longsPayShorts ? "Longs pay shorts: your short earns funding." : direction == .shortsPayLongs ? "Shorts pay longs: a short would pay funding right now." : "No funding this interval.")
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
            Text("Read from the Exchange contract (fundingRatePct100k) and refreshed every 20 s. Perpl settles funding about once an hour (every 8 571 blocks); the rate is the interval's impact-price premium over the oracle, clamped by the contract. Positive: long positions pay short positions.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Pick a market to see its funding.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var costs: some View {
        let parameters = model.parameters
        if let costs = model.costs, let projection = model.projection {
            LabeledContent("Spot entry (impact + venue fee)") {
                HStack(spacing: 6) {
                    Text(costs.spotEntry.formatted(.currency(code: "USD"))).monospacedDigit()
                    if let note = model.spotCostNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
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
            Text("Spot costs come from a live quote of one slice against the perp mark. Perpl charges fees only to open (tier 1: 6.9 bp taker, 0.9 bp maker); closing is free. Funding figures assume the current rate holds; it is recomputed every hour and can flip.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.previewing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quoting the first slice…").foregroundStyle(.secondary) }
        } else if let error = model.previewError {
            InlineError(message: error)
        } else {
            Text("Enter an amount to see the costs.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var risk: some View {
        if let market = model.market, let sizing = model.sizing, sizing.isViable {
            let liq = PerplService.liquidationPrice(side: .short, entry: market.mark, size: sizing.perpSize, margin: sizing.perpMargin, premium: 0, maintenanceFraction: market.maintMarginFraction)
            LabeledContent("Short liquidation", value: liq.map { NumberStyle.number($0) } ?? "—")
            if let liq, market.mark > 0 {
                LabeledContent("Distance", value: "+\(String(format: "%.1f", (liq - market.mark) / market.mark * 100))% rally")
            }
            LabeledContent("Leverage", value: "\(NumberStyle.number(model.parameters.perpLeverage, maximumFractionDigits: 1))× (market max \(Int(market.maxLeverage))×)")
            LabeledContent("Maintenance margin", value: NumberStyle.percent(market.maintMarginFraction * 100, fractionDigits: 1, signed: false))
        }
        if let spot = model.spot, spot.isDerivative {
            Label("\(spot.token.symbol) is a derivative of \(model.market?.asset ?? ""): its own peg or yield adds basis the hedge does not cover.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.attention)
        }
        Text("The spot leg gains what the short loses on a rally, but the gain sits in your wallet while the short's margin sits on Perpl: the short can be liquidated before you move collateral across. Keep leverage low, watch the liquidation distance, and add margin from the strategy page when alerted.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The proof behind one line of the Simple screen.
private struct DNDetailSheet: View {
    let topic: DeltaNeutralView.DetailTopic
    let model: DeltaNeutralSetupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch topic {
                    case .funding: DNSetupRows(model: model).funding
                    case .costs: DNSetupRows(model: model).costs
                    case .risk: DNSetupRows(model: model).risk
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch topic {
        case .funding: return "Funding on Perpl"
        case .costs: return "Costs"
        case .risk: return "Risk"
        }
    }
}

/// Three cards, shown once and available from the menu afterwards.
private struct DNIntroSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    card("cart", "Buy the asset", "Your USDC buys BTC, ETH or MON on the best Monad venue, in a few steps so the price stays steady.")
                    card("arrow.down.right.circle", "Short the same size on Perpl", "A matching short, margined with AUSD, cancels the price risk: up moves and down moves net to zero.")
                    card("clock.badge.checkmark", "Collect funding every hour", "While longs pay shorts, your short earns the hourly funding. If it flips, you are told and the position can exit on its own.")
                    Text("Entry, exit and the monitor run while DyorHQ is open. Nothing is delegated; every step is signed by your wallet.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Got it") { dismiss() }.padding().background(.bar)
            }
        }
        .presentationDetents([.large])
    }

    private func card(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Color.brand, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The receipt: exactly what starts, what it costs, what it earns, and the one caveat. Replaces reading the page.
private struct DNStartReceipt: View {
    let model: DeltaNeutralSetupModel
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let sizing = model.sizing, let market = model.market, let spot = model.spot {
                    let p = model.parameters
                    Section {
                        LabeledContent("Buy", value: "\(NumberStyle.number(sizing.spotUnits, maximumFractionDigits: 6)) \(spot.token.symbol) for \(NumberStyle.number(sizing.spotBudget, maximumFractionDigits: 2)) USDC")
                        LabeledContent("Short", value: "\(NumberStyle.number(sizing.perpSize, maximumFractionDigits: 6)) \(market.asset) at \(NumberStyle.number(p.perpLeverage, maximumFractionDigits: 1))×")
                        LabeledContent("Margin", value: "\(NumberStyle.number(sizing.requiredAUSD, maximumFractionDigits: 2)) AUSD" + (p.topUpAUSDFromUSDC && model.ausdShortfall > 0 ? " (≈ \(NumberStyle.number(model.ausdShortfall * 1.005, maximumFractionDigits: 2)) USDC converted first)" : ""))
                        LabeledContent("Entry", value: model.entryText)
                        if let costs = model.costs {
                            LabeledContent("Costs in and out", value: costs.total.formatted(.currency(code: "USD")))
                        }
                        if let projection = model.projection {
                            LabeledContent("Earns now") {
                                Text(projection.earning ? "≈ \(projection.perDay.formatted(.currency(code: "USD"))) a day" : "nothing at today's rate")
                                    .foregroundStyle(projection.earning ? Color.positive : Color.negative)
                            }
                        }
                        LabeledContent("Auto exit", value: p.autoExitOnFundingFlip ? "after \(p.exitAfterIntervals) h of funding against you" : "off")
                    } footer: {
                        Text("Keep DyorHQ open for about \(max(1, Int(model.entryMinutes.rounded(.up)))) minute\(model.entryMinutes > 1.5 ? "s" : "") while it enters. Every step is a transaction signed by your wallet; funding changes hourly and can flip.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Start earning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Start earning", image: "scale.balance") { onStart() }.padding().background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Loads markets, sizes the legs, quotes one slice for the cost preview, and builds the strategy record.
@Observable
@MainActor
final class DeltaNeutralSetupModel {
    var parameters = DeltaNeutral.Parameters.default
    /// Simple mode picks the slice count from the amount (and doubles it while a slice's impact is too high);
    /// Pro mode leaves the steppers alone.
    var autoSlicing = true
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
    private var autoSlicesValue = 1
    private var autoSlicesBudget: Double = -1

    var balancesLoaded: Bool { usdcBalance != nil }
    var ausdAvailable: Double { (walletAUSD ?? 0) + (perplAccountBalance ?? 0) }
    /// AUSD that must be on Perpl before the first short: margin plus buffer, or Perpl's $10 opening minimum.
    var ausdNeeded: Double { max(sizing?.requiredAUSD ?? 0, perplAccountBalance == nil ? 10 : 0) }
    /// AUSD still missing after the wallet and the free Perpl balance are counted.
    var ausdShortfall: Double { sizing == nil ? 0 : max(0, ausdNeeded - ausdAvailable) }
    /// USDC the run needs: the spot budget, plus the AUSD shortfall when the user opted to swap for it.
    var usdcNeeded: Double { (sizing?.spotBudget ?? 0) + (ausdShortfall > 0 && parameters.topUpAUSDFromUSDC ? ausdShortfall * 1.005 : 0) }
    /// Markets by what a short earns right now, best first.
    var rankedMarkets: [PerpMarket] { markets.sorted { $0.fundingRateHourly > $1.fundingRateHourly } }
    var entryMinutes: Double { DeltaNeutral.entryMinutes(slices: parameters.twapSlices, intervalSeconds: parameters.twapIntervalSeconds) }
    var entryText: String {
        let n = parameters.twapSlices
        if n <= 1 { return "one step, hedged right after" }
        let minutes = entryMinutes
        let length = minutes < 1 ? "\(Int((minutes * 60).rounded())) s" : "\(NumberStyle.number(minutes, maximumFractionDigits: 1)) min"
        return "\(n) steps over \(length), hedged after every step"
    }

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
            // Default to the market that pays a short the most; the first listed (BTC) when none pays.
            if market == nil, let best = rankedMarkets.first {
                selectMarket(id: best.fundingRateHourly > 0 ? best.id : (markets.first?.id ?? best.id))
            }
            loadError = nil
        } catch {
            loadError = describe(error)
        }
        await refreshMarket(env: env, address: address)
        refreshRunning(owner: address)
    }

    /// Re-reads every hedgeable market (funding, mark), the block head, the spot price and the wallet's balances.
    func refreshMarket(env: AppEnvironment, address: Address?) async {
        guard let current = market else { return }
        if let fresh = try? await env.perpl.markets(ids: DeltaNeutral.hedgeableMarketIds) {
            for m in fresh {
                if let i = markets.firstIndex(where: { $0.id == m.id }) { markets[i] = m }
                if m.id == current.id { market = m }
            }
        }
        if let block = try? await env.rpc.blockNumber() { head = block; headAt = Date() }
        if let spot, let price = try? await env.prices.prices(for: [spot.token])[spot.token.address]?.usd { spotPriceUSD = price }
        await refreshBalances(env: env, address: address)
    }

    /// Wallet USDC (spot leg), wallet AUSD and the free Perpl balance (perp leg).
    func refreshBalances(env: AppEnvironment, address: Address?) async {
        guard let address else { usdcBalance = nil; walletAUSD = nil; perplAccountBalance = nil; return }
        if let usdc = (try? await ERC20.balances(of: [.usdc], owner: address, rpc: env.rpc, multicall: env.multicall))?[Monad.usdc] {
            let value = Amount.units(usdc, decimals: 6)
            if value != usdcBalance { usdcBalance = value }
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
        if autoSlicing {
            if autoSlicesBudget != s.spotBudget {
                autoSlicesValue = DeltaNeutral.autoSlices(spotBudget: s.spotBudget)
                autoSlicesBudget = s.spotBudget
            }
            if parameters.twapSlices != autoSlicesValue { parameters.twapSlices = autoSlicesValue }
            let interval = DeltaNeutral.Parameters.default.twapIntervalSeconds
            if parameters.twapIntervalSeconds != interval { parameters.twapIntervalSeconds = interval }
        }
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
        if let quoteImpact = quote.priceImpactBps, quoteImpact > parameters.maxSpotImpactBps {
            if autoSlicing, autoSlicesValue < 20 {
                // Smaller slices; the preview re-runs with the new count.
                autoSlicesValue = min(20, autoSlicesValue * 2)
                parameters.twapSlices = autoSlicesValue
                costs = nil; projection = nil
                return
            }
            quoteProblems = ["One slice already exceeds your max impact (\(quoteImpact) bp): use more slices or less capital."]
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
    }

    func makeStrategy() -> DNStrategy? {
        guard let market, let spot, let sizing, sizing.isViable, problems.isEmpty, sliceAmount > 0 else { return nil }
        return DNStrategy(marketId: market.id, symbol: market.asset, priceDecimals: market.priceDecimals, lotDecimals: market.lotDecimals, spot: spot, parameters: parameters, sizing: sizing, sliceAmountIn: sliceAmount)
    }
}
