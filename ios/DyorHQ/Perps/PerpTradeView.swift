import BigInt
import DyorKit
import SwiftUI

extension PerpMarket {
    /// The bare asset symbol for display and logo lookup — e.g. "SOL" from a contract symbol like "SOL_v2".
    var asset: String {
        let letters = String(symbol.prefix { $0.isLetter })
        return letters.isEmpty ? symbol : letters.uppercased()
    }
}

/// The pro perpetuals screen: a live Perpl candlestick chart, the live order book and trade tape from Perpl's
/// market-data feed, and an order ticket that switches green/red with the side. Positions, orders and the account
/// come from the Exchange contract. Everything here — symbols, prices, chart, book — is Perpl's own data.
struct PerpTradeView: View {
    let market: PerpMarket
    let model: PerpsModel
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(Router.self) private var router

    @State private var feed = PerplFeed()
    @State private var candles: [PerpCandle] = []
    @State private var resolution = 3600
    @State private var loadingCandles = true
    @State private var dataTab: DataTab = .chart
    @State private var bottomTab: BottomTab = .positions
    @State private var ticket = OrderTicket()
    @State private var showConfirm = false
    @State private var closingPosition: PerpPosition?
    @State private var cancellingOrder: PerpOrder?
    @State private var candleTask: Task<Void, Never>?

    enum DataTab: String, CaseIterable, Identifiable { case chart = "Chart", book = "Order Book", trades = "Trades"; var id: String { rawValue } }
    enum BottomTab: String, CaseIterable, Identifiable { case positions = "Positions", orders = "Orders", assets = "Assets", history = "History"; var id: String { rawValue } }

    private var position: PerpPosition? { model.positions.first { $0.perpId == market.id } }
    private var live: PerplLiveState? { feed.state }
    private var mark: Double { live?.mark ?? market.mark }
    private var change24h: Double? { live?.change24h ?? model.change24h(for: market) }
    private var sideColor: Color { ticket.side == .long ? .positive : .negative }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                dataSection
                orderTicket
                bottomSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(market.asset)-PERP")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .task {
            ticket.leverage = min(settings.defaultLeverage, maxLeverage)
            ticket.slippageBps = settings.slippageBps
            // Copy-trade hand-off: preset the ticket to the copied trader's direction/leverage so the user doesn't
            // accidentally place the opposite side.
            if let side = router.pendingPerpSide { ticket.side = side; router.pendingPerpSide = nil }
            if let leverage = router.pendingPerpLeverage { ticket.leverage = min(leverage, maxLeverage); router.pendingPerpLeverage = nil }
            if let size = router.pendingPerpSize, size > 0 { ticket.sizeText = plainSize(size); router.pendingPerpSize = nil }
            feed.focus(market)
            await loadCandles()
            // Keep the chart live: re-fetch the window every 15s without flashing the spinner.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await loadCandles(showSpinner: false)
            }
        }
        .onDisappear { feed.stop(); candleTask?.cancel() }
        .onChange(of: resolution) { _, _ in Task { await loadCandles() } }
        .task(id: session.address) { perplTrading.refresh(address: session.address) }
        .sheet(isPresented: $showConfirm) {
            if perplTrading.isReady, let accountId = model.account?.accountId {
                AuthedOrderSheet(market: market, input: ticket.input(market: market), takeProfit: tpValue, stopLoss: slValue, accountId: accountId, sideColor: sideColor, summaryMargin: notional / max(ticket.leverage, 1)) {
                    ticket.sizeText = ""; ticket.takeProfitText = ""; ticket.stopLossText = ""
                    Task { await model.load(env: env, address: session.address) }
                }
            } else {
                confirmSheet
            }
        }
    }

    private var tpValue: Double? { ticket.tpslEnabled ? Double(ticket.takeProfitText) : nil }
    private var slValue: Double? { ticket.tpslEnabled ? Double(ticket.stopLossText) : nil }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                TokenLogo(symbol: market.asset, url: nil, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(market.asset)-PERP").font(.headline)
                    Text(market.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(NumberStyle.number(mark)).font(.title3.weight(.semibold)).monospacedDigit()
                    ChangeText(value: change24h, style: .caption)
                }
                Circle().fill(feed.connected ? Color.positive : Color.secondary).frame(width: 7, height: 7)
                    .accessibilityLabel(feed.connected ? "Live" : "Connecting")
            }
            HStack(spacing: 0) {
                headerStat("Funding", fundingText, tint: fundingTint)
                headerStat("Countdown", countdownText)
                headerStat("24h Vol", live.map { NumberStyle.number($0.volume24h, compact: true) } ?? "—")
                headerStat("Open Int.", NumberStyle.number(market.longOI + market.shortOI, compact: true))
            }
        }
        .padding(14)
        .cardBackground()
    }

    private func headerStat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
    }

    private var fundingText: String { NumberStyle.percent(Double(market.fundingRatePct100k) / 1_000, fractionDigits: 4) }
    private var fundingTint: Color { market.fundingRatePct100k < 0 ? .negative : market.fundingRatePct100k > 0 ? .positive : .secondary }
    private var countdownText: String {
        // ~1h funding grid on Monad blocks; show minutes to the next hour boundary as a live-ish estimate.
        let now = Date().timeIntervalSince1970
        let secs = 3600 - Int(now.truncatingRemainder(dividingBy: 3600))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    // MARK: Data section (chart / book / trades)

    private var dataSection: some View {
        VStack(spacing: 12) {
            Picker("View", selection: $dataTab) {
                ForEach(DataTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch dataTab {
            case .chart:
                VStack(spacing: 8) {
                    TradingViewChart(candles: candles)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            if candles.isEmpty {
                                if loadingCandles { ProgressView() }
                                else { ContentUnavailableView("No Candles", systemImage: "chart.bar.xaxis", description: Text("Perpl has no candle history for this market yet.")) }
                            }
                        }
                    timeframePicker
                }
            case .book:
                OrderBookPanel(book: feed.book, priceDecimals: market.priceDecimals, sizeDecimals: market.lotDecimals, symbol: market.asset)
                    .frame(minHeight: 300)
            case .trades:
                TradesTape(trades: feed.trades, symbol: market.asset)
                    .frame(minHeight: 300)
            }
        }
        .padding(14)
        .cardBackground()
    }

    private var timeframePicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.resolutions, id: \.0) { seconds, label in
                Button(label) { if resolution != seconds { Haptics.selection(); resolution = seconds } }
                    .font(.caption.weight(resolution == seconds ? .bold : .regular))
                    .foregroundStyle(resolution == seconds ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(resolution == seconds ? Color(.tertiarySystemFill) : .clear, in: Capsule())
            }
        }
    }

    static let resolutions: [(Int, String)] = [(60, "1m"), (300, "5m"), (900, "15m"), (3600, "1h"), (14400, "4h"), (86400, "1D")]

    // MARK: Order ticket

    private var orderTicket: some View {
        VStack(spacing: 14) {
            // Side — the whole ticket takes its colour from here: green for Long, red for Short.
            sideSelector

            HStack(spacing: 10) {
                chip("Isolated", system: "lock")
                Menu {
                    ForEach(leverageOptions, id: \.self) { lev in
                        Button("\(Int(lev))×") { ticket.leverage = lev }
                    }
                } label: {
                    HStack(spacing: 4) { Text("\(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×").fontWeight(.semibold); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .foregroundStyle(.primary)
            }

            Picker("Type", selection: $ticket.kind) {
                Text("Market").tag(OrderKind.market)
                Text("Limit").tag(OrderKind.limit)
            }
            .pickerStyle(.segmented)

            if ticket.kind == .limit {
                fieldRow("Limit price", text: $ticket.priceText, unit: "USD", placeholder: NumberStyle.number(mark))
            }
            fieldRow("Amount", text: $ticket.sizeText, unit: market.asset, placeholder: NumberStyle.number(minSize))

            // Percent presets of available margin.
            HStack(spacing: 8) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button("\(pct)%") { Haptics.selection(); applyPercent(Double(pct)) }
                        .font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .disabled(model.account == nil)

            Toggle(isOn: $ticket.tpslEnabled) { Text("Take Profit / Stop Loss").font(.subheadline) }
                .tint(.brand)
            if ticket.tpslEnabled {
                fieldRow("Take profit", text: $ticket.takeProfitText, unit: "USD", placeholder: "Optional")
                fieldRow("Stop loss", text: $ticket.stopLossText, unit: "USD", placeholder: "Optional")
                Text(perplTrading.isReady
                     ? "Placed on Perpl as keeper-managed trigger orders linked to this position."
                     : "Connect Perpl trading in Profile to place take-profit and stop-loss.")
                    .font(.caption2).foregroundStyle(perplTrading.isReady ? Color.secondary : Color.attention)
            }

            DetailRows {
                DetailRow("Notional", notional.formatted(.currency(code: "USD")))
                DetailRow("Margin required", (notional / max(ticket.leverage, 1)).formatted(.currency(code: "USD")))
                DetailRow("Liq. price", liquidationText, tint: sideColor)
                DetailRow("Est. fee", estFee.formatted(.currency(code: "USD")))
            }

            if let reason = ticket.problem(market: market, account: model.account, available: availableMargin) {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }

            PrimaryButton(
                title: ticket.side == .long ? "Long \(market.asset)" : "Short \(market.asset)",
                isDisabled: ticket.problem(market: market, account: model.account, available: availableMargin) != nil || !session.canSign
            ) { showConfirm = true }
                .tint(sideColor)

            if !session.canSign { Text("Sign in to trade.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
        .padding(14)
        .cardBackground()
    }

    /// Long / Short as two filled segments that turn solid green or red the moment they are selected — the whole
    /// ticket (CTA, liquidation price) follows the same `sideColor`, so switching side visibly recolours the screen.
    private var sideSelector: some View {
        HStack(spacing: 8) {
            sideButton(.long, "Long", .positive)
            sideButton(.short, "Short", .negative)
        }
    }

    private func sideButton(_ side: PositionSide, _ label: String, _ color: Color) -> some View {
        let selected = ticket.side == side
        return Button {
            if ticket.side != side { Haptics.selection(); ticket.side = side }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(selected ? .white : color)
                .background(selected ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func chip(_ text: String, system: String) -> some View {
        Label(text, systemImage: system)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: Capsule())
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

    // MARK: Bottom (positions / orders / assets / history)

    private var bottomSection: some View {
        VStack(spacing: 12) {
            Picker("Section", selection: $bottomTab) {
                ForEach(BottomTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch bottomTab {
            case .positions:
                if let position { PositionCard(position: position, onClose: { closingPosition = position }) }
                else { emptyRow("No open positions") }
            case .orders:
                let orders = model.orders.filter { $0.perpId == market.id }
                if orders.isEmpty { emptyRow("No open orders") }
                else { ForEach(orders) { order in OrderCard(order: order, onCancel: { cancellingOrder = order }) } }
            case .assets:
                DetailRows {
                    DetailRow("Trading balance", (model.account.map { Amount.units($0.balance, decimals: 6) } ?? 0).formatted(.currency(code: "USD")))
                    DetailRow("Available", availableMargin.formatted(.currency(code: "USD")))
                    DetailRow("Unrealized", model.unrealizedTotal.formatted(.currency(code: "USD").sign(strategy: .always())), tint: model.unrealizedTotal < 0 ? .negative : .positive)
                }
            case .history:
                emptyRow("Trade history appears here")
            }
        }
        .padding(14)
        .cardBackground()
        .sheet(item: $closingPosition) { position in closePositionSheet(position) }
        .sheet(item: $cancellingOrder) { order in cancelOrderSheet(order) }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: Confirmation sheets

    private var confirmSheet: some View {
        ConfirmationSheet(title: "Review Order", confirmTitle: ticket.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", build: { env.perpl.orderPlan(ticket.input(market: market)) }, onDone: { ticket.sizeText = ""; Task { await model.load(env: env, address: session.address) } }, onCompleted: { hash in
            ActivityLog.record(ActivityRecord(kind: .perp, title: "\(ticket.side == .long ? "Long" : "Short") \(market.asset)-PERP", subtitle: "\(ticket.sizeText) \(market.asset) · \(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×", hash: hash), owner: session.address)
        }) {
            DetailRow("Market", "\(market.asset)-PERP")
            DetailRow("Side", ticket.side == .long ? "Long" : "Short", tint: sideColor)
            DetailRow("Type", ticket.kind == .market ? "Market · \(NumberStyle.basisPoints(ticket.slippageBps)) slippage" : "Limit at \(ticket.priceText)")
            DetailRow("Size", "\(ticket.sizeText) \(market.asset)")
            DetailRow("Leverage", "\(NumberStyle.number(ticket.leverage, maximumFractionDigits: 1))×")
            DetailRow("Margin", (notional / max(ticket.leverage, 1)).formatted(.currency(code: "USD")))
            if ticket.tpslEnabled, !ticket.takeProfitText.isEmpty { DetailRow("Take profit", ticket.takeProfitText) }
            if ticket.tpslEnabled, !ticket.stopLossText.isEmpty { DetailRow("Stop loss", ticket.stopLossText) }
        }
    }

    private func closePositionSheet(_ position: PerpPosition) -> some View {
        ConfirmationSheet(title: "Close Position", confirmTitle: "Close \(position.symbol)", build: { env.perpl.closePositionPlan(market: market, position: position, slippageBps: 100) }, onDone: { Task { await model.load(env: env, address: session.address) } }) {
            DetailRow("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
            DetailRow("Mark price", NumberStyle.number(mark))
            DetailRow("Unrealized", position.unrealized.formatted(.currency(code: "USD").sign(strategy: .always())), tint: position.unrealized < 0 ? .negative : .positive)
            DetailRow("Order", "Market, reduce only, 1% slippage")
        }
    }

    private func cancelOrderSheet(_ order: PerpOrder) -> some View {
        ConfirmationSheet(title: "Cancel Order", confirmTitle: "Cancel Order", build: { env.perpl.cancelPlan(perpId: order.perpId, orderId: order.orderId) }, onDone: { Task { await model.load(env: env, address: session.address) } }) {
            DetailRow("Market", order.symbol)
            DetailRow("Order", "\(order.side == .buy ? "Buy" : "Sell") \(NumberStyle.number(order.size)) at \(NumberStyle.number(order.price))")
        }
    }

    // MARK: Derived values

    private var maxLeverage: Double { max(1, (1 / max(market.initMarginFraction, 0.01)).rounded(.down)) }
    private var leverageOptions: [Double] { [1, 2, 3, 5, 10, 15, 20, 25, 50].filter { $0 <= maxLeverage } }
    private var minSize: Double { pow(10, -Double(market.lotDecimals)) }
    private var refPrice: Double { ticket.kind == .limit ? (Double(ticket.priceText) ?? mark) : mark }
    private var notional: Double { (Double(ticket.sizeText) ?? 0) * refPrice }
    private var estFee: Double { notional * 0.00069 } // T1 taker ≈ 6.9 bps; close is free
    private var availableMargin: Double {
        guard let account = model.account else { return 0 }
        return Amount.units(account.balance - min(account.balance, account.locked), decimals: 6)
    }
    private var liquidationText: String {
        let size = Double(ticket.sizeText) ?? 0
        guard size > 0 else { return "—" }
        let margin = notional / max(ticket.leverage, 1)
        guard let liq = PerplService.liquidationPrice(side: ticket.side, entry: refPrice, size: size, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction) else { return "—" }
        return NumberStyle.number(liq)
    }

    private func applyPercent(_ pct: Double) {
        guard refPrice > 0 else { return }
        let size = availableMargin * (pct / 100) * ticket.leverage / refPrice
        let stepped = (size * pow(10, Double(market.lotDecimals))).rounded(.down) / pow(10, Double(market.lotDecimals))
        ticket.sizeText = stepped > 0 ? plainSize(stepped) : ""
    }

    /// Formats a size into the amount field as a plain, ungrouped decimal. `NumberStyle.number` inserts the locale's
    /// grouping separator for values ≥ 1000 ("2,000"), which `Double(sizeText)` — used to validate and place the
    /// order — cannot parse (or, in dot-grouping locales, mis-parses as 2.0). This keeps the round-trip exact.
    private func plainSize(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = max(market.lotDecimals, 2)
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

// MARK: - Order book

struct OrderBookPanel: View {
    let book: OrderBook
    let priceDecimals: Int
    let sizeDecimals: Int
    let symbol: String
    private let rows = 9

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size (\(symbol))").font(.caption2).foregroundStyle(.secondary)
            }
            if book.isEmpty {
                Text("Waiting for the book…").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                let asks = Array(book.asks.prefix(rows)).reversed()
                let bids = Array(book.bids.prefix(rows))
                let maxSize = max(book.asks.prefix(rows).map(\.size).max() ?? 1, book.bids.prefix(rows).map(\.size).max() ?? 1)
                ForEach(Array(asks), id: \.price) { level in row(level, tint: .negative, maxSize: maxSize) }
                HStack {
                    Text(book.bestBid.map { NumberStyle.number($0) } ?? "—").font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(.positive)
                    Spacer()
                    if let spread = book.spread { Text("Spread \(NumberStyle.number(spread))").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(book.bestAsk.map { NumberStyle.number($0) } ?? "—").font(.footnote.weight(.bold)).monospacedDigit().foregroundStyle(.negative)
                }
                .padding(.vertical, 4)
                ForEach(bids, id: \.price) { level in row(level, tint: .positive, maxSize: maxSize) }
                ratioBar
            }
        }
    }

    private func row(_ level: BookLevel, tint: Color, maxSize: Double) -> some View {
        ZStack(alignment: tint == .positive ? .leading : .trailing) {
            GeometryReader { geo in
                Rectangle().fill(tint.opacity(0.14))
                    .frame(width: geo.size.width * min(1, level.size / maxSize))
            }
            HStack {
                Text(NumberStyle.number(level.price)).font(.caption.monospacedDigit()).foregroundStyle(tint)
                Spacer()
                Text(NumberStyle.number(level.size, maximumFractionDigits: sizeDecimals)).font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 20)
    }

    private var ratioBar: some View {
        let buy = book.bidShare
        return VStack(spacing: 3) {
            HStack {
                Text("Bids \(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false))").font(.caption2).foregroundStyle(.positive)
                Spacer()
                Text("\(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false)) Asks").font(.caption2).foregroundStyle(.negative)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Color.positive).frame(width: geo.size.width * buy - 1)
                    Capsule().fill(Color.negative)
                }
            }
            .frame(height: 4)
        }
        .padding(.top, 6)
    }
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
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Spacer()
                Text(position.unrealized, format: .currency(code: "USD").sign(strategy: .always()))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                stat("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
                stat("Entry", NumberStyle.number(position.entry))
                stat("Mark", NumberStyle.number(position.mark))
                stat("Margin", position.margin.formatted(.currency(code: "USD")))
                stat("Liq.", position.liquidation.map { NumberStyle.number($0) } ?? "—")
                stat("Notional", position.notional.formatted(.currency(code: "USD")))
            }
            Button("Close at Market", action: onClose)
                .buttonStyle(.bordered).controlSize(.small).tint(.negative)
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
                    PrimaryButton(title: input.side == .long ? "Long \(market.asset)" : "Short \(market.asset)", isBusy: phase == .placing) {
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
                // Perpl's authenticated path settles off-chain, so there is no Monad tx hash to link — record it for
                // Recent Activity anyway (perps have no on-chain feed to scan).
                ActivityLog.record(ActivityRecord(kind: .perp, title: "\(input.side == .long ? "Long" : "Short") \(market.asset)-PERP", subtitle: "\(NumberStyle.number(input.size)) \(market.asset)\(input.kind == .market ? " · Market" : " · Limit")", hash: nil), owner: session.address)
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
    var side: PositionSide = .long
    var kind: OrderKind = .market
    var sizeText = ""
    var priceText = ""
    var leverage: Double = 2
    var reduceOnly = false
    var slippageBps = 50
    var tpslEnabled = false
    var takeProfitText = ""
    var stopLossText = ""

    func problem(market: PerpMarket, account: PerpAccount?, available: Double) -> String? {
        guard let size = Double(sizeText), size > 0 else { return "Enter a size in \(market.asset)." }
        if kind == .limit, (Double(priceText) ?? 0) <= 0 { return "Enter a limit price." }
        if account == nil, !reduceOnly { return "Deposit AUSD to open a trading account first." }
        if account != nil, !reduceOnly {
            let price = kind == .limit ? (Double(priceText) ?? market.mark) : market.mark
            if size * price / max(leverage, 1) > available * 1.0001 { return "Not enough available margin." }
        }
        return nil
    }

    func input(market: PerpMarket) -> OrderInput {
        OrderInput(market: market, side: side, kind: kind, size: Double(sizeText) ?? 0, price: kind == .limit ? Double(priceText) : nil, leverage: leverage, reduceOnly: reduceOnly, slippageBps: slippageBps, postOnly: false)
    }
}
