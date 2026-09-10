import BigInt
import DyorKit
import SwiftUI

/// Automated Market Making. The user configures a Mid or Grid strategy with take-profit / stop-loss; the app places a
/// bracketed ladder over Perpl's authenticated path (each level a resting limit with a native TP/SL trigger that fires
/// venue-side), persists it, and hands off to the live status dashboard. A background manager recycles it from flat and
/// keeps the trading socket alive while the app is active. Ported from Nadobro's Mid/Grid, adapted to on-device.
struct MarketMakingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(PerplTrading.self) private var perplTrading

    enum Mode: String, CaseIterable, Identifiable { case mid, grid; var id: String { rawValue }; var label: String { self == .mid ? "Mid" : "Grid" } }
    enum Curve: String, CaseIterable, Identifiable { case flat, linear, geometric; var id: String { rawValue }; var label: String { rawValue.capitalized } }

    @State private var markets: [PerpMarket] = []
    @State private var market: PerpMarket?
    @State private var account: PerpAccount?
    @State private var loading = true

    @State private var mode: Mode = .grid
    @State private var capitalText = "100"
    @State private var leverage = 2.0
    @State private var takeProfitPct = 0.5
    @State private var stopLossPct = 1.5
    // Mid
    @State private var spreadBp = 10.0
    @State private var levels = 2
    @State private var curve: Curve = .flat
    @State private var bias = 0.0
    // Grid
    @State private var gridLong = true
    @State private var gridLevels = 3
    @State private var gridStepBp = 15.0

    @State private var confirmStart = false
    @State private var placing = false
    @State private var startError: String?
    @State private var runningID: String?

    private var capital: Double { Double(capitalText) ?? 0 }
    private var mark: Double { market?.mark ?? 0 }
    private var hasAccount: Bool { account != nil }
    private var deployed: Double { capital * leverage }

    /// An existing running strategy on the selected market, if any.
    private var existing: MMStrategy? {
        MMStore.active(owner: session.address).first { $0.marketId == market?.id }
    }

    private func makeStrategy() -> MMStrategy? {
        guard let market else { return nil }
        return MMStrategy(
            id: UUID().uuidString, marketId: market.id, symbol: market.symbol,
            priceDecimals: market.priceDecimals, lotDecimals: market.lotDecimals,
            mode: mode.rawValue, startedAt: Int(Date().timeIntervalSince1970),
            capital: capital, leverage: leverage, takeProfitPct: takeProfitPct, stopLossPct: stopLossPct,
            spreadBp: spreadBp, levelsPerSide: levels, curve: curve.rawValue, bias: bias,
            gridLong: gridLong, gridLevels: gridLevels, gridStepBp: gridStepBp,
            startBalance: 0, volume: 0, fills: [], placedLevels: [], restingPrices: [], active: false
        )
    }

    private var previewLevels: [MMLevel] { makeStrategy()?.levels(mark: mark) ?? [] }

    var body: some View {
        List {
            if let existing { runningBanner(existing) }
            modeSection
            marketSection
            parametersSection
            bracketSection
            if !previewLevels.isEmpty { previewSection }
            explainer
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Market Making")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { actionBar }
        .task { await load() }
        .task(id: session.address) { perplTrading.refresh(address: session.address) }
        .navigationDestination(item: $runningID) { id in MMStatusView(strategyID: id) }
        .confirmationDialog("Start this strategy?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start & Place \(previewLevels.count) orders") { Task { await start() } }
        } message: {
            Text("Deploys ≈ \(NumberStyle.number(deployed, maximumFractionDigits: 0)) AUSD across \(previewLevels.count) bracketed orders on \(market?.symbol ?? "")-PERP. Each level auto-closes at its take-profit or stop-loss.")
        }
    }

    private func load() async {
        loading = true
        let list = (try? await env.perpl.markets()) ?? []
        markets = list.filter { $0.status == 0 || $0.mark > 0 }
        if market == nil { market = markets.first }
        if let address = session.address { account = try? await env.perpl.account(address) }
        loading = false
    }

    // MARK: Sections

    private func runningBanner(_ s: MMStrategy) -> some View {
        Section {
            Button { runningID = s.id } label: {
                HStack(spacing: 12) {
                    Circle().fill(Color.positive).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.mode.capitalized) strategy running").font(.subheadline.weight(.semibold))
                        Text("Tap to view live status").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Strategy", selection: $mode) { ForEach(Mode.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).listRowBackground(Color.clear)
        } footer: {
            Text(mode == .mid
                 ? "Quote both sides around the mid and earn the spread as price oscillates through your ladder."
                 : "A directional grid: rest a ladder of \(gridLong ? "buys below" : "sells above") the mid, each auto-closing at its take-profit.")
        }
    }

    private var marketSection: some View {
        Section {
            if loading, markets.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading markets…").foregroundStyle(.secondary) }
            } else {
                Picker("Market", selection: $market) {
                    ForEach(markets) { m in Text("\(m.symbol)-PERP").tag(Optional(m)) }
                }
                if let market { LabeledContent("Mark price", value: NumberStyle.number(market.mark)) }
            }
        } header: { Text("Market") }
    }

    @ViewBuilder private var parametersSection: some View {
        Section("Capital") {
            HStack {
                Text("Margin")
                Spacer()
                TextField("0", text: $capitalText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 100)
                Text("AUSD").foregroundStyle(.secondary)
            }
            Stepper(value: $leverage, in: 1...10, step: 1) { LabeledContent("Leverage", value: "\(NumberStyle.number(leverage, maximumFractionDigits: 0))×") }
        }

        if mode == .mid {
            Section("Mid strategy") {
                Stepper(value: $spreadBp, in: 1...100, step: 1) { LabeledContent("Half-spread", value: "\(NumberStyle.number(spreadBp, maximumFractionDigits: 0)) bp") }
                Stepper(value: $levels, in: 1...4) { LabeledContent("Levels per side", value: "\(levels)") }
                Picker("Size curve", selection: $curve) { ForEach(Curve.allCases) { Text($0.label).tag($0) } }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Directional bias", value: bias == 0 ? "Neutral" : (bias > 0 ? "Bullish" : "Bearish"))
                    Slider(value: $bias, in: -1...1, step: 0.25)
                }
            }
        } else {
            Section("Grid strategy") {
                Picker("Direction", selection: $gridLong) { Text("Long (buy dips)").tag(true); Text("Short (sell rips)").tag(false) }
                    .pickerStyle(.segmented)
                Stepper(value: $gridLevels, in: 2...6) { LabeledContent("Grid levels", value: "\(gridLevels)") }
                Stepper(value: $gridStepBp, in: 5...100, step: 5) { LabeledContent("Step per level", value: "\(NumberStyle.number(gridStepBp, maximumFractionDigits: 0)) bp") }
            }
        }
    }

    private var bracketSection: some View {
        Section {
            Stepper(value: $takeProfitPct, in: 0.1...10, step: 0.1) {
                LabeledContent("Take-profit", value: "\(NumberStyle.number(takeProfitPct, maximumFractionDigits: 1))%")
            }
            Stepper(value: $stopLossPct, in: 0...10, step: 0.5) {
                LabeledContent("Stop-loss", value: stopLossPct == 0 ? "Off" : "\(NumberStyle.number(stopLossPct, maximumFractionDigits: 1))%")
            }
        } header: {
            Text("Take-profit / Stop-loss")
        } footer: {
            Text("Placed as native Perpl trigger orders on every level — the keeper fires them when the mark crosses, so they're accurate and work even when the app is closed.")
        }
    }

    private var previewSection: some View {
        Section {
            ForEach(previewLevels.sorted { $0.entry > $1.entry }) { level in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(sideLabel(level.positionSide)).font(.caption.weight(.bold))
                            .foregroundStyle(level.positionSide == .long ? Color.positive : Color.negative).frame(width: 34, alignment: .leading)
                        Text(NumberStyle.number(level.entry)).monospacedDigit()
                        Spacer()
                        Text("\(NumberStyle.number(level.size, maximumFractionDigits: 4)) \(market?.symbol ?? "")").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack(spacing: 10) {
                        Spacer().frame(width: 34)
                        if let tp = level.takeProfit { Text("TP \(NumberStyle.number(tp))").font(.caption2).foregroundStyle(Color.positive).monospacedDigit() }
                        if let sl = level.stopLoss { Text("SL \(NumberStyle.number(sl))").font(.caption2).foregroundStyle(Color.negative).monospacedDigit() }
                        Spacer()
                    }
                }
                .padding(.vertical, 1)
            }
        } header: {
            HStack { Text("Ladder preview"); Spacer(); Text("\(previewLevels.count) orders").foregroundStyle(.secondary) }
        } footer: {
            Text("Total deployed ≈ \(NumberStyle.number(deployed, maximumFractionDigits: 0)) AUSD notional. Resting limit orders never cross the spread.")
        }
    }

    private func sideLabel(_ side: PositionSide) -> String {
        mode == .mid ? (side == .long ? "Bid" : "Ask") : (side == .long ? "Buy" : "Sell")
    }

    private var explainer: some View {
        Section {
            Text("The app runs the strategy: it places the bracketed ladder, and while open re-arms it once a cycle fully closes out. Take-profit and stop-loss are native venue triggers, so exits fire accurately even when the app is closed. Requires one-click trading.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Action

    @ViewBuilder private var actionBar: some View {
        VStack(spacing: 8) {
            if let startError { Text(startError).font(.caption).foregroundStyle(Color.attention) }
            if existing != nil {
                Button { runningID = existing?.id } label: { Text("View running strategy").frame(maxWidth: .infinity).fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).tint(.brand)
            } else if !hasAccount {
                Text("Fund a Perpl account to run this strategy.").font(.caption).foregroundStyle(.secondary)
                Button { router.openPerp(id: market?.id ?? 1) } label: { Text("Fund Perpl").frame(maxWidth: .infinity).fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).tint(.brand)
            } else if !perplTrading.isReady {
                Text("Automated strategies need one-click trading.").font(.caption).foregroundStyle(.secondary)
                NavigationLink { PerplTradingView() } label: { Text("Enable One-Click Trading").frame(maxWidth: .infinity).fontWeight(.semibold).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent).tint(.brand)
            } else {
                PrimaryButton(title: placing ? "Placing…" : "Start Strategy", isBusy: placing, isDisabled: previewLevels.isEmpty || !session.canSign) {
                    Haptics.tap(); confirmStart = true
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func start() async {
        startError = nil
        placing = true
        defer { placing = false }
        guard var strategy = makeStrategy(), let selected = market, let owner = session.address else { return }
        // Fresh mark + starting balance, so orders are priced to the live market and realized PnL is measured from now.
        let markets = (try? await env.perpl.markets()) ?? []
        let fresh = markets.first { $0.id == selected.id } ?? selected
        guard fresh.mark > 0 else { startError = "Couldn't read the market price."; return }
        let startBalance = (try? await env.perpl.account(owner)).map { Amount.units($0.balance, decimals: Perpl.collateralDecimals) } ?? 0

        // Persist a manageable record BEFORE placing, so a crash mid-placement leaves a strategy the manager/Stop can
        // reconcile — never orphaned orders with no record.
        strategy.startBalance = startBalance
        strategy.active = true
        MMStore.upsert(strategy, owner: owner)

        let placed = await MMExecutor.place(strategy, market: fresh, mark: fresh.mark, env: env)
        guard !placed.isEmpty else {
            MMStore.remove(id: strategy.id, owner: owner) // nothing rested — drop the placeholder
            startError = "No orders were accepted. Check your Perpl balance and try again."
            return
        }
        strategy.placedLevels = placed
        strategy.restingPrices = placed.map(\.entry)
        MMStore.upsert(strategy, owner: owner)
        NotificationCenter.default.post(name: .mmStrategyChanged, object: nil)
        Haptics.success()
        runningID = strategy.id
    }
}
