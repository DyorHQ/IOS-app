import BigInt
import DyorKit
import SwiftUI

/// The pro perpetuals screen, laid out like the best mobile perp DEXes: a tappable market header, a Chart/Trade view
/// toggle, and — in Trade view — the order ticket beside the live order book, with two full-width Long/Short buttons
/// under it. Placing an order, changing leverage, the order type, the size unit and the reference price each happen in
/// a focused bottom sheet with haptics, so the whole thing feels deliberate and fast. Everything — symbols, prices,
/// chart, book, positions — is Perpl's own data; orders go through the Exchange contract / Perpl trading connection.
struct PerpTradeView: View {
    let market: PerpMarket
    let model: PerpsModel
    /// Switch the visible market in place (the host owns the selection), so the header's chevron changes markets
    /// without a navigation push — the way a single-screen trading app does it.
    var onSelectMarket: (Int) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(Router.self) private var router

    @State private var feed = PerplFeed()
    @State private var candles: [PerpCandle] = []
    @State private var resolution = 3600
    @State private var loadingCandles = true
    @State private var viewMode: ViewMode = .trade
    @State private var chartDataTab: ChartDataTab = .book
    @State private var bottomTab: BottomTab = .positions
    @State private var ticket = OrderTicket()
    @State private var sizePercent: Double = 0
    /// True for the one sizeText change the slider itself drives, so the amount .onChange doesn't recompute the
    /// percentage from the lot-rounded size and make the thumb fight the finger mid-drag.
    @State private var suppressPercentSync = false
    @State private var priceType: PriceType = .last
    @State private var ticketError: String?

    // Sheets
    @State private var showConfirm = false
    @State private var showLeverage = false
    @State private var showOrderType = false
    @State private var showUnitPref = false
    @State private var showPriceType = false
    @State private var showSelect = false
    @State private var showDeposit = false
    @State private var showWithdraw = false
    @State private var showPortfolio = false
    @State private var closingPosition: PerpPosition?
    @State private var addingMargin: PerpPosition?
    @State private var cancellingOrder: PerpOrder?

    @State private var fills: [PerplFill] = []
    @State private var pnlByOrder: [Int: Double] = [:]
    @State private var loadingFills = false
    @State private var fillsError: String?

    enum ViewMode: String, CaseIterable, Identifiable { case chart = "Chart", trade = "Trade"; var id: String { rawValue } }
    enum ChartDataTab: String, CaseIterable, Identifiable { case book = "Order Book", trades = "Trades"; var id: String { rawValue } }
    enum BottomTab: String, CaseIterable, Identifiable { case positions = "Positions", orders = "Orders", assets = "Assets", history = "Trade History"; var id: String { rawValue } }
    enum PriceType: String, CaseIterable, Identifiable { case last = "Last", mid = "Mid"; var id: String { rawValue } }

    private var position: PerpPosition? { model.positions.first { $0.perpId == market.id } }
    private var live: PerplLiveState? { feed.state }
    private var mark: Double { live?.mark ?? market.mark }
    private var change24h: Double? { live?.change24h ?? model.change24h(for: market) }
    private var change24hAbs: Double? {
        if let prev = live?.prev24h, prev > 0 { return mark - prev }
        return change24h.map { mark * $0 / 100 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                marketHeader
                if viewMode == .chart {
                    chartSection
                } else {
                    tradeGrid
                    longShortButtons
                }
                Divider().padding(.top, 2)
                bottomSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDoneButton()
        .task {
            ticket.leverage = min(settings.defaultLeverage, maxLeverage)
            ticket.slippageBps = settings.slippageBps
            feed.focus(market)
            await loadCandles()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await loadCandles(showSpinner: false)
            }
        }
        .onDisappear { feed.stop() }
        .onChange(of: resolution) { _, _ in Task { await loadCandles() } }
        .onChange(of: model.fillSignal) { _, _ in
            if model.lastFilledPerpId == market.id { withAnimation { bottomTab = .positions } }
        }
        .task(id: session.address) { perplTrading.refresh(address: session.address); await loadFills() }
        .onChange(of: bottomTab) { _, tab in if tab == .history { Task { await loadFills() } } }
        .onChange(of: model.fillSignal) { _, _ in if model.lastFilledPerpId == market.id { Task { await loadFills() } } }
        .sheet(isPresented: $showConfirm) { orderConfirmSheet }
        .sheet(isPresented: $showLeverage) {
            LeverageSheet(leverage: ticket.leverage, maxLeverage: maxLeverage) { chosen in
                ticket.leverage = chosen
                clampSizeToMargin()
            }
        }
        .sheet(isPresented: $showOrderType) {
            OrderTypeSheet(kind: ticket.kind) { kind in
                ticket.kind = kind
                if kind == .market {
                    // Post-Only / Reduce Only are Limit-only controls; clear them so a stale flag can't leak into a
                    // Market order (which would change its meaning and skip the margin guard in OrderTicket.problem).
                    ticket.reduceOnly = false
                    ticket.postOnly = false
                } else if ticket.priceText.isEmpty {
                    ticket.priceText = plainSize(referencePrice(priceType))
                }
            }
        }
        .sheet(isPresented: $showUnitPref) {
            UnitPreferenceSheet(unit: ticket.amountUnit, asset: market.asset) { unit in
                if unit != ticket.amountUnit { convertAmount(to: unit) }
            }
        }
        .sheet(isPresented: $showPriceType) {
            PriceTypeSheet(selected: priceType) { type in
                priceType = type
                ticket.priceText = plainSize(referencePrice(type))
            }
        }
        .sheet(isPresented: $showSelect) {
            SelectPerpetualSheet(markets: model.markets, currentId: market.id, change: { model.change24h(for: $0) }) { id in
                onSelectMarket(id)
            }
        }
        .sheet(isPresented: $showDeposit) { CollateralSheet(kind: .deposit, model: model) }
        .sheet(isPresented: $showWithdraw) { CollateralSheet(kind: .withdraw, model: model) }
        .sheet(isPresented: $showPortfolio) { PerpsPortfolioView(model: model) }
        .sheet(item: $closingPosition) { position in
            ClosePositionSheet(market: market, position: position, mark: mark) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $addingMargin) { position in
            AddMarginSheet(market: market, position: position, available: availableMargin) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $cancellingOrder) { order in cancelOrderSheet(order) }
    }

    // MARK: Market header

    private var marketHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Haptics.selection(); showSelect = true
            } label: {
                HStack(spacing: 10) {
                    TokenLogo(symbol: market.asset, url: nil, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(market.asset).font(.title3.weight(.bold))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        headerChange
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            viewModePill
            Menu {
                Button("Deposit AUSD", systemImage: "plus.circle") { showDeposit = true }
                Button("Withdraw AUSD", systemImage: "minus.circle") { showWithdraw = true }.disabled(model.account == nil)
                Button("Portfolio", systemImage: "chart.xyaxis.line") { showPortfolio = true }.disabled(session.address == nil)
                Divider()
                Label(feed.connected ? "Live market data" : "Connecting…", systemImage: feed.connected ? "dot.radiowaves.left.and.right" : "hourglass")
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder private var headerChange: some View {
        let tint: Color = (change24h ?? 0) < 0 ? .negative : (change24h ?? 0) > 0 ? .positive : .secondary
        HStack(spacing: 6) {
            if let abs = change24hAbs {
                Text(abs.formatted(.currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(abs.magnitude < 1 ? 4 : 2))))
            }
            if change24hAbs != nil, change24h != nil { Text("/") }
            if let pct = change24h { Text(NumberStyle.percent(pct)) }
        }
        .font(.footnote.weight(.medium)).monospacedDigit()
        .foregroundStyle(tint)
    }

    private var viewModePill: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases) { mode in
                let active = viewMode == mode
                Button {
                    if viewMode != mode { Haptics.selection(); withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }
                } label: {
                    Image(systemName: mode == .chart ? "chart.xyaxis.line" : "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 46, height: 38)
                        .foregroundStyle(active ? Color.brand : Color.secondary)
                        .background(active ? Color(.systemBackground) : .clear, in: Capsule())
                        .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode == .chart ? "Chart view" : "Order view")
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    // MARK: Chart view

    private var chartSection: some View {
        VStack(spacing: 10) {
            TradingViewChart(candles: candles, levels: chartLevels)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) { positionBadge }
                .overlay {
                    if candles.isEmpty {
                        if loadingCandles { ProgressView() }
                        else { ContentUnavailableView("No Candles", systemImage: "chart.bar.xaxis", description: Text("Perpl has no candle history for this market yet.")) }
                    }
                }
            timeframePicker
            Picker("Data", selection: $chartDataTab) {
                ForEach(ChartDataTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch chartDataTab {
            case .book:
                SideOrderBook(book: feed.book, mark: mark, mid: live?.mid ?? live?.last ?? mark, changePct: change24h, symbol: market.asset, priceDecimals: market.priceDecimals, rows: 9, wide: true)
                    .frame(minHeight: 260)
            case .trades:
                TradesTape(trades: feed.trades, symbol: market.asset).frame(minHeight: 260)
            }
        }
    }

    private var timeframePicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.resolutions, id: \.0) { seconds, label in
                Button(label) { if resolution != seconds { Haptics.selection(); resolution = seconds } }
                    .font(.caption.weight(resolution == seconds ? .bold : .regular))
                    .foregroundStyle(resolution == seconds ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(resolution == seconds ? Color(.tertiarySystemFill) : .clear, in: Capsule())
            }
        }
    }

    static let resolutions: [(Int, String)] = [(60, "1m"), (300, "5m"), (900, "15m"), (3600, "1h"), (14400, "4h"), (86400, "1D")]

    // MARK: Trade grid — order ticket beside the live book

    private var tradeGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            orderTicket
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                fundingPanel
                SideOrderBook(book: feed.book, mark: mark, mid: live?.mid ?? live?.last ?? mark, changePct: change24h, symbol: market.asset, priceDecimals: market.priceDecimals, rows: 8, wide: false)
            }
            .frame(width: 150)
        }
    }

    private var fundingPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Funding (1h) / Countdown").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(fundingText).foregroundStyle(fundingTint)
                Text("/").foregroundStyle(.secondary)
                // A 1s timeline so the countdown ticks smoothly instead of only refreshing on incidental re-renders.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(countdownText(now: ctx.date)).foregroundStyle(.primary)
                }
            }
            .font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: Order ticket (left column)

    private var orderTicket: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Margin mode (static — Perpl is isolated-only) · Leverage (tap to adjust)
            HStack(spacing: 8) {
                // A bordered, secondary chip rather than a filled capsule, so it doesn't mimic the tappable leverage
                // button beside it — Perpl only offers isolated margin, so there's nothing to toggle.
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.caption2)
                    Text("Isolated").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Isolated margin")
                .accessibilityHint("This market is isolated-margin only")
                Button {
                    Haptics.selection(); showLeverage = true
                } label: {
                    Text("\(NumberStyle.number(ticket.leverage, maximumFractionDigits: ticket.leverage.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))x")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .accessibilityLabel("Leverage \(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1)) times")
                .accessibilityHint("Adjust leverage")
            }

            // Available + add funds
            HStack {
                Text("Available").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("\(NumberStyle.number(availableMargin, maximumFractionDigits: 2)) AUSD")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Button {
                    Haptics.selection(); showDeposit = true
                } label: {
                    Image(systemName: "plus.circle").font(.subheadline)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.brand)
                .accessibilityLabel("Add funds")
            }

            // Order type (+ price-type for limit)
            HStack(spacing: 8) {
                Button { Haptics.selection(); showOrderType = true } label: {
                    HStack {
                        Text(ticket.kind == .market ? "Market" : "Limit").fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                if ticket.kind == .limit {
                    Button { Haptics.selection(); showPriceType = true } label: {
                        Text(priceType.rawValue).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Color.brand.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.brand)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Price (limit) or Market Price placeholder
            if ticket.kind == .limit {
                stepperField(text: $ticket.priceText, placeholder: NumberStyle.number(mark), unit: "AUSD", step: priceStep)
            } else {
                Text("Market Price")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Amount + unit
            amountStepper

            // Size percent of available margin
            PercentSizeSlider(percent: $sizePercent) { pct in applyPercent(pct) }
                .disabled(model.account == nil || availableMargin <= 0)

            // Flags
            VStack(alignment: .leading, spacing: 10) {
                if ticket.kind == .market {
                    checkRow("Max Slippage", isOn: $ticket.maxSlippageEnabled)
                    if ticket.maxSlippageEnabled {
                        slippageField
                    }
                    checkRow("TP/SL", isOn: $ticket.tpslEnabled)
                } else {
                    checkRow("TP/SL", isOn: $ticket.tpslEnabled)
                    checkRow("Post-Only", isOn: $ticket.postOnly)
                    checkRow("Reduce Only", isOn: $ticket.reduceOnly)
                }
            }

            if ticket.tpslEnabled { tpslFields }

            // Summary
            VStack(spacing: 8) {
                summaryRow("Liq. Price", liquidationPairText, tint: nil, split: true)
                summaryRow("Max", "\(NumberStyle.number(maxNotional, maximumFractionDigits: 2)) AUSD")
                summaryRow("Fee", "\(NumberStyle.number(estFee, maximumFractionDigits: 2)) AUSD")
            }
            .padding(.top, 2)

            if let ticketError {
                Text(ticketError).font(.caption).foregroundStyle(Color.attention)
            }
        }
    }

    private var amountStepper: some View {
        HStack(spacing: 4) {
            Button { adjustAmount(-amountStep) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Decrease amount")
            TextField("Amount", text: $ticket.sizeText)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
                .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .onChange(of: ticket.sizeText) { _, _ in
                    ticketError = nil
                    // Keep the % slider in step with a typed amount, unless the slider itself drove this change.
                    if suppressPercentSync { suppressPercentSync = false } else { syncPercentFromSize() }
                }
            Button { adjustAmount(amountStep) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Increase amount")
            Divider().frame(height: 22)
            Button { Haptics.selection(); showUnitPref = true } label: {
                HStack(spacing: 3) {
                    Text(ticket.amountUnit == .usd ? "AUSD" : market.asset).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.trailing, 10).padding(.leading, 4).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityLabel("Amount unit, \(ticket.amountUnit == .usd ? "AUSD" : market.asset)")
            .accessibilityHint("Change size unit")
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepperField(text: Binding<String>, placeholder: String, unit: String, step: Double) -> some View {
        HStack(spacing: 4) {
            Button { adjust(text, by: -step) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Decrease price")
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
                .font(.subheadline.weight(.medium))
            Button { adjust(text, by: step) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Increase price")
            Text(unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.trailing, 12)
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var slippageField: some View {
        HStack {
            Text("Slippage").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField("0.5", text: Binding(
                get: { ticket.slippageBps == 0 ? "" : NumberStyle.number(Double(ticket.slippageBps) / 100, maximumFractionDigits: 2) },
                set: { ticket.slippageBps = Int(($0.perpDouble ?? 0) * 100) }
            ))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
            .font(.caption.weight(.medium)).frame(width: 60)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var tpslFields: some View {
        VStack(spacing: 8) {
            fieldRow("Take profit", text: $ticket.takeProfitText, unit: "USD", placeholder: "Optional")
            if let m = tpMetrics { triggerMetricRow("Exp. profit", m) }
            fieldRow("Stop loss", text: $ticket.stopLossText, unit: "USD", placeholder: "Optional")
            if let m = slMetrics { triggerMetricRow("Exp. loss", m) }
            Text(perplTrading.isReady ? "Placed on Perpl as keeper-managed trigger orders linked to this position." : tpslGateMessage)
                .font(.caption2).foregroundStyle(perplTrading.isReady ? Color.secondary : Color.attention)
        }
    }

    private func checkRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            Haptics.selection(); isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isOn.wrappedValue ? Color.brand : Color.secondary)
                Text(label).font(.subheadline).foregroundStyle(.primary)
                Spacer()
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(isOn.wrappedValue ? [.isButton, .isSelected] : .isButton)
    }

    private func summaryRow(_ label: String, _ value: String, tint: Color? = nil, split: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if split, liquidationLong != nil || liquidationShort != nil {
                HStack(spacing: 3) {
                    Text(liquidationLong.map { NumberStyle.number($0) } ?? "—").foregroundStyle(Color.positive)
                    Text("/").foregroundStyle(.secondary)
                    Text(liquidationShort.map { NumberStyle.number($0) } ?? "—").foregroundStyle(Color.negative)
                }
                .font(.subheadline.weight(.medium)).monospacedDigit()
            } else {
                Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
            }
        }
    }

    // MARK: Long / Short

    private var longShortButtons: some View {
        VStack(spacing: 10) {
            sideButton(.long, "Long", .positive)
            sideButton(.short, "Short", .negative)
            if !session.canSign {
                Text("Sign in to trade.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func sideButton(_ side: PositionSide, _ label: String, _ color: Color) -> some View {
        Button {
            attemptOrder(side)
        } label: {
            Text(label)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(Color.onStatus)
                .background(color.opacity(session.canSign ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!session.canSign)
    }

    private func attemptOrder(_ side: PositionSide) {
        ticket.side = side
        if let reason = ticket.problem(market: market, account: model.account, available: availableMargin) {
            Haptics.warning(); ticketError = reason; return
        }
        ticketError = nil
        Haptics.commit()
        showConfirm = true
    }

    // MARK: Bottom section (positions / orders / assets / trade history)

    private var bottomSection: some View {
        VStack(spacing: 14) {
            segmentedTabs
            switch bottomTab {
            case .positions:
                if let position { PositionCard(position: position, liveMark: mark, onClose: { closingPosition = position }, onAddMargin: { addingMargin = position }) }
                else { emptyRow("No open positions") }
            case .orders:
                let orders = model.orders.filter { $0.perpId == market.id }
                if orders.isEmpty { emptyRow("No open orders") }
                else { ForEach(orders) { order in OrderCard(order: order, onCancel: { cancellingOrder = order }) } }
            case .assets:
                let total = model.account.map { Amount.units($0.balance, decimals: 6) } ?? 0
                let inUse = model.account.map { Amount.units(min($0.balance, $0.locked), decimals: 6) } ?? 0
                DetailRows {
                    DetailRow("Total balance", total.formatted(.currency(code: "USD")))
                    DetailRow("In use (margin)", inUse.formatted(.currency(code: "USD")))
                    DetailRow("Available", availableMargin.formatted(.currency(code: "USD")))
                    DetailRow("Unrealized", model.unrealizedTotal.formatted(.currency(code: "USD").sign(strategy: .always())), tint: model.unrealizedTotal < 0 ? .negative : .positive)
                }
            case .history:
                historyList
            }
        }
    }

    /// Scrolling underline tabs like Miracle's Positions / Orders / Assets / Trade History.
    private var segmentedTabs: some View {
        HStack(spacing: 0) {
            ForEach(BottomTab.allCases) { tab in
                let active = bottomTab == tab
                Button {
                    if bottomTab != tab { Haptics.selection(); withAnimation(.easeInOut(duration: 0.15)) { bottomTab = tab } }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            Capsule().fill(active ? Color.brand : .clear).frame(height: 2.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: Trade history (this market)

    @ViewBuilder private var historyList: some View {
        if perplTrading.key == nil {
            emptyRow("Connect Perpl trading in Profile to see your history.")
        } else if let fillsError {
            InlineError(message: fillsError)
        } else if loadingFills, fills.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if fills.isEmpty {
            emptyRow("No trades on \(market.asset)-PERP yet")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(fills.prefix(50)) { fill in
                    historyRow(fill)
                    if fill.id != fills.prefix(50).last?.id { Divider() }
                }
            }
        }
    }

    private func historyRow(_ fill: PerplFill) -> some View {
        let pnl: Double? = fill.isClose ? pnlByOrder[fill.orderId] : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fill.direction).font(.subheadline.weight(.semibold))
                    .foregroundStyle(fill.side == .buy ? Color.positive : Color.negative)
                Spacer()
                Text(fill.time, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .trailing)], spacing: 6) {
                historyStat("Price", NumberStyle.number(fill.price), align: .leading)
                historyStat("Size", "\(NumberStyle.number(fill.size, maximumFractionDigits: 4)) \(fill.symbol)", align: .leading)
                historyStat("Value", fill.notional.formatted(.currency(code: "USD")), align: .trailing)
                historyStat("Fee", fill.fee.formatted(.currency(code: "USD")), align: .leading)
                Color.clear.frame(height: 0)
                pnlStat(pnl)
            }
        }
        .padding(.vertical, 10)
    }

    private func historyStat(_ label: String, _ value: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: align == .trailing ? .trailing : .leading)
    }

    @ViewBuilder private func pnlStat(_ pnl: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("PnL").font(.caption2).foregroundStyle(.secondary)
            if let pnl {
                Text(pnl, format: .currency(code: "USD").sign(strategy: .always()))
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(pnl < 0 ? Color.negative : (pnl > 0 ? Color.positive : Color.primary))
            } else {
                Text("—").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func loadFills() async {
        guard let key = perplTrading.key else { fills = []; pnlByOrder = [:]; fillsError = nil; return }
        loadingFills = fills.isEmpty
        defer { loadingFills = false }
        let markets = model.markets.isEmpty ? [market] : model.markets
        do {
            let fillPage = try await env.perpl.fills(key: key, markets: markets, count: 100)
            fills = fillPage.items.filter { $0.marketId == market.id }
            fillsError = nil
            if let pnlPage = try? await env.perpl.positionHistory(key: key, markets: markets, count: 100) {
                pnlByOrder = Dictionary(pnlPage.items.filter { $0.marketId == market.id }.map { ($0.orderId, $0.realizedPnl) }, uniquingKeysWith: +)
            }
        } catch {
            if fills.isEmpty { fillsError = describe(error) }
        }
    }

    // MARK: Confirmation

    @ViewBuilder private var orderConfirmSheet: some View {
        if perplTrading.isReady, let accountId = model.account?.accountId {
            AuthedOrderSheet(market: market, input: ticket.input(market: market, refPrice: refPrice), takeProfit: tpValue, stopLoss: slValue, accountId: accountId, sideColor: sideColor, summaryMargin: notional / max(ticket.leverage, 1)) {
                ticket.sizeText = ""; ticket.takeProfitText = ""; ticket.stopLossText = ""; sizePercent = 0
                Task { await model.load(env: env, address: session.address) }
            }
        } else {
            confirmSheet
        }
    }

    private var confirmSheet: some View {
        ConfirmationSheet(title: "Review Order", confirmTitle: ticket.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", build: { env.perpl.orderPlan(ticket.input(market: market, refPrice: refPrice)) }, onDone: { ticket.sizeText = ""; sizePercent = 0; Task { await model.load(env: env, address: session.address) } }, onCompleted: { hash in
            ActivityLog.record(ActivityRecord(kind: .perp, title: "\(ticket.side == .long ? "Long" : "Short") \(market.asset)-PERP", subtitle: "\(ticket.sizeText) \(market.asset) · \(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×", hash: hash, usd: notional > 0 ? notional : nil), owner: session.address)
        }) {
            DetailRow("Market", "\(market.asset)-PERP")
            DetailRow("Side", ticket.side == .long ? "Long" : "Short", tint: sideColor)
            DetailRow("Type", ticket.kind == .market ? "Market · \(NumberStyle.basisPoints(ticket.slippageBps)) slippage" : "Limit at \(ticket.priceText)")
            DetailRow("Size", "\(ticket.sizeText) \(ticket.amountUnit == .usd ? "AUSD" : market.asset)")
            DetailRow("Leverage", "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×")
            DetailRow("Margin", (notional / max(ticket.leverage, 1)).formatted(.currency(code: "USD")))
            // This path (perplTrading not ready) places a bare on-chain entry — it cannot attach TP/SL. Don't advertise
            // triggers the order won't carry; tell the user they need one-click trading for them.
            if ticket.tpslEnabled, !ticket.takeProfitText.isEmpty || !ticket.stopLossText.isEmpty {
                DetailRow("TP/SL", "Needs one-click trading — not placed", tint: .attention)
            }
        }
    }

    private func cancelOrderSheet(_ order: PerpOrder) -> some View {
        ConfirmationSheet(title: "Cancel Order", confirmTitle: "Cancel Order", build: { env.perpl.cancelPlan(perpId: order.perpId, orderId: order.orderId) }, onDone: { Task { await model.load(env: env, address: session.address) } }) {
            DetailRow("Market", order.symbol)
            DetailRow("Order", "\(order.side == .buy ? "Buy" : "Sell") \(NumberStyle.number(order.size)) at \(NumberStyle.number(order.price))")
        }
    }

    // MARK: TP/SL helpers

    private var tpValue: Double? { ticket.tpslEnabled ? ticket.takeProfitText.perpDouble : nil }
    private var slValue: Double? { ticket.tpslEnabled ? ticket.stopLossText.perpDouble : nil }
    private var sideColor: Color { ticket.side == .long ? .positive : .negative }

    private var tpslGateMessage: String {
        switch perplTrading.status {
        case .needsForwarding: return "Enable one-click trading in Profile to place take-profit and stop-loss."
        case .connecting: return "Connecting to Perpl trading…"
        default: return "Connect Perpl trading in Profile to place take-profit and stop-loss."
        }
    }

    private func triggerMetrics(_ trigger: Double?) -> (pct: Double, pnl: Double)? {
        guard let trigger, trigger > 0, refPrice > 0, baseSize > 0 else { return nil }
        let dir = ticket.side == .long ? 1.0 : -1.0
        return ((trigger - refPrice) / refPrice * 100, dir * (trigger - refPrice) * baseSize)
    }
    private var tpMetrics: (pct: Double, pnl: Double)? { triggerMetrics(tpValue) }
    private var slMetrics: (pct: Double, pnl: Double)? { triggerMetrics(slValue) }

    private func triggerMetricRow(_ label: String, _ m: (pct: Double, pnl: Double)) -> some View {
        HStack {
            Text("\(label) \(m.pnl.formatted(.currency(code: "USD").sign(strategy: .always())))")
            Spacer()
            Text(NumberStyle.percent(m.pct))
        }
        .font(.caption2).monospacedDigit()
        .foregroundStyle(m.pnl >= 0 ? Color.positive : Color.negative)
    }

    private func fieldRow(_ title: String, text: Binding<String>, unit: String, placeholder: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            TextField(placeholder, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().fontWeight(.medium)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Funding

    private var fundingText: String { NumberStyle.percent(Double(market.fundingRatePct100k) / 1_000, fractionDigits: 4) }
    private var fundingTint: Color { market.fundingRatePct100k < 0 ? .negative : market.fundingRatePct100k > 0 ? .positive : .secondary }
    private func countdownText(now date: Date = Date()) -> String {
        let now = date.timeIntervalSince1970
        let secs = 3600 - Int(now.truncatingRemainder(dividingBy: 3600))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    // MARK: Derived values

    private var maxLeverage: Double { max(1, (1 / max(market.initMarginFraction, 0.01)).rounded(.down)) }
    private var minSize: Double { pow(10, -Double(market.lotDecimals)) }
    private func referencePrice(_ type: PriceType) -> Double {
        switch type {
        case .last: return live?.last ?? mark
        case .mid: return live?.mid ?? mark
        }
    }
    private var refPrice: Double { ticket.kind == .limit ? (ticket.priceText.perpDouble ?? mark) : mark }
    private var baseSize: Double { ticket.baseSize(market: market, price: refPrice) }
    private var notional: Double { baseSize * refPrice }
    private var estFee: Double { notional * 0.00069 }
    private var maxNotional: Double { availableMargin * ticket.leverage }
    private var priceStep: Double { pow(10, -Double(market.priceDecimals)) * 10 }
    private var amountStep: Double { ticket.amountUnit == .usd ? 1 : minSize * 10 }

    private var liquidationLong: Double? {
        guard baseSize > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        return PerplService.liquidationPrice(side: .long, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }
    private var liquidationShort: Double? {
        guard baseSize > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        return PerplService.liquidationPrice(side: .short, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }
    private var liquidationPairText: String {
        "\(liquidationLong.map { NumberStyle.number($0) } ?? "—") / \(liquidationShort.map { NumberStyle.number($0) } ?? "—")"
    }

    private var chartLevels: [ChartLevel] {
        var out: [ChartLevel] = []
        if let position {
            out.append(ChartLevel(price: position.entry, colorHex: position.side == .long ? "#1F9E5B" : "#D2483F", title: "Entry"))
            if let liq = position.liquidation, liq > 0 {
                out.append(ChartLevel(price: liq, colorHex: "#F5A623", title: "Liq", dashed: true))
            }
        }
        for order in model.orders where order.perpId == market.id {
            out.append(ChartLevel(price: order.price, colorHex: order.side == .buy ? "#1F9E5B" : "#D2483F",
                                  title: order.reduceOnly ? "Close" : "Limit", dashed: true))
        }
        return out
    }

    @ViewBuilder private var positionBadge: some View {
        if let position {
            let dir = position.side == .long ? 1.0 : -1.0
            let pnl = dir * (mark - position.entry) * position.size + position.premium
            HStack(spacing: 6) {
                Text("\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Text(pnl, format: .currency(code: "USD").sign(strategy: .always()))
                    .foregroundStyle(pnl < 0 ? Color.negative : Color.positive)
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }

    private var availableMargin: Double {
        guard let account = model.account else { return 0 }
        return Amount.units(account.balance - min(account.balance, account.locked), decimals: 6)
    }

    // MARK: Mutations

    private func applyPercent(_ pct: Double) {
        guard refPrice > 0 else { return }
        // The slider owns sizePercent here; skip the amount-field's resync so it doesn't overwrite the live drag value.
        suppressPercentSync = true
        let size = availableMargin * (pct / 100) * ticket.leverage / refPrice
        let stepped = (size * pow(10, Double(market.lotDecimals))).rounded(.down) / pow(10, Double(market.lotDecimals))
        guard stepped > 0 else { ticket.sizeText = ""; return }
        ticket.sizeText = ticket.amountUnit == .usd ? plainSize(stepped * refPrice) : plainSize(stepped)
        ticketError = nil
    }

    /// Recomputes the size slider's percentage from the currently-entered size, so typing an amount, tapping the +/-
    /// steppers, or switching the size unit keeps the slider honest. Exact inverse of `applyPercent`.
    private func syncPercentFromSize() {
        guard availableMargin > 0, refPrice > 0, baseSize > 0 else { sizePercent = 0; return }
        sizePercent = min(100, notional / max(ticket.leverage, 1) / availableMargin * 100)
    }

    /// Keeps the entered size within the newly-chosen leverage's affordable notional after a leverage change.
    private func clampSizeToMargin() {
        guard sizePercent > 0 else { return }
        applyPercent(sizePercent)
    }

    private func convertAmount(to unit: OrderTicket.AmountUnit) {
        let base = ticket.baseSize(market: market, price: refPrice)
        ticket.amountUnit = unit
        guard base > 0, refPrice > 0 else { return }
        ticket.sizeText = unit == .usd ? plainSize(base * refPrice) : plainSize(base)
    }

    private func adjustAmount(_ delta: Double) {
        Haptics.selection()
        let current = ticket.sizeText.perpDouble ?? 0
        let next = max(0, current + delta)
        ticket.sizeText = next == 0 ? "" : plainSize(next)
        ticketError = nil
    }

    private func adjust(_ text: Binding<String>, by delta: Double) {
        Haptics.selection()
        let current = text.wrappedValue.perpDouble ?? mark
        let next = max(0, current + delta)
        text.wrappedValue = plainSize(next)
    }

    private func plainSize(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = max(market.priceDecimals, market.lotDecimals, 2)
        f.minimumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? String(value)
    }

    private func loadCandles(showSpinner: Bool = true) async {
        if showSpinner { loadingCandles = true }
        let to = Date()
        let from = to.addingTimeInterval(-Double(resolution) * 150)
        let fetched = (try? await env.perpl.candles(marketId: market.id, resolution: resolution, from: from, to: to, priceDecimals: market.priceDecimals)) ?? []
        if !fetched.isEmpty { candles = fetched }
        loadingCandles = false
    }
}

// MARK: - Side order book (compact ladder shown beside the ticket, wide version under the chart)

struct SideOrderBook: View {
    let book: OrderBook
    let mark: Double
    /// Perpl's own mid (falls back to book mid / mark). Rendered as the big centered price between the ladders — using
    /// bestBid there duplicated the top bid row directly below it.
    var mid: Double? = nil
    var changePct: Double? = nil
    let symbol: String
    let priceDecimals: Int
    var rows: Int = 8
    var wide: Bool = false

    /// Tick-size grouping (wide book only). 0 = raw; higher indices aggregate price levels so a deep book reads at a
    /// glance. @State resets to raw when the market changes, since the whole trade view is rebuilt with `.id(market.id)`.
    @State private var groupIndex = 0

    private var midTint: Color { (changePct ?? 0) < 0 ? .negative : .positive }
    private var centerPrice: Double {
        if let mid { return mid }
        if let b = book.bestBid, let a = book.bestAsk { return (a + b) / 2 }
        return book.bestBid ?? mark
    }
    private var tick: Double { pow(10, -Double(priceDecimals)) }
    private let groupMultipliers = [1, 10, 100]
    private var groupMultiplier: Int { groupMultipliers[min(groupIndex, groupMultipliers.count - 1)] }
    private var group: Double { tick * Double(groupMultiplier) }

    var body: some View {
        VStack(alignment: .leading, spacing: wide ? 3 : 2) {
            HStack(spacing: 6) {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                if wide {
                    Menu {
                        ForEach(groupMultipliers.indices, id: \.self) { i in
                            Button(NumberStyle.number(tick * Double(groupMultipliers[i]))) { Haptics.selection(); groupIndex = i }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(NumberStyle.number(group)).font(.caption2.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.brand)
                    }
                    .accessibilityLabel("Price grouping \(NumberStyle.number(group))")
                }
                Spacer()
                Text("Total (\(symbol))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if book.isEmpty {
                Text("Waiting for the book…").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                let asks = cumulative(Array(aggregated(book.asks, up: true).prefix(rows)))   // ascending, cumulative from mid
                let bids = cumulative(Array(aggregated(book.bids, up: false).prefix(rows)))
                let maxTotal = max(asks.map(\.total).max() ?? 1, bids.map(\.total).max() ?? 1)

                ForEach(asks.reversed(), id: \.price) { level in
                    bookRow(level, tint: .negative, maxTotal: maxTotal)
                }

                HStack(spacing: 6) {
                    Text(NumberStyle.number(centerPrice))
                        .font((wide ? Font.headline : Font.subheadline).weight(.bold)).monospacedDigit()
                        .foregroundStyle(midTint)
                    if wide, let spread = book.spread {
                        Spacer()
                        Text("Spread \(NumberStyle.number(spread))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, wide ? 6 : 4)

                ForEach(bids, id: \.price) { level in
                    bookRow(level, tint: .positive, maxTotal: maxTotal)
                }

                ratioBar
            }
        }
    }

    private struct Level { let price: Double; let total: Double }

    /// Aggregates raw book levels into the current tick group (passthrough when grouping is 1×). Asks round up, bids
    /// round down, so every bucket stays on the correct side of the spread.
    private func aggregated(_ levels: [BookLevel], up: Bool) -> [(price: Double, size: Double)] {
        guard groupMultiplier > 1 else { return levels.map { (price: $0.price, size: $0.size) } }
        var buckets: [Double: Double] = [:]
        for l in levels {
            let key = (up ? (l.price / group).rounded(.up) : (l.price / group).rounded(.down)) * group
            buckets[key, default: 0] += l.size
        }
        return buckets.map { (price: $0.key, size: $0.value) }.sorted { up ? $0.price < $1.price : $0.price > $1.price }
    }

    private func cumulative(_ levels: [(price: Double, size: Double)]) -> [Level] {
        var running = 0.0
        return levels.map { running += $0.size; return Level(price: $0.price, total: running) }
    }

    private func bookRow(_ level: Level, tint: Color, maxTotal: Double) -> some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().fill(tint.opacity(0.16))
                    .frame(width: geo.size.width * min(1, level.total / maxTotal))
            }
            HStack {
                Text(NumberStyle.number(level.price)).font(.caption.monospacedDigit()).foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(NumberStyle.number(level.total, compact: true)).font(.caption.monospacedDigit()).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: wide ? 22 : 19)
    }

    private var ratioBar: some View {
        let buy = book.bidShare
        return VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(Color.positive).frame(width: max(2, geo.size.width * buy - 1.5))
                    Capsule().fill(Color.negative)
                }
            }
            .frame(height: 4)
            HStack {
                Text(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false)).foregroundStyle(.positive)
                Spacer()
                Text(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false)).foregroundStyle(.negative)
            }
            .font(.caption2.weight(.medium)).monospacedDigit()
        }
        .padding(.top, 6)
    }
}

// MARK: - Percent-of-margin size slider

/// A track with five stops (0/25/50/75/100 %) and a draggable brand thumb, the size control from the reference perp
/// screens. Dragging fires a selection haptic when it crosses a stop and reports the live percentage so the ticket's
/// amount recalculates from available margin × leverage.
struct PercentSizeSlider: View {
    @Binding var percent: Double
    var onChange: (Double) -> Void

    private let stops = [0.0, 25, 50, 75, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Int(percent.rounded()))%")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(percent > 0 ? Color.brand : Color.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * CGFloat(percent / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 3)
                    Capsule().fill(Color.brand).frame(width: max(0, x), height: 3)
                    ForEach(stops, id: \.self) { stop in
                        Circle()
                            .fill(percent >= stop - 0.01 ? Color.brand : Color(.systemBackground))
                            .overlay(Circle().stroke(percent >= stop - 0.01 ? Color.brand : Color(.systemFill), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(x: w * CGFloat(stop / 100), y: geo.size.height / 2)
                    }
                    Circle().fill(Color.brand)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .position(x: min(max(9, x), w - 9), y: geo.size.height / 2)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = Double(min(max(0, value.location.x / w), 1)) * 100
                            let previousStop = nearestStop(percent)
                            percent = pct
                            if nearestStop(pct) != previousStop { Haptics.selection() }
                            onChange(pct)
                        }
                        .onEnded { _ in
                            // Snap to the nearest stop for a clean resting value.
                            let snapped = nearestStop(percent)
                            withAnimation(.easeOut(duration: 0.15)) { percent = snapped }
                            onChange(snapped)
                        }
                )
            }
            .frame(height: 22)
        }
    }

    private func nearestStop(_ pct: Double) -> Double {
        stops.min(by: { abs($0 - pct) < abs($1 - pct) }) ?? 0
    }
}

// MARK: - Adjust Leverage sheet

/// A focused leverage picker: a ruler you drag, integer quick-picks, and a Confirm that applies the choice. The ruler
/// ticks a selection haptic at every whole leverage as you drag, and the value pill tracks your finger — the tactile
/// "changing leverage" feel of a native trading app.
struct LeverageSheet: View {
    let leverage: Double
    let maxLeverage: Double
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double

    init(leverage: Double, maxLeverage: Double, onConfirm: @escaping (Double) -> Void) {
        self.leverage = leverage
        self.maxLeverage = maxLeverage
        self.onConfirm = onConfirm
        _value = State(initialValue: leverage)
    }

    private var rounded: Double { value.rounded() }
    private var changed: Bool { Int(rounded) != Int(leverage.rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Adjust Leverage").font(.title2.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.top, 22).padding(.horizontal, 22)

            LeverageRuler(value: $value, range: 1...max(2, maxLeverage))
                .frame(height: 104)
                .padding(.top, 28).padding(.horizontal, 20)
                .clipped()

            HStack(spacing: 12) {
                ForEach(quickPicks, id: \.self) { pick in
                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.2)) { value = Double(pick) }
                    } label: {
                        Text(pick == Int(maxLeverage) ? "Max" : "\(pick)x")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Int(rounded) == pick ? Color.brand.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(Int(rounded) == pick ? Color.brand : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 30).padding(.horizontal, 20)

            Button {
                Haptics.commit(); onConfirm(rounded); dismiss()
            } label: {
                Text("Confirm")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24).padding(.horizontal, 20)

            Spacer(minLength: 12)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }

    private var quickPicks: [Int] {
        [2, 5, 10, Int(maxLeverage)].filter { $0 <= Int(maxLeverage) }.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// A scrolling leverage ruler, the way the reference perp apps do it: a fixed brand indicator at the centre with the
/// current value pinned above and below it, while the whole tick strip + integer labels SLIDE horizontally under your
/// finger. You read the leverage where the ruler meets the centre line — the number stays put, the *ruler* moves.
struct LeverageRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Points per 1× — sets tick density and how many integers are visible at once (~7 across a phone width).
    private let pointsPerUnit: CGFloat = 50
    private let minorEvery = 0.2

    // Vertical layout. Each integer label morphs between the row baseline and the raised position as it nears the
    // centre: the nearest number rises to `topY` and enlarges to `bigSize` to BECOME the leverage value; the rest sit
    // small at `rowY`. There is no separate big readout — that was the duplicated number.
    private let topY: CGFloat = 15
    private let rowY: CGFloat = 47
    private let tickTop: CGFloat = 70
    private let majorTick: CGFloat = 24
    private let minorTick: CGFloat = 11
    private let rowSize: CGFloat = 15
    private let bigSize: CGFloat = 27

    private var lo: Double { range.lowerBound }
    private var hi: Double { range.upperBound }

    /// The leverage the current drag began at, so a finger translation maps to an absolute value.
    @State private var dragAnchor: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let center = w / 2
            let visibleUnits = Double(center / pointsPerUnit) + 1
            let firstInt = max(Int(lo.rounded(.up)), Int((value - visibleUnits).rounded(.down)))
            let lastInt = min(Int(hi.rounded(.down)), Int((value + visibleUnits).rounded(.up)))

            ZStack {
                // Tick strip — every tick is placed by its offset from the centred value, so the whole strip slides as
                // `value` changes. Whole numbers get a tall tick; sub-integer steps a short one.
                Canvas { ctx, size in
                    let ctr = size.width / 2
                    let half = Double(ctr / pointsPerUnit) + 1
                    var v = ((value - half) / minorEvery).rounded(.down) * minorEvery
                    let end = min(hi, value + half) + 0.0001
                    while v <= end {
                        if v >= lo - 0.0001 {
                            let x = ctr + CGFloat(v - value) * pointsPerUnit
                            let isWhole = abs(v.rounded() - v) < 0.001
                            let h = isWhole ? majorTick : minorTick
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: tickTop))
                            path.addLine(to: CGPoint(x: x, y: tickTop + h))
                            ctx.stroke(path, with: .color(Color(.tertiaryLabel).opacity(isWhole ? 0.85 : 0.4)), lineWidth: isWhole ? 1.4 : 1)
                        }
                        v += minorEvery
                    }
                }

                // Integer labels. Each stays at its own value-position (so the strip scrolls) while its size and height
                // interpolate by nearness to the centre: the closest number rises and grows to become the leverage
                // value, its neighbours shrink back into the row. One copy of each number — the raised one IS the value.
                if firstInt <= lastInt {
                    ForEach(firstInt...lastInt, id: \.self) { i in
                        let dist = abs(Double(i) - value)          // distance from the centred value, in leverage units
                        let p = max(0, 1 - dist)
                        let prox = p * p * (3 - 2 * p)              // smoothstep, so the nearest number pops cleanly
                        Text("\(i)X")
                            .font(.system(size: rowSize + (bigSize - rowSize) * prox, weight: prox > 0.55 ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.4 + 0.6 * prox))
                            .fixedSize()
                            .position(x: center + CGFloat(Double(i) - value) * pointsPerUnit,
                                      y: rowY - (rowY - topY) * prox)
                    }
                }

                // Fixed centre — brand indicator line and the value pill (the precise, possibly-fractional value).
                Rectangle().fill(Color.brand).frame(width: 2.5, height: 70)
                    .position(x: center, y: 58)
                Text("\(NumberStyle.number(value, maximumFractionDigits: 1))x")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.brand, in: Capsule())
                    .fixedSize()
                    .position(x: center, y: tickTop)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragAnchor == nil { dragAnchor = value }
                        let anchor = dragAnchor ?? value
                        let previous = Int(value.rounded())
                        // Scroll convention: dragging right pulls lower values to the centre (the strip follows the finger).
                        value = min(max(lo, anchor - Double(g.translation.width) / Double(pointsPerUnit)), hi)
                        if Int(value.rounded()) != previous { Haptics.selection() }
                    }
                    .onEnded { _ in
                        dragAnchor = nil
                        withAnimation(.easeOut(duration: 0.16)) { value = min(max(lo, value.rounded()), hi) }
                    }
            )
        }
    }
}

// MARK: - Order Type sheet

struct OrderTypeSheet: View {
    let kind: OrderKind
    let onSelect: (OrderKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Order Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.market, icon: "bolt.fill", title: "Market", subtitle: "Execute immediately at current price")
                optionRow(.limit, icon: "chart.line.uptrend.xyaxis", title: "Limit", subtitle: "Set a specific price for your order")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: OrderKind, icon: String, title: String, subtitle: String) -> some View {
        let selected = kind == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.brand : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(selected ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unit Preference sheet

struct UnitPreferenceSheet: View {
    let unit: OrderTicket.AmountUnit
    let asset: String
    let onSelect: (OrderTicket.AmountUnit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Unit Preference") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.asset, symbol: asset, title: asset, subtitle: "Order size is denominated in \(asset), the base asset.")
                optionRow(.usd, symbol: "AUSD", title: "AUSD", subtitle: "Order size is calculated from an AUSD amount at the current price.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: OrderTicket.AmountUnit, symbol: String, title: String, subtitle: String) -> some View {
        let selected = unit == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                TokenLogo(symbol: symbol, url: nil, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Color.brand : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Price Type sheet

struct PriceTypeSheet: View {
    let selected: PerpTradeView.PriceType
    let onSelect: (PerpTradeView.PriceType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Price Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.last, title: "Last Traded Price", subtitle: "Fill the limit price with the last trade.")
                optionRow(.mid, title: "Mid Price", subtitle: "Fill the limit price with the mid of the book.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: PerpTradeView.PriceType, title: String, subtitle: String) -> some View {
        let isSel = selected == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSel { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(isSel ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Select Perpetual sheet

struct SelectPerpetualSheet: View {
    let markets: [PerpMarket]
    let currentId: Int
    let change: (PerpMarket) -> Double?
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PerpMarket] {
        guard !query.isEmpty else { return markets }
        let q = query.lowercased()
        return markets.filter { $0.asset.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Select Perpetual") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search…", text: $query).autocorrectionDisabled().textInputAutocapitalization(.characters)
            }
            .font(.body)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .padding(.horizontal, 20).padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { market in
                        Button {
                            Haptics.selection(); onSelect(market.id); dismiss()
                        } label: { marketRow(market) }
                        .buttonStyle(.plain)
                        if market.id != filtered.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private func marketRow(_ market: PerpMarket) -> some View {
        let selected = market.id == currentId
        return HStack(spacing: 12) {
            TokenLogo(symbol: market.asset, url: nil, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(market.asset).font(.body.weight(.bold))
                Text(market.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(market.mark.formatted(.currency(code: "USD").precision(.fractionLength(market.mark < 1 ? 4 : 2))))
                    .font(.body.weight(.semibold)).monospacedDigit()
                ChangeText(value: change(market), style: .caption)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(selected ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Shared sheet header: a bold title on the left and a round close button on the right.
private func sheetHeader(_ title: String, onClose: @escaping () -> Void) -> some View {
    HStack {
        Text(title).font(.title2.weight(.bold))
        Spacer()
        Button(action: onClose) {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
    .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 8)
}

// MARK: - Trades tape

struct TradesTape: View {
    let trades: [PerpTrade]
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size (\(symbol))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Time").font(.caption2).foregroundStyle(.secondary)
            }
            if trades.isEmpty {
                Text("Waiting for trades…").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ForEach(trades.prefix(18)) { trade in
                    HStack {
                        Text(NumberStyle.number(trade.price)).font(.caption.monospacedDigit()).foregroundStyle(trade.side == .buy ? Color.positive : Color.negative)
                        Spacer()
                        Text(NumberStyle.number(trade.size, maximumFractionDigits: 4)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(trade.time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: 18)
                }
            }
        }
    }
}

// MARK: - Position & order cards

private struct PositionCard: View {
    let position: PerpPosition
    let liveMark: Double
    let onClose: () -> Void
    let onAddMargin: () -> Void

    private var livePnl: Double {
        let dir = position.side == .long ? 1.0 : -1.0
        return dir * (liveMark - position.entry) * position.size + position.premium
    }
    private var pnlPct: Double? { position.margin > 0 ? livePnl / position.margin * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(livePnl, format: .currency(code: "USD").sign(strategy: .always()))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let pnlPct {
                        Text(pnlPct, format: .number.precision(.fractionLength(2)).sign(strategy: .always())) + Text("%")
                    }
                }
                .foregroundStyle(livePnl < 0 ? Color.negative : Color.positive)
                .font(.caption.monospacedDigit())
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                stat("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
                stat("Entry", NumberStyle.number(position.entry))
                stat("Mark", NumberStyle.number(liveMark > 0 ? liveMark : position.mark))
                stat("Margin", position.margin.formatted(.currency(code: "USD")))
                stat("Liq.", position.liquidation.map { NumberStyle.number($0) } ?? "—")
                stat("Notional", position.notional.formatted(.currency(code: "USD")))
            }
            HStack(spacing: 8) {
                Button("Add Margin", action: onAddMargin)
                    .buttonStyle(.bordered).controlSize(.small).tint(.brand)
                Button("Close", action: onClose)
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

private struct OrderCard: View {
    let order: PerpOrder
    let onCancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(order.side == .buy ? "Buy" : "Sell") \(NumberStyle.number(order.size)) \(order.symbol)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(order.side == .buy ? Color.positive : Color.negative)
                Text("Limit \(NumberStyle.number(order.price))\(order.reduceOnly ? " · reduce-only" : "")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small).tint(.negative)
        }
        .padding(.vertical, 4)
    }
}

/// Closes a position at market or with a resting reduce-only limit order (optionally post-only).
private struct ClosePositionSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let mark: Double
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var kind: OrderKind = .market
    @State private var limitText = ""
    @State private var postOnly = false

    private var isLimit: Bool { kind == .limit }
    private var limitPrice: Double? { limitText.perpDouble }
    private var canConfirm: Bool { session.canSign && !run.isRunning && (!isLimit || (limitPrice ?? 0) > 0) }

    private var steps: [TransactionStep] {
        env.perpl.closePositionPlan(market: market, position: position, slippageBps: 100, kind: kind, limitPrice: limitPrice, postOnly: postOnly)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", "\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.size)) \(position.symbol)", tint: position.side == .long ? .positive : .negative)
                    DetailRow("Mark price", NumberStyle.number(mark))
                    DetailRow("Unrealized", position.unrealized.formatted(.currency(code: "USD").sign(strategy: .always())), tint: position.unrealized < 0 ? .negative : .positive)
                }
                Section("Close order") {
                    Picker("Type", selection: $kind) {
                        Text("Market").tag(OrderKind.market)
                        Text("Limit").tag(OrderKind.limit)
                    }
                    .pickerStyle(.segmented)
                    if isLimit {
                        HStack {
                            Text("Limit price").foregroundStyle(.secondary)
                            Spacer()
                            TextField(NumberStyle.number(mark), text: $limitText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                        }
                        Toggle("Post only (maker)", isOn: $postOnly)
                        Text("Rests as a reduce-only limit at your price until it fills. It won't reduce your position until then.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DetailRow("Order", "Market, reduce-only, 1% slippage")
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events) } }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Close Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.isDone ? "Done" : "Cancel") { finish() }.disabled(run.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if !session.canSign {
                        Text(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        PrimaryButton(title: isLimit ? "Place Limit Close" : "Close at Market", isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.requireBiometrics, !(await BiometricGate.authenticate(reason: "Confirm close")) { return }
                                run.start(steps, session: session, sender: env.sender)
                            }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: run.isDone)
    }

    private func finish() {
        let done = run.isDone
        dismiss()
        if done { onDone() }
    }
}

/// Adds AUSD collateral to an open position — lowering its leverage and pushing the liquidation price away.
private struct AddMarginSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let available: Double
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var amountText = ""

    private var amount: Double { amountText.perpDouble ?? 0 }
    private var overBalance: Bool { amount > available + 0.000001 }
    private var canConfirm: Bool { session.canSign && !run.isRunning && amount > 0 && !overBalance }

    private var projMargin: Double { position.margin + max(0, amount) }
    private var projLeverage: Double { projMargin > 0 ? position.notional / projMargin : position.leverage }
    private var projLiquidation: Double? {
        PerplService.liquidationPrice(side: position.side, entry: position.entry, size: position.size, margin: projMargin, premium: position.premium, maintenanceFraction: market.maintMarginFraction)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", "\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.size)) \(position.symbol)", tint: position.side == .long ? .positive : .negative)
                    DetailRow("Current margin", position.margin.formatted(.currency(code: "USD")))
                    DetailRow("Available", available.formatted(.currency(code: "USD")))
                }
                Section("Add margin") {
                    HStack {
                        Text("Amount").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                        Text("AUSD").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach([0.25, 0.5, 1.0], id: \.self) { frac in
                            Button(frac == 1.0 ? "Max" : "\(Int(frac * 100))%") { amountText = plainAmount(available * frac) }
                                .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                        }
                    }
                    if overBalance { Text("More than your available balance.").font(.caption).foregroundStyle(.negative) }
                }
                if amount > 0, !overBalance {
                    Section("After") {
                        DetailRow("Margin", projMargin.formatted(.currency(code: "USD")))
                        DetailRow("Leverage", "\(NumberStyle.number(projLeverage, maximumFractionDigits: 1))×")
                        DetailRow("Liq. price", projLiquidation.map { NumberStyle.number($0) } ?? "—")
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events) } }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Margin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.isDone ? "Done" : "Cancel") { finish() }.disabled(run.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if !session.canSign {
                        Text(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        PrimaryButton(title: "Add Margin", isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.requireBiometrics, !(await BiometricGate.authenticate(reason: "Confirm add margin")) { return }
                                run.start(env.perpl.addMarginPlan(market: market, amount: amount), session: session, sender: env.sender)
                            }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: run.isDone)
    }

    private func plainAmount(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private func finish() {
        let done = run.isDone
        dismiss()
        if done { onDone() }
    }
}

/// Confirms and places an order through the authenticated Perpl trading connection (entry + optional TP/SL).
struct AuthedOrderSheet: View {
    let market: PerpMarket
    let input: OrderInput
    let takeProfit: Double?
    let stopLoss: Double?
    let accountId: Int
    let sideColor: Color
    let summaryMargin: Double
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review

    enum Phase: Equatable { case review, placing, done, failed(String) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Market", "\(market.asset)-PERP")
                    DetailRow("Side", input.side == .long ? "Long" : "Short", tint: sideColor)
                    DetailRow("Type", input.kind == .market ? "Market · \(NumberStyle.basisPoints(input.slippageBps)) slippage" : "Limit at \(NumberStyle.number(input.price ?? market.mark))")
                    DetailRow("Size", "\(NumberStyle.number(input.size)) \(market.asset)")
                    DetailRow("Leverage", "\(NumberStyle.number(input.leverage, maximumFractionDigits: 1))×")
                    DetailRow("Margin", summaryMargin.formatted(.currency(code: "USD")))
                    if let takeProfit { DetailRow("Take profit", NumberStyle.number(takeProfit), tint: .positive) }
                    if let stopLoss { DetailRow("Stop loss", NumberStyle.number(stopLoss), tint: .negative) }
                } header: {
                    Text("Review Order · Perpl")
                } footer: {
                    Text("Signed and forwarded by your Perpl API key over the trading connection.")
                }
                if case .failed(let message) = phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
                if phase == .done {
                    Section { Label("Order sent to Perpl.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Place Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Done" : "Cancel") { let done = phase == .done; dismiss(); if done { onDone() } }
                        .disabled(phase == .placing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if phase != .done {
                    PrimaryButton(title: input.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", isBusy: phase == .placing, foreground: .onStatus) {
                        Task { await place() }
                    }
                    .tint(sideColor)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .interactiveDismissDisabled(phase == .placing)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: phase == .done)
    }

    private func place() async {
        phase = .placing
        do {
            let ack = try await perplTrading.submit(input: input, accountId: accountId, takeProfit: takeProfit, stopLoss: stopLoss, env: env)
            phase = ack.accepted ? .done : .failed(ack.error ?? "Perpl rejected the order.")
            if ack.accepted {
                ActivityLog.record(ActivityRecord(kind: .perp, title: "\(input.side == .long ? "Long" : "Short") \(market.asset)-PERP", subtitle: "\(NumberStyle.number(input.size)) \(market.asset)\(input.kind == .market ? " · Market" : " · Limit")", hash: nil, usd: input.size * market.mark > 0 ? input.size * market.mark : nil), owner: session.address)
                if settings.notificationsEnabled, settings.notifyFills {
                    Notifications.perpOrder(side: input.side == .long ? "Long" : "Short", market: "\(market.asset)-PERP", filled: input.kind == .market)
                }
            }
        } catch {
            phase = .failed(describe(error))
        }
    }
}

// MARK: - Order ticket state

struct OrderTicket {
    enum AmountUnit { case asset, usd }
    var side: PositionSide = .long
    var kind: OrderKind = .market
    var sizeText = ""
    var priceText = ""
    var leverage: Double = 2
    var reduceOnly = false
    var postOnly = false
    var maxSlippageEnabled = false
    var slippageBps = 50
    var tpslEnabled = false
    var takeProfitText = ""
    var stopLossText = ""
    var amountUnit: AmountUnit = .asset

    /// Reduce-Only / Post-Only are Limit-only flags; a Market order must never carry them (it would change the order's
    /// meaning and, for reduceOnly, skip the margin guard below). This is the single source of truth — even if a stale
    /// flag survives a mode switch, the effective value here is always false for a market order.
    var effectiveReduceOnly: Bool { kind == .limit && reduceOnly }
    var effectivePostOnly: Bool { kind == .limit && postOnly }

    func baseSize(market: PerpMarket, price: Double) -> Double {
        let typed = sizeText.perpDouble ?? 0
        guard typed > 0, price > 0 else { return 0 }
        let raw = amountUnit == .usd ? typed / price : typed
        let scale = pow(10, Double(market.lotDecimals))
        return (raw * scale).rounded(.down) / scale
    }

    func problem(market: PerpMarket, account: PerpAccount?, available: Double) -> String? {
        let price = kind == .limit ? (priceText.perpDouble ?? market.mark) : market.mark
        let size = baseSize(market: market, price: price)
        guard size > 0 else { return amountUnit == .usd ? "Enter an amount in AUSD." : "Enter a size in \(market.asset)." }
        if kind == .limit, (priceText.perpDouble ?? 0) <= 0 { return "Enter a limit price." }
        if account == nil, !effectiveReduceOnly { return "Deposit AUSD to open a trading account first." }
        if account != nil, !effectiveReduceOnly {
            if size * price / max(leverage, 1) > available * 1.0001 { return "Not enough available margin." }
        }
        return nil
    }

    func input(market: PerpMarket, refPrice: Double) -> OrderInput {
        OrderInput(market: market, side: side, kind: kind, size: baseSize(market: market, price: refPrice), price: kind == .limit ? priceText.perpDouble : nil, leverage: leverage, reduceOnly: effectiveReduceOnly, slippageBps: slippageBps, postOnly: effectivePostOnly)
    }
}

extension String {
    /// Parses a user-typed decimal. The decimal pad shows the locale separator ("," across much of Europe/LatAm) but
    /// our own writers (`plainSize`) emit POSIX "." — so try the fast POSIX path first, then normalize the locale's
    /// grouping/decimal separators. Purely additive: en_US "." input still parses via `Double(_:)` unchanged.
    var perpDouble: Double? {
        if let d = Double(self) { return d }
        var s = self
        if let g = Locale.current.groupingSeparator, !g.isEmpty { s = s.replacingOccurrences(of: g, with: "") }
        if let dec = Locale.current.decimalSeparator, dec != "." { s = s.replacingOccurrences(of: dec, with: ".") }
        return Double(s)
    }
}
