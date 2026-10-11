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
    /// The timeframe `candles` belong to: another timeframe's candles are never shown under this one's name (RS-10).
    @State private var candlesResolution: Int?
    /// The last candle read failed: the chart says so rather than "no history".
    @State private var candlesFailed = false
    /// The candles the chart draws: the selected timeframe's only, so a switch shows the spinner, not the old ones.
    private var shownCandles: [PerpCandle] { candlesResolution == resolution ? candles : [] }
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
    /// Which path the open order confirmation uses, fixed when Long/Short is tapped: non-nil is the one-click
    /// (keeper-forwarded) path for that Perpl account, nil the on-chain path. The socket's status changes in the
    /// background (keep-alive, reconnects, drops), and re-deciding inside the sheet would swap a sheet with an order in
    /// flight for a fresh one with an enabled button — a second order (security audit 2026-09-26).
    @State private var authedOrderAccount: Int?
    /// The order as it stood when Review was tapped: the review renders it and the plan signs it, so a mark that moves
    /// under an open review (a USD-sized order re-derives its size from the price) can't change one without the other.
    @State private var reviewInput: OrderInput?
    /// The side of the position the order under review closes, as the account held it when Review was tapped
    /// (`PerpCloseOrder.closes`): a reduce-only order, or one on the other side of the position, which Perpl nets against
    /// it. Noted once the order is sent, so its ending is not reported as a close from elsewhere.
    @State private var reviewCloses: PositionSide?
    /// The live outcome switch as it stood at the tap (`PerplTrading.liveOutcomes`), fixed with the path: an order keeps
    /// the mode of its tap.
    @State private var reviewLive = false
    /// This market's position at the tap and when it was read, and whether an order that can grow the same side rested
    /// here then: what the order's result is compared with if Perpl's own report never comes.
    @State private var reviewHeld: PerpPosition?
    @State private var reviewReadAt: Date?
    @State private var reviewRestingOnSide = false
    /// The wallet-signed order under review: its id from the moment it is signed (`onStarted`), which its result is
    /// followed under once its transaction confirms, and the desc id its plan signs (what finds it in the receipt).
    @State private var onChainOrder: UUID?
    @State private var planDescId: UInt64?
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
    /// The path Close / Add Margin take, fixed at the tap that opens the sheet (p4 spec A.2): the account they go over the
    /// trading connection for, or nil for the wallet transaction. Never switched afterwards.
    @State private var closeRoute: PerplTrading.ActionAccount?
    @State private var marginRoute: PerplTrading.ActionAccount?
    /// The resting order a Cancel tap goes to Perpl's API for, fixed at the tap: the stream's order the chain's matches by
    /// its smart contract order id, the request it belonged to then, and the account — nil target: the wallet's cancel.
    @State private var cancelTarget: PerplOpenOrder?
    @State private var cancelTapRq: Int?
    @State private var cancelAccount: PerplTrading.ActionAccount?
    @State private var editingTriggers: PerpPosition?
    @State private var cancellingTriggers: TriggerCancelRequest?

    @State private var fills: [PerplFill] = []
    @State private var pnlByOrder: [Int: Double] = [:]
    @State private var loadingFills = false
    @State private var fillsError: String?

    // The raw values are identifiers; each tab's name on screen is its `title`.
    enum ViewMode: String, CaseIterable, Identifiable { case chart = "Chart", trade = "Trade"; var id: String { rawValue } } // not localized: identifiers
    enum ChartDataTab: String, CaseIterable, Identifiable {
        case book = "Order Book", trades = "Trades" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .book: Text("Order Book", comment: "A tab under the chart: the market's bids and asks. [tight]")
            case .trades: Text("Trades", comment: "Trades: a tab under the Perps chart with the market's latest trades, and a count of trades on Portfolio [tight]")
            }
        }
    }
    enum BottomTab: String, CaseIterable, Identifiable {
        case positions = "Positions", orders = "Orders", assets = "Assets", history = "Trade History" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .positions: Text("Positions", comment: "A tab of the Perps screen: the open positions. [tight]")
            case .orders: Text("Orders", comment: "A tab of the Perps screen: the open orders. [tight]")
            case .assets: Text("Assets", comment: "A tab: in My Holdings the tokens held, on Perps the trading account's balance [tight]")
            case .history: Text("Trade History", comment: "A tab of the Perps screen: this market's past trades. [tight]")
            }
        }
    }
    enum PriceType: String, CaseIterable, Identifiable {
        case last = "Last", mid = "Mid" // not localized: identifiers
        var id: String { rawValue }
        var title: Text {
            switch self {
            case .last: Text("Last", comment: "The price a limit order starts from: the last traded price. [tight]")
            case .mid: Text("Mid", comment: "The price a limit order starts from: the middle of the order book. [tight]")
            }
        }
    }

    private var position: PerpPosition? { model.positions.first { $0.perpId == market.id } }

    /// The account this screen acts for, at the tap.
    private var actionAccount: PerplTrading.ActionAccount? {
        guard session.canSign, let id = model.account?.accountId else { return nil }
        return .init(owner: session.address, accountId: id, passkey: session.isPasskeyAccount)
    }

    /// The API route for Close / Add Margin (nil: the wallet transaction, as before). Decided at the tap that opens the sheet.
    private var apiRoute: PerplTrading.ActionAccount? {
        guard let account = actionAccount else { return nil }
        return perplTrading.apiActionsLive(for: account) || perplTrading.apiActionsAfterUnlock(for: account) ? account : nil
    }
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
        .task(id: session.address) {
            perplTrading.refresh(account: session.account)
            // The user already connected Perpl trading in Profile; the single trading socket just idles to `.enrolled`
            // between visits. Bring it live up front (in the background, so it never blocks history) so `isReady` is
            // true and TP/SL is actually offered — instead of showing "Connect Perpl trading in Profile" to someone
            // who already did. ensureConnected() is a no-op when already live and respects backoff / a rejected key.
            Task { await perplTrading.ensureConnected() }
            await loadFills()
        }
        .onChange(of: ticket.tpslEnabled) { _, on in
            guard on else { return }
            // TP/SL and Reduce Only exclude each other (security audit GT-6): a reduce-only order's triggers would close
            // the side the account doesn't hold.
            ticket.reduceOnly = false
            Task { await perplTrading.ensureConnected() }
        }
        .onChange(of: ticket.reduceOnly) { _, on in if on { ticket.tpslEnabled = false } }
        .onChange(of: bottomTab) { _, tab in if tab == .history { Task { await loadFills() } } }
        .onChange(of: model.fillSignal) { _, _ in if model.lastFilledPerpId == market.id { Task { await loadFills() } } }
        .sheet(isPresented: $showConfirm, onDismiss: {
            reviewInput = nil; reviewCloses = nil
            // A wallet-signed order's sheet closed: its result shows on the status row from now on (or, never confirmed,
            // it expects no fill any more).
            if let id = onChainOrder { perplTrading.onChainSheetClosed(id) }
        }) { orderConfirmSheet }
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
            ClosePositionSheet(market: market, position: position, mark: mark, accountId: model.account?.accountId, leftoverTriggers: triggersProtecting(position),
                               route: closeRoute,
                               onSending: { whole in if whole { model.noteUserClose(market.id, closing: position.side) } }, onNotSent: { model.forgetUserClose(market.id) },
                               onSettled: { Task { await model.reloadSoon(env: env, address: session.address) } }) {
                Task { await model.load(env: env, address: session.address) }
            }
        }
        .sheet(item: $addingMargin) { position in
            AddMarginSheet(market: market, position: position, available: availableMargin, accountId: model.account?.accountId, route: marginRoute,
                           onSettled: { Task { await model.reloadSoon(env: env, address: session.address) } }) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $cancellingOrder) { order in
            // The path of the tap: Perpl's API for the stream order it matched, else the wallet's cancel as before.
            if let target = cancelTarget, let account = cancelAccount {
                CancelOrderSheet(market: market, order: order, target: target, tapRq: cancelTapRq, account: account) {
                    Task { await model.load(env: env, address: session.address) }
                }
            } else {
                cancelOrderSheet(order)
            }
        }
        .sheet(item: $editingTriggers) { position in
            PositionTriggersSheet(market: market, position: position, mark: mark) { Task { await model.load(env: env, address: session.address) } }
        }
        .sheet(item: $cancellingTriggers) { request in
            CancelTriggersSheet(market: market, orders: request.orders, title: request.title, note: request.note) { Task { await model.load(env: env, address: session.address) } }
        }
    }

    // MARK: Market header

    private var marketHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Haptics.selection(); showSelect = true
            } label: {
                HStack(spacing: 10) {
                    MarketLogo(symbol: market.asset, url: nil, size: 34)
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
                Text(PriceFormat.usdPrice(abs, signed: true))
            }
            if change24hAbs != nil, change24h != nil { Text(verbatim: "/") }
            if let pct = change24h { Text(NumberStyle.percent(pct)) }
        }
        .font(.footnote.weight(.medium)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7) // one line: a signed dollar figure wrapped after its "−"
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
            TradingViewChart(candles: shownCandles, levels: chartLevels)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The chart is a canvas in a web view: VoiceOver gets a spoken summary instead (security audit AI-10).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(market.asset) price chart")
                .accessibilityValue(chartSummary)
                .overlay(alignment: .topTrailing) { positionBadge }
                .overlay {
                    if shownCandles.isEmpty {
                        if loadingCandles { ProgressView() }
                        else if candlesFailed {
                            ContentUnavailableView { Label("Chart Unavailable", systemImage: "wifi.exclamationmark") } description: { Paragraph("Perpl's candles couldn't be loaded. Retrying every 15 seconds.") }
                        }
                        else {
                            ContentUnavailableView { Label("No Candles", systemImage: "chart.bar.xaxis") } description: { Paragraph("Perpl has no candle history for this market yet.") }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if candlesFailed, !shownCandles.isEmpty {
                        Label("Not updating", systemImage: "wifi.exclamationmark")
                            .font(.caption2.weight(.medium)).foregroundStyle(Color.attention)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            timeframePicker
            Picker("Data", selection: $chartDataTab) {
                ForEach(ChartDataTab.allCases) { $0.title.tag($0) }
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

    /// The chart in words, in the app's language: the period, the last price, the change over the period, and its range.
    /// The candle count is a plural.
    private var chartSummary: String {
        guard let first = shownCandles.first, let last = shownCandles.last else {
            return loadingCandles ? tr("Loading") : candlesFailed ? tr("Couldn't load the chart") : tr("No candle history yet")
        }
        let span = Self.resolutions.first { $0.0 == resolution }?.1 ?? ""
        let high = NumberStyle.number(shownCandles.map(\.high).max() ?? last.high)
        let low = NumberStyle.number(shownCandles.map(\.low).min() ?? last.low)
        let change = first.open > 0 ? (last.close - first.open) / first.open * 100 : 0
        let close = NumberStyle.number(last.close)
        let move = NumberStyle.percent(abs(change), signed: false)
        let count = shownCandles.count
        return change >= 0
            ? tr("\(count) \(span) candles. Last \(close), up \(move) over the period. High \(high), low \(low).")
            : tr("\(count) \(span) candles. Last \(close), down \(move) over the period. High \(high), low \(low).")
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

    /// The chart's timeframes in seconds, each with its label in the app's language (written as trading charts write them).
    static var resolutions: [(Int, String)] {
        [(60, tr(LocalizedStringResource("1m", comment: "Chart timeframe: one minute. [tight]"))),
         (300, tr(LocalizedStringResource("5m", comment: "Chart timeframe: five minutes. [tight]"))),
         (900, tr(LocalizedStringResource("15m", comment: "Chart timeframe: fifteen minutes. [tight]"))),
         (3600, tr(LocalizedStringResource("1h", comment: "Chart timeframe: one hour. [tight]"))),
         (14400, tr(LocalizedStringResource("4h", comment: "Chart timeframe: four hours. [tight]"))),
         (86400, tr(LocalizedStringResource("1D", comment: "Chart timeframe: one day. [tight]")))]
    }

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
            Text("Funding (1h) / Countdown", comment: "Over the funding rate and the time to the next funding, in a narrow column. [tight]")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(fundingText).foregroundStyle(fundingTint)
                Text(verbatim: "/").foregroundStyle(.secondary)
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
                    Text("Isolated", comment: "Isolated margin: Perpl's only margin mode. [tight]").font(.subheadline.weight(.semibold))
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
                    Text(verbatim: "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: ticket.leverage.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))x")
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
                Text(verbatim: "\(NumberStyle.number(availableMargin, maximumFractionDigits: 2)) AUSD")
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
                        (ticket.kind == .market ? Text("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]")
                                                : Text("Limit", comment: "Order type: rests at the price you set until it fills. [tight]")).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                if ticket.kind == .limit {
                    Button { Haptics.selection(); showPriceType = true } label: {
                        priceType.title.font(.subheadline.weight(.semibold))
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
                    if ticket.reduceOnly {
                        Paragraph("TP/SL can't go on a reduce-only order. Set it on the position instead.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if ticket.effectiveTPSL { tpslFields }

            // Summary
            VStack(spacing: 8) {
                // Named in words, not told apart by green and red alone (security audit AI-3): the side isn't chosen
                // until Long or Short is tapped, so both are shown.
                summaryRow("Liq. if long", liquidationLong.map { NumberStyle.number($0) } ?? liquidationFallback, tint: liquidationLong == nil ? nil : .positive)
                summaryRow("Liq. if short", liquidationShort.map { NumberStyle.number($0) } ?? liquidationFallback, tint: liquidationShort == nil ? nil : .negative)
                summaryRow("Max", "\(NumberStyle.number(maxNotional, maximumFractionDigits: 2)) AUSD")
                summaryRow("Fee", "\(NumberStyle.number(estFee, maximumFractionDigits: 2)) AUSD")
            }
            .padding(.top, 2)

            if let ticketError {
                Paragraph(ticketError).font(.caption).foregroundStyle(Color.attention)
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
            TextField("0.5" as String, text: Binding(
                get: { ticket.slippageBps == 0 ? "" : NumberStyle.number(Double(ticket.slippageBps) / 100, maximumFractionDigits: 2) },
                // 0 (the default) to 50%, as the swap slippage sheet: never negative, never past 100%, never a trap.
                set: { ticket.slippageBps = min(5_000, max(0, Int(exactly: (($0.perpDouble ?? 0) * 100).rounded(.towardZero)) ?? 0)) }
            ))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
            .font(.caption.weight(.medium)).frame(width: 60)
            Text(verbatim: "%").font(.caption).foregroundStyle(.secondary)
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
            Paragraph(tpslStatus.text)
                .font(.caption2).foregroundStyle(tpslStatus.warning ? Color.attention : Color.secondary)
        }
    }

    private func checkRow(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
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

    private func summaryRow(_ label: LocalizedStringKey, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Long / Short

    private var longShortButtons: some View {
        VStack(spacing: 10) {
            sideButton(.long, Text("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"), .positive)
            sideButton(.short, Text("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"), .negative)
            if !session.canSign {
                Text("Sign in to trade.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func sideButton(_ side: PositionSide, _ label: Text, _ color: Color) -> some View {
        Button {
            attemptOrder(side)
        } label: {
            label
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
        if let reason = ticket.problem(market: market, mark: mark, account: model.account, available: availableMargin) {
            Haptics.warning(); ticketError = reason; return
        }
        if let reason = triggerProblem(side: side) {
            Haptics.warning(); ticketError = reason; return
        }
        if !ticket.effectiveReduceOnly, let reason = leftoverTriggerProblem(side: side) {
            Haptics.warning(); ticketError = reason; return
        }
        ticketError = nil
        reviewInput = ticket.input(market: market, refPrice: refPrice)
        reviewCloses = PerpCloseOrder.closes(orderSide: side, reduceOnly: ticket.effectiveReduceOnly, held: position?.side)
        Haptics.commit()
        // Use the authenticated path when the socket is live, OR when the wallet has an enrolled key and the user wants
        // TP/SL (`submitBracket` awaits ensureConnected()); otherwise the on-chain path. Decided here, once per
        // confirmation.
        authedOrderAccount = (perplTrading.isReady || (perplTrading.isEnrolled && wantsTriggers)) ? model.account?.accountId : nil
        reviewLive = perplTrading.liveOutcomes
        reviewHeld = position
        reviewReadAt = model.positionsReadAt
        reviewRestingOnSide = model.orders.contains { $0.perpId == market.id && !$0.reduceOnly && ($0.side == .buy) == (side == .long) }
            || perplTrading.openOrders.contains { $0.marketId == market.id && $0.isRestingEntry && ($0.typeRaw == 1) == (side == .long) }
        // A new review: no wallet-signed order of it exists yet.
        onChainOrder = nil
        planDescId = nil
        showConfirm = true
    }

    /// A take-profit must sit on the profit side of the entry and a stop-loss on the loss side for the chosen
    /// direction. A wrong-sided trigger is what the keeper rejects or fires instantly, which would leave the position
    /// unprotected — so block it before placing (and before recording it as if it were live). Also refused (security
    /// audit GT-7, GT-8): a price that isn't a number (it would silently be left off), zero or below one tick (sent as
    /// `tp: 0`, a close that fires at once), off the market's tick, and a stop-loss at or beyond the liquidation price.
    private func triggerProblem(side: PositionSide) -> String? {
        guard ticket.effectiveTPSL else { return nil }
        // An order that only shrinks the position on the other side opens nothing for its triggers to close (GT-6).
        let wantsTriggers = [ticket.takeProfitText, ticket.stopLossText].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if wantsTriggers, let position, PerplTriggerRules.onlyReduces(side: side, size: baseSize, positionSide: position.side, positionSize: position.size) {
            return PerplTriggerRules.Problem.reducesPosition(position.side).message(market: market)
        }
        for (kind, text) in [(PerplTriggerKind.takeProfit, ticket.takeProfitText), (.stopLoss, ticket.stopLossText)] {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let price = text.perpDouble else {
                return kind == .takeProfit ? tr("Enter the take-profit as a number, or leave it empty.") : tr("Enter the stop-loss as a number, or leave it empty.")
            }
            if kind == .stopLoss, market.maintMarginFraction == nil { return PerplTriggerRules.liquidationUnknownMessage }
            if let problem = PerplTriggerRules.problem(kind, price: price, side: side, reference: refPrice, liquidation: projectedLiquidation(side: side), priceDecimals: market.priceDecimals) {
                return problem.message(market: market)
            }
        }
        return nil
    }

    // MARK: Bottom section (positions / orders / assets / trade history)

    private var bottomSection: some View {
        VStack(spacing: 14) {
            orderStatusRow
            protectionBanner
            segmentedTabs
            switch bottomTab {
            case .positions:
                if let position {
                    PositionCard(position: position, liveMark: mark, triggers: triggerRows(for: market).filter { $0.positionLong == (position.side == .long) },
                                 onClose: { closeRoute = apiRoute; closingPosition = position }, onAddMargin: { marginRoute = apiRoute; addingMargin = position },
                                 onTriggers: { editingTriggers = position })
                }
                else { emptyRow("No open positions") }
                orphanBanner
            case .orders:
                let orders = model.orders.filter { $0.perpId == market.id }
                let rows = triggerRows(for: market)
                ordersFreshnessBanner(rows: rows)
                orphanBanner
                if orders.isEmpty, rows.isEmpty { emptyRow("No open orders") }
                else {
                    ForEach(orders) { order in
                        let streamKey = PerplOpenOrder.streamOrder(for: order, in: perplTrading.openOrders, priceDecimals: market.priceDecimals)?.id
                        OrderCard(order: order, mark: mark, cancelling: streamKey.map { perplTrading.cancellingKeys.contains($0) } ?? false,
                                  gone: perplTrading.chainOrderGone(order), onCancel: { tapCancel(order) })
                    }
                    ForEach(rows) { row in
                        TriggerCard(row: row, mark: mark, cancelling: row.order.map { perplTrading.cancellingKeys.contains($0.id) } ?? false) {
                            guard let order = row.order else { return }
                            cancellingTriggers = TriggerCancelRequest(orders: [order], title: row.kind == .takeProfit ? "Cancel Take Profit" : "Cancel Stop Loss", note: nil)
                        }
                    }
                }
            case .assets:
                let total = model.account.map { Amount.units($0.balance, decimals: 6) } ?? 0
                let inUse = model.account.map { Amount.units(min($0.balance, $0.locked), decimals: 6) } ?? 0
                DetailRows {
                    DetailRow("Total balance", PriceFormat.usdValue(total))
                    DetailRow("In use (margin)", PriceFormat.usdValue(inUse))
                    DetailRow("Available", PriceFormat.usdValue(availableMargin))
                    DetailRow("Unrealized", PriceFormat.usdValue(model.unrealizedTotal, signed: true), tint: model.unrealizedTotal < 0 ? .negative : .positive)
                }
            case .history:
                historyList
            }
        }
    }

    /// Positions / Orders / Assets / Trade History as underline tabs: each title on one line at its own width, the selected one
    /// semibold without moving the others (each reserves its semibold width). When they don't all fit (a longer translation,
    /// a large text size), the row scrolls sideways instead of wrapping, keeping the selected tab in view.
    private var segmentedTabs: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { tab in
                    tabButton(tab)
                    if tab != BottomTab.allCases.last { Spacer(minLength: 12) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) { ForEach(BottomTab.allCases) { tabButton($0).id($0) } }
                }
                .onAppear { proxy.scrollTo(bottomTab, anchor: .center) }
                .onChange(of: bottomTab) { _, tab in withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(tab, anchor: .center) } }
            }
        }
    }

    private func tabButton(_ tab: BottomTab) -> some View {
        let active = bottomTab == tab
        return Button {
            if bottomTab != tab { Haptics.selection(); withAnimation(.easeInOut(duration: 0.15)) { bottomTab = tab } }
        } label: {
            ZStack {
                tab.title.font(.subheadline.weight(.semibold)).hidden()   // the selected width, always reserved
                tab.title.font(.subheadline.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Capsule().fill(active ? Color.brand : .clear).frame(height: 2.5) }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Says when the TP/SL list can't be verified (security audit GT-3): the trading stream isn't live, so rows are
    /// the last list Perpl sent or this device's own record, and triggers set elsewhere don't show — or it is live but a
    /// heartbeat gap means some of Perpl's updates may have been missed (I10).
    @ViewBuilder private func ordersFreshnessBanner(rows: [TriggerRow]) -> some View {
        if !perplTrading.ordersAreLive, perplTrading.isEnrolled || !rows.isEmpty {
            freshnessNote(Paragraph("TP/SL can't be verified right now: Perpl trading is offline. Rows below may be out of date, and orders placed on other devices or the Perpl web app don't show."))
        } else if perplTrading.ordersAreLive, perplTrading.streamSuspect {
            freshnessNote(Paragraph(LocalizedStringResource("TP/SL may be out of date: some updates from Perpl may have been missed. Reconnect in Profile → Perpl Trading to refresh them.",
                                                            comment: "The Perps Orders tab's warning: the trading connection is up, but a gap in Perpl's heartbeat means some order updates may have been missed, so the take-profit / stop-loss rows may be out of date. Profile → Perpl Trading is where the connection is managed.")))
        }
    }

    private func freshnessNote(_ paragraph: Paragraph) -> some View {
        Label { paragraph } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .modifier(ParagraphLabel())
            .font(.footnote).foregroundStyle(Color.attention)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// TP/SL left on this market with no position to close (security audit GT-2): left armed, they would fire on the
    /// next position on that side. Offered for cancelling in one tap (the app cancels them itself for a key account
    /// once it sees the position close; a passkey account's cancel needs Face ID, so it lands here). Never those a
    /// cancel is already on its way for, or that the automatic clean-up is about to cancel: a tap would send a second.
    /// Those are said to be cancelling instead (no button), so the banner neither flashes away nor offers them twice
    /// (I32); still listed after those windows, they are offered again.
    @ViewBuilder private var orphanBanner: some View {
        let orphans = orphansToOffer
        let cancelling = orphansBeingCancelled
        if !orphans.isEmpty || !cancelling.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !orphans.isEmpty {
                    Label {
                        Paragraph("\(orphans.count) TP/SL on \(market.asset) have no position to close. Left armed, they would fire on your next position here.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .modifier(ParagraphLabel())
                    .font(.footnote).foregroundStyle(Color.attention)
                    Button(orphans.count == 1 ? "Cancel It" : "Cancel Them") {
                        cancellingTriggers = TriggerCancelRequest(orders: orphans, title: "Leftover TP/SL", note: "There is no open position on \(market.asset) for these to close.")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
                if !cancelling.isEmpty {
                    Label {
                        Paragraph(verbatim: PerpTriggerCopy.cancellingLeftovers(count: cancelling.count, asset: market.asset))
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                    .modifier(ParagraphLabel())
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// The newest order sent from this market whose sheet is closed: still waiting for Perpl, or its result until it is
    /// seen (a success leaves after a few seconds, a warning or a failure stays until dismissed). The timeline re-reads
    /// it every second, for the success's time out.
    @ViewBuilder private var orderStatusRow: some View {
        if perplTrading.orders.orders.contains(where: { $0.marketId == market.id }) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let order = perplTrading.orders.bannerOrder(marketId: market.id, now: context.date) {
                    PerpOrderStatusRow(order: order) { perplTrading.orders.dismissBanner(order.id) }
                }
            }
        }
    }

    /// A fired or failed TP/SL, or a liquidation, reported by the trading stream (security audit GT-9) — shown here as
    /// well as in notifications, until dismissed.
    @ViewBuilder private var protectionBanner: some View {
        if let notice = perplTrading.protectionNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.warning ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(notice.warning ? Color.attention : Color.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Paragraph(notice.title).font(.subheadline.weight(.semibold))
                    Paragraph(notice.body).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { perplTrading.dismissProtectionNotice() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 12)
            .background((notice.warning ? Color.attention : Color.brand).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    // MARK: Trade history (this market)

    @ViewBuilder private var historyList: some View {
        if perplTrading.key == nil {
            // A passkey account's key exists only while its session is live; the history needs it to sign the reads.
            emptyRow(perplTrading.isEnrolled ? "Your Perpl history loads while your passkey session is unlocked." : "Connect Perpl trading in Profile to see your history.")
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
                historyStat("Value", PriceFormat.usdValue(fill.notional), align: .trailing)
                historyStat("Fee", PriceFormat.usdValue(fill.fee), align: .leading)
                Color.clear.frame(height: 0)
                pnlStat(pnl)
            }
        }
        .padding(.vertical, 10)
    }

    private func historyStat(_ label: LocalizedStringKey, _ value: String, align: HorizontalAlignment) -> some View {
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
                Text(PriceFormat.usdValue(pnl, signed: true))
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(pnl < 0 ? Color.negative : (pnl > 0 ? Color.positive : Color.primary))
            } else {
                Text(verbatim: "—").font(.caption.weight(.medium)).foregroundStyle(.secondary)
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

    /// The order under review (`reviewInput`), or the live ticket when no review is open.
    private var reviewedInput: OrderInput { reviewInput ?? ticket.input(market: market, refPrice: refPrice) }

    @ViewBuilder private var orderConfirmSheet: some View {
        // Use the authenticated (keeper-forwarded) path when the socket is live, OR when the wallet has an enrolled key
        // and the user wants TP/SL — `submitBracket` awaits ensureConnected(), so a socket that idled to `.enrolled`
        // still reconnects and carries the triggers instead of silently dropping to a bare on-chain entry. A plain
        // order with no triggers still falls through to the on-chain path when not live, so trading never depends on
        // one-click.
        if let accountId = authedOrderAccount {
            AuthedOrderSheet(market: market, input: reviewedInput, takeProfit: tpValue, stopLoss: slValue, accountId: accountId, sideColor: sideColor, summaryMargin: notional / max(ticket.leverage, 1),
                             triggerSize: invertedSize(side: ticket.side), triggerNote: turnaroundNote, onChainPositions: model.positions, onChainOrders: model.orders,
                             live: reviewLive, closes: reviewCloses, held: reviewHeld.map { ($0.side, $0.size) }, ttlBlocks: model.context[market.id]?.orderTTLBlocks,
                             markets: model.markets, before: reviewHeld, beforeReadAt: reviewReadAt, restingOnSide: reviewRestingOnSide,
                             onSent: { if let reviewCloses { model.noteUserClose(market.id, closing: reviewCloses) } }) { clearTicket in
                // An order that provably executed nothing stays in the ticket, ready to send again (a new tap).
                if clearTicket { ticket.sizeText = ""; ticket.takeProfitText = ""; ticket.stopLossText = ""; sizePercent = 0 }
                Task { await model.load(env: env, address: session.address) }
            }
        } else {
            confirmSheet
        }
    }

    /// The on-chain order: signed in the wallet, sent as a transaction, and — once it confirms — read from its receipt:
    /// the sheet holds "done" until it can say what the order did (filled, partly filled, resting, or nothing filled).
    private var confirmSheet: some View {
        ConfirmationSheet(title: "Review Order", confirmTitle: ticket.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", build: { try await checkedOrderPlan() }, onDone: {
            // An order that provably executed nothing stays in the ticket, ready to send again (a new tap).
            if PerplTracker.clearsTicket(onChainOrder.flatMap { perplTrading.orders.order($0)?.entry }) { ticket.sizeText = ""; sizePercent = 0 }
            Task { await model.load(env: env, address: session.address) }
        }, onCompleted: { hash in
            if let reviewCloses { model.noteUserClose(market.id, closing: reviewCloses) }
            // At the receipt (GL-3): its row says it was sent and its result isn't read yet (no volume until a fill is), and
            // it is followed until its receipt is read, even if the app is killed first.
            let id = onChainOrder ?? UUID()
            onChainOrder = id
            perplTrading.trackOnChain(id: id, hash: hash, input: reviewedInput, closes: reviewCloses, held: reviewHeld.map { ($0.side, $0.size) },
                                      accountId: model.account?.accountId, descId: planDescId, owner: session.address)
        }, intent: orderIntent, onStarted: {
            // A confirm tried again after one that sent nothing: that one expects no fill any more.
            if let previous = onChainOrder { perplTrading.onChainSheetClosed(previous) }
            // The app-wide watcher waits for this order's own result rather than announcing its fill first (I5).
            onChainOrder = perplTrading.expectOnChainOrder(reviewedInput, held: reviewHeld.map { ($0.side, $0.size) })
        }, settle: { _ in
            guard let id = onChainOrder else { return nil }
            return await perplTrading.settleOnChainOrder(id)
        }) {
            let signed = reviewedInput
            DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: "\(market.asset)-PERP"))
            DetailRow("Side", ticket.side == .long ? "Long" : "Short", tint: sideColor)
            if signed.kind == .limit, let flagged = PerpOrderCopy.limitType(price: NumberStyle.number(signed.price ?? mark, maximumFractionDigits: market.priceDecimals), postOnly: signed.postOnly, reduceOnly: signed.reduceOnly) {
                DetailRow("Type", verbatim: flagged)
            } else {
                DetailRow("Type", ticket.kind == .market ? "Market · \(NumberStyle.basisPoints(ticket.slippageBps)) slippage" : "Limit at \(NumberStyle.number(signed.price ?? mark, maximumFractionDigits: market.priceDecimals))")
            }
            // The parsed values this order signs, not the typed text (audit F4), at the market's full precision.
            DetailRow("Size", verbatim: "\(NumberStyle.number(signed.size, maximumFractionDigits: market.lotDecimals)) \(market.asset)")
            DetailRow("Leverage", verbatim: "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×")
            DetailRow("Margin", PriceFormat.usdValue(notional / max(ticket.leverage, 1)))
            // This path (perplTrading not ready) places a bare on-chain entry — it cannot attach TP/SL. Don't advertise
            // triggers the order won't carry; tell the user they need one-click trading for them.
            if ticket.effectiveTPSL, !ticket.takeProfitText.isEmpty || !ticket.stopLossText.isEmpty {
                DetailRow("TP/SL", "Needs one-click trading — not placed", tint: .attention)
            }
            if !ticket.effectiveReduceOnly, let leftover = leftoverTriggerProblem(side: ticket.side) {
                // The stream came up after the plan was prepared: the check runs here too.
                Text(leftover).font(.footnote).foregroundStyle(Color.attention)
            } else if leftoversUnchecked {
                Text(ticket.side == .long
                     ? "Take-profit and stop-loss left from an earlier \(market.asset) long can't be checked while Perpl trading is offline. If you had any, check Orders first: they would act on this position."
                     : "Take-profit and stop-loss left from an earlier \(market.asset) short can't be checked while Perpl trading is offline. If you had any, check Orders first: they would act on this position.")
                    .font(.footnote).foregroundStyle(Color.attention)
            }
        }
    }

    /// An on-chain opening order, valued at its worst-case notional and declared by its terms (market, side, size,
    /// leverage), which the wallet checks against the calldata it signs; a reduce-only close always asks (MERA-PLAN §3).
    private var orderIntent: Mera.Intent {
        let input = reviewedInput
        return input.reduceOnly ? .alwaysAsks(.closePosition) : .perplOrder(usd: Mera.SpendingCaps.notionalUSD(of: input), order: .init(input))
    }

    /// A Cancel tap on a resting order. Perpl's live list already showed a cancel from this device took it: no sheet, and
    /// the chain is read again. The stream's word alone that it left (no cancel from here) never refuses the wallet's
    /// cancel: the chain is read again, and if it still lists the order its wallet sheet opens.
    /// Otherwise the path is fixed here (A.2): Perpl's API when one-click is live for this account, its list is live and
    /// not suspect, and the stream's order matches the chain's by its smart contract order id; else the wallet's cancel.
    private func tapCancel(_ order: PerpOrder) {
        if let gone = perplTrading.chainOrderGone(order) {
            if gone.byCancel { Haptics.warning() }
            Task {
                await model.load(env: env, address: session.address)
                guard !gone.byCancel else { return }
                guard let fresh = model.orders.first(where: { PerplTrading.ChainOrderKey($0) == PerplTrading.ChainOrderKey(order) }) else {
                    Haptics.warning()
                    return
                }
                cancelTarget = nil
                cancelTapRq = nil
                cancelAccount = nil
                cancellingOrder = fresh
            }
            return
        }
        if let account = actionAccount, perplTrading.apiActionsLive(for: account), perplTrading.ordersAreLive, !perplTrading.streamSuspect {
            cancelTarget = PerplOpenOrder.streamOrder(for: order, in: perplTrading.openOrders, priceDecimals: market.priceDecimals)
            cancelTapRq = cancelTarget.flatMap { perplTrading.requestId(for: $0.id) }
            cancelAccount = account
        } else {
            cancelTarget = nil
            cancelTapRq = nil
            cancelAccount = nil
        }
        cancellingOrder = order
    }

    private func cancelOrderSheet(_ order: PerpOrder) -> some View {
        let size = NumberStyle.number(order.size)
        let price = NumberStyle.number(order.price)
        let what = order.side == .buy ? tr("Buy \(size) at \(price)") : tr("Sell \(size) at \(price)")
        return ConfirmationSheet(title: "Cancel Order", confirmTitle: "Cancel Order", build: { env.perpl.cancelPlan(perpId: order.perpId, orderId: order.orderId) }, onDone: { Task { await model.load(env: env, address: session.address) } },
                          onCompleted: { hash in Activity.record(ActivityRecord(kind: .perp, title: tr("Cancelled \(order.symbol) order"), subtitle: what, hash: hash, section: "perps"), owner: session.address) },
                          intent: .alwaysAsks(.cancelOrder)) {
            DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: order.symbol))
            DetailRow("Order", verbatim: what)
        }
    }

    // MARK: TP/SL helpers

    private var tpValue: Double? { ticket.effectiveTPSL ? ticket.takeProfitText.perpDouble : nil }
    private var slValue: Double? { ticket.effectiveTPSL ? ticket.stopLossText.perpDouble : nil }
    /// The user is asking for at least one trigger — which only the authenticated (keeper-forwarded) path can carry.
    private var wantsTriggers: Bool { tpValue != nil || slValue != nil }

    /// The market's TP/SL to show: Perpl's authoritative open triggers (mt:23/24, source of truth), plus — only
    /// briefly after placement, or while the trading socket is offline — the app's local echo for a kind the
    /// authoritative feed hasn't reflected yet. Once the feed confirms a trigger, the echo for that kind drops out.
    /// "Live" means the stream is signed in and has sent its snapshot (one-click on or not); otherwise every row says it
    /// can't be verified (security audit GT-3).
    private func triggerRows(for market: PerpMarket) -> [TriggerRow] {
        let priceScale = pow(10.0, Double(market.priceDecimals))
        let sizeScale = pow(10.0, Double(market.lotDecimals))
        // A heartbeat gap since the snapshots means updates may have been missed: the rows say "Last seen on Perpl" (I10).
        let live = perplTrading.ordersAreLive && !perplTrading.streamSuspect
        let positionSize = { (long: Bool) -> Double? in position.flatMap { ($0.side == .long) == long ? $0.size : nil } }
        let authoritative = perplTrading.openOrders
            .filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly }
            .map { o in
                TriggerRow(id: "auth-\(o.marketId)-\(o.oid)", symbol: market.asset, kind: o.isStopLoss ? .stopLoss : .takeProfit,
                           price: Double(o.triggerPriceRaw ?? 0) / priceScale, size: Double(o.sizeRaw) / sizeScale,
                           positionLong: o.protectsLong, source: live ? .live : .lastKnown, order: o, positionSize: positionSize(o.protectsLong))
            }
        let authKinds = Set(authoritative.map(\.kind))
        let echo = model.triggers
            .filter { $0.perpId == market.id && !authKinds.contains($0.kind) && (!live || Date().timeIntervalSince($0.placedAt) < 10) }
            .map { TriggerRow(id: "echo-\($0.id)", symbol: $0.symbol, kind: $0.kind, price: $0.price, size: $0.size, positionLong: $0.positionLong,
                              source: live ? .pending : .unverified, order: nil, positionSize: positionSize($0.positionLong)) }
        return authoritative + echo
    }

    /// The live TP/SL closing `position`'s side on this market.
    private func triggersProtecting(_ position: PerpPosition) -> [PerplOpenOrder] {
        guard perplTrading.ordersAreLive else { return [] }
        return perplTrading.openOrders.filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly && $0.protectsLong == (position.side == .long) }
    }

    /// This market's TP/SL with no position left to close (security audit GT-2).
    private var orphanedTriggers: [PerplOpenOrder] {
        perplTrading.orphanedTriggers(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// This market's orphaned TP/SL that no cancel is already on its way for (`PerplTrading.orphansToOffer`).
    private var orphansToOffer: [PerplOpenOrder] {
        perplTrading.orphansToOffer(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// This market's orphaned TP/SL a cancel is on its way for, or that the automatic clean-up is about to cancel.
    private var orphansBeingCancelled: [PerplOpenOrder] {
        perplTrading.orphansBeingCancelled(onChainPositions: model.positions, onChainOrders: model.orders).filter { $0.marketId == market.id }
    }

    /// Leftover TP/SL on this side of the market (security audit GT-2) would act on the position this order opens: a
    /// stop-loss left from an earlier position can fire the moment it exists. They are cancelled first. Checked again
    /// where the order is sent: `PerplTrading.submitBracket` for a one-click order, `checkedOrderPlan` on-chain.
    private func leftoverTriggerProblem(side: PositionSide) -> String? {
        let leftovers = orphanedTriggers.filter { $0.protectsLong == (side == .long) }
        guard !leftovers.isEmpty else { return nil }
        return PerplTrading.leftoverMessage(count: leftovers.count, asset: market.asset, side: side)
    }

    /// The on-chain order's plan, once the leftover TP/SL check has run on Perpl's live lists (GT-2). The stream is
    /// brought up first when it can be without a prompt; a passkey account's stays down until its session opens, and
    /// the review says the check couldn't run (`leftoversUnchecked`).
    private func checkedOrderPlan() async throws -> [TransactionStep] {
        let input = reviewedInput
        if !input.reduceOnly {
            if perplTrading.isEnrolled, !(perplTrading.ordersAreLive && perplTrading.positionsAreLive) {
                await perplTrading.awaitLiveStream(timeout: 4)
            }
            if let problem = leftoverTriggerProblem(side: input.side) { throw PerplTradeError.invalidOrder(problem) }
        }
        let plan = env.perpl.orderPlan(input)
        // The id this very plan signs: its request is found by it in the receipt.
        planDescId = PerplReceipt.descId(ofPlan: plan)
        return plan
    }

    /// An opening order whose leftover TP/SL check can't run: Perpl trading is enrolled but its stream isn't live.
    private var leftoversUnchecked: Bool {
        !ticket.effectiveReduceOnly && perplTrading.isEnrolled && !(perplTrading.ordersAreLive && perplTrading.positionsAreLive)
    }
    private var sideColor: Color { ticket.side == .long ? .positive : .negative }

    /// For an order that turns the position around (GT-6): what its triggers act on, in the app's language. The order is
    /// on the other side of the position, so a long turns into a short or a short into a long.
    private var turnaroundNote: String? {
        guard wantsTriggers, let position, let residual = invertedSize(side: ticket.side) else { return nil }
        let held = "\(NumberStyle.number(position.size)) \(market.asset)"
        let opened = "\(NumberStyle.number(residual)) \(market.asset)"
        return ticket.side == .long
            ? tr("This order closes your \(held) short and opens a \(opened) long: its take-profit and stop-loss close that long only.")
            : tr("This order closes your \(held) long and opens a \(opened) short: its take-profit and stop-loss close that short only.")
    }

    /// What to tell the user about whether their take-profit / stop-loss will actually be placed, and whether it needs
    /// them to act. An enrolled key means the triggers WILL be placed (the order path reconnects on submit), so that
    /// is reassurance, not a warning — only `notEnrolled` / `needsForwarding` / a hard failure require an action.
    private var tpslStatus: (text: String, warning: Bool) {
        switch perplTrading.status {
        case .connected:
            // Sized to this order, and they stay that size (security audit GT-5): say so, rather than "linked to this
            // position", and point at the position's own TP/SL for the whole of it.
            let size = "\(NumberStyle.number(baseSize)) \(market.asset)"
            if let position {
                let whole = "\(NumberStyle.number(position.size)) \(market.asset)"
                return (baseSize > 0
                    ? tr("Placed on Perpl as keeper triggers that close this order's size only (\(size)), not your whole \(whole) position. For all of it, use TP/SL on the position.")
                    : tr("Placed on Perpl as keeper triggers that close this order's size only, not your whole \(whole) position. For all of it, use TP/SL on the position."), false)
            }
            return (baseSize > 0
                ? tr("Placed on Perpl as keeper triggers that close this order's size (\(size)). The size is fixed: they don't grow if you add to the position later.")
                : tr("Placed on Perpl as keeper triggers that close this order's size. The size is fixed: they don't grow if you add to the position later."), false)
        case .connecting, .enrolled:
            return (tr("Connecting to Perpl trading to place your take-profit and stop-loss."), false)
        case .needsForwarding:
            return (tr("Enable one-click trading in Profile to place take-profit and stop-loss."), true)
        case .notEnrolled:
            return (tr("Connect Perpl trading in Profile to place take-profit and stop-loss."), true)
        case .failed:
            return (tr("Couldn’t reach Perpl trading — retrying. Take-profit and stop-loss need it live."), true)
        }
    }

    /// Expected result at a take-profit / stop-loss trigger, measured from the entry (`refPrice` — the limit price for
    /// a limit order, else the mark). The ticket's side isn't chosen until the user taps Long or Short, so the sign
    /// follows the trigger's ROLE, not a not-yet-chosen (and defaulted-to-long) side: a take-profit is by definition a
    /// gain and a stop-loss a loss, and the magnitude is the price distance from entry × size. This reads correctly
    /// for both directions — a short's TP sits below entry, a long's above, but each is |trigger − entry| away.
    private func triggerMetrics(_ trigger: Double?, isProfit: Bool) -> (pct: Double, pnl: Double)? {
        guard let trigger, trigger > 0, refPrice > 0, baseSize > 0 else { return nil }
        let distance = abs(trigger - refPrice)
        let signed = isProfit ? distance : -distance
        return (signed / refPrice * 100, signed * baseSize)
    }
    private var tpMetrics: (pct: Double, pnl: Double)? { triggerMetrics(tpValue, isProfit: true) }
    private var slMetrics: (pct: Double, pnl: Double)? { triggerMetrics(slValue, isProfit: false) }

    private func triggerMetricRow(_ label: LocalizedStringKey, _ m: (pct: Double, pnl: Double)) -> some View {
        HStack {
            // The label is a key, the amount is shown as it is: one line, never a placeholder-only key.
            Text(label) + Text(verbatim: " \(PriceFormat.usdValue(m.pnl, signed: true))")
            Spacer()
            Text(NumberStyle.percent(m.pct))
        }
        .font(.caption2).monospacedDigit()
        .foregroundStyle(m.pnl >= 0 ? Color.positive : Color.negative)
    }

    private func fieldRow(_ title: LocalizedStringKey, text: Binding<String>, unit: String, placeholder: LocalizedStringKey) -> some View {
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

    /// 1x while the margin read has failed: the venue's limit is unknown, and it is never guessed.
    private var maxLeverage: Double { max(1, (1 / max(market.initMarginFraction ?? 1, 0.01)).rounded(.down)) }
    /// What a liquidation price that can't be computed reads as: unknown when the maintenance margin couldn't be read
    /// (never a guessed 5%, which would understate the risk), a dash when there is nothing to compute yet.
    private var liquidationFallback: String { market.maintMarginFraction == nil ? PositionText.unknown : "—" }
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
    /// The liquidation price the position will have after this order, to check a stop-loss against (security audit
    /// GT-8): the order's own when it opens a position, the combined one when it adds to a position on the same side,
    /// and the new side's when it turns a position around (GT-6: its triggers act on what is left on that side).
    private func projectedLiquidation(side: PositionSide) -> Double? {
        guard baseSize > 0, refPrice > 0 else { return nil }
        let margin = notional / max(ticket.leverage, 1)
        if let position, position.side == side, position.size > 0 {
            let size = position.size + baseSize
            let entry = (position.entry * position.size + refPrice * baseSize) / size
            return PerplService.liquidationPrice(side: side, entry: entry, size: size, margin: position.margin + margin, premium: position.premium, maintenanceFraction: market.maintMarginFraction)
        }
        if let residual = invertedSize(side: side) {
            return PerplService.liquidationPrice(side: side, entry: refPrice, size: residual, margin: residual * refPrice / max(ticket.leverage, 1), premium: 0, maintenanceFraction: market.maintMarginFraction)
        }
        return PerplService.liquidationPrice(side: side, entry: refPrice, size: baseSize, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction)
    }

    /// The size left on `side` when this order turns the open position on the other side around, or nil when it
    /// doesn't.
    private func invertedSize(side: PositionSide) -> Double? {
        guard let position, position.side != side, position.size > 0, baseSize > 0,
              !PerplTriggerRules.onlyReduces(side: side, size: baseSize, positionSide: position.side, positionSize: position.size) else { return nil }
        return baseSize - position.size
    }

    private var chartLevels: [ChartLevel] {
        var out: [ChartLevel] = []
        // Each line's title is on the chart's price axis, in the app's language.
        if let position {
            out.append(ChartLevel(price: position.entry, colorHex: position.side == .long ? "#1F9E5B" : "#D2483F",
                                  title: tr(LocalizedStringResource("Entry", comment: "The position's entry price: a chart line and a stat on the position [tight]"))))
            if let liq = position.liquidation, liq > 0 {
                out.append(ChartLevel(price: liq, colorHex: "#F5A623", title: tr(LocalizedStringResource("Liq", comment: "A chart line at the liquidation price, short for Liquidation. [tight]")), dashed: true))
            }
        }
        for order in model.orders where order.perpId == market.id {
            out.append(ChartLevel(price: order.price, colorHex: order.side == .buy ? "#1F9E5B" : "#D2483F",
                                  title: order.reduceOnly ? tr(LocalizedStringResource("chartLine.close", defaultValue: "Close", comment: "A chart line at a resting order that closes the position (a noun, as the order's name). [tight]"))
                                                          : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]")),
                                  dashed: true))
        }
        return out
    }

    /// "Long 5×" or "Short 5×": a position's side and its leverage.
    static func sideLeverage(_ position: PerpPosition) -> Text {
        let leverage = NumberStyle.number(position.leverage, maximumFractionDigits: 1)
        return position.side == .long ? Text("Long \(leverage)×") : Text("Short \(leverage)×")
    }

    @ViewBuilder private var positionBadge: some View {
        if let position {
            let dir = position.side == .long ? 1.0 : -1.0
            let pnl = dir * (mark - position.entry) * position.size + position.premium
            HStack(spacing: 6) {
                PerpTradeView.sideLeverage(position)
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Text(PriceFormat.usdValue(pnl, signed: true))
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

    /// Reads the current timeframe's candles. The answer only counts for the timeframe it was asked for; a failed read
    /// keeps that timeframe's last candles (marked not updating) but never another timeframe's (RS-10).
    private func loadCandles(showSpinner: Bool = true) async {
        let requested = resolution
        if showSpinner { loadingCandles = true }
        let to = Date()
        let from = to.addingTimeInterval(-Double(requested) * 150)
        let fetched = try? await env.perpl.candles(marketId: market.id, resolution: requested, from: from, to: to, priceDecimals: market.priceDecimals)
        // Cut short (the screen closed), or another timeframe was picked meanwhile and its own read follows.
        guard !Task.isCancelled, requested == resolution else { return }
        loadingCandles = false
        if let fetched {
            candles = fetched
            candlesResolution = requested
            candlesFailed = false
        } else {
            if candlesResolution != requested { candles = []; candlesResolution = nil }
            candlesFailed = true
        }
    }
}
