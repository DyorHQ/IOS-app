import BigInt
import Charts
import DyorKit
import SwiftUI

/// Portfolio first, then the market. The layout follows a trading app's home: a balance hero with the spot,
/// perps and launchpad split, quick actions, an allocation ring, top movers, and the wallet's own holdings.
/// Everything reads straight from Monad and Perpl each refresh; the design stays in DyorHQ's system (SF type,
/// serif display, semantic green/red), and works on paper and ink grounds alike.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeModel()
    /// The Add funds card for an empty passkey account (MERA-PLAN §4).
    @State private var funding = FundingWatch()
    @State private var tokenTab: HomeTokenTab = .popular
    @State private var holdingTab: HoldingCategory = .spot
    @State private var showReceive = false
    @State private var showBridge = false
    @State private var showSend = false
    @State private var showTransfer = false
    @State private var showSearch = false
    @State private var searchTarget: MarketRow?
    /// The Top Tokens rank column: 16 pt at the default text size, grown with the rank's footnote text so a digit never
    /// shows as "…" at the accessibility sizes. The dividers are inset by it too (`TokenListRow.textInset`).
    @ScaledMetric(relativeTo: .footnote) private var rankWidth: CGFloat = 16

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if session.isPasskeyAccount {
                        HStack { SessionPill(); Spacer() }
                    }
                    if session.isPasskeyAccount, funding.phase.isVisible, let address = session.address {
                        AddFundsCard(phase: funding.phase, address: address,
                                     onBridge: { showBridge = true },
                                     onShowQR: { showReceive = true },
                                     onTrade: { trade in router.openSwap(tokenIn: trade.pay, tokenOut: trade.receive) },
                                     onClose: { funding.close() })
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                    heroCard
                    quickActions
                    if model.totalValue ?? 0 > 0 || !model.holdings.isEmpty { allocationCard }
                    topTokensCard
                    holdingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.snappy, value: funding.phase)
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { HomeHeader(showSearch: $showSearch, error: model.error, updatedAt: model.updatedAt) }
            .navigationDestination(for: MarketRow.self) { row in TokenDetailView(row: row) }
            .navigationDestination(item: $searchTarget) { row in TokenDetailView(row: row) }
            .refreshable {
                await model.load(env: env, address: session.address)
                await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: true)
            }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .task(id: session.address) { await model.discoverHeldTokens(env: env, address: session.address) }
            .task(id: session.address) { await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: false) }
            // The Add funds card's balance watch: a passkey account only, while Home is on screen and the app is active.
            .task(id: "\(session.isPasskeyAccount ? session.address?.hex ?? "" : "")-\(scenePhase == .active)") {
                guard session.isPasskeyAccount, scenePhase == .active, let address = session.address else { return }
                await funding.watch(env: env, address: address, home: model)
            }
            .onChange(of: funding.phase.isArrival) { _, arrived in
                // Show the deposit in the balance straight away rather than at Home's next 30 s refresh.
                if arrived { Task { await model.load(env: env, address: session.address) } }
            }
            .sensoryFeedback(.success, trigger: funding.phase.isArrival) { _, arrived in arrived }
            .overlay { if model.rows.isEmpty, model.loading { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showBridge) { BridgeView(env: env) }
            .sheet(isPresented: $showSend) { SendSheet() }
            .sheet(isPresented: $showTransfer) { TransferSheet() }
            .sheet(isPresented: $showSearch) {
                TokenPickerSheet(selected: .mon, balances: Dictionary(uniqueKeysWithValues: model.rows.map { ($0.token.address, $0.balance) }), universe: KnownTokenStore.universe(owner: session.address), tradableOnly: false,
                                 unverified: KnownTokenStore.unverified(owner: session.address)) { token in
                    // Open the token's page; a token outside the priced list gets a bare row (price loads on the page).
                    searchTarget = model.rows.first { $0.token.address == token.address } ?? MarketRow(token: token, usd: nil, change24h: nil, balance: 0)
                }
            }
        }
    }

    // MARK: Hero

    /// The balance hero, in the reference layout: the total on the left with its 24h move; on the right the
    /// wallet's Total Volume across DyorHQ for the selected period, with the period switch right under it.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PriceFormat.usdValue(model.totalValue ?? 0))
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: model.totalValue ?? 0))
                        .redacted(reason: model.totalValue == nil ? .placeholder : [])
                    HStack(spacing: 8) {
                        Text(PriceFormat.usdValue(changeAmount, signed: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(changeAmount < 0 ? Color.negative : Color.positive)
                        ChangeBadge(value: model.change24h ?? 0)
                    }
                }
                Spacer(minLength: 8)
                totalVolume
            }

            Divider()

            HStack(alignment: .top) {
                statColumn("Avail. Balance", value: model.availableBalance, tint: .primary)
                Spacer()
                statColumn("In Use", value: model.inUse, tint: model.inUse > 0 ? .positive : .primary, alignment: .trailing)
            }

            Divider()

            HStack(spacing: 10) {
                splitStat("Spot", model.spotValue, .allocationSpot)
                splitStat("Perps", model.perpsValue, .allocationPerps)
                splitStat("Launch", model.launchpadValue, .allocationLaunchpad)
                splitStat("Moments", model.momentsValue, .allocationMoments)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// Today's move in dollars, from the value-weighted 24h change.
    private var changeAmount: Double {
        guard let total = model.totalValue, let change = model.change24h, change != 0 else { return 0 }
        return total - total / (1 + change / 100)
    }

    /// Total Volume for the period, right-aligned, with the period menu (24h · 7 days · 30 days · All) under it —
    /// the same figure the Portfolio breaks down by section. Tapping the number opens the Portfolio.
    private var totalVolume: some View {
        @Bindable var router = router
        return VStack(alignment: .trailing, spacing: 4) {
            Button { Haptics.tap(); router.presented = .portfolio } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total Volume").font(.subheadline).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(env.portfolio.totals(router.period).volume))
                        .font(.headline).monospacedDigit().foregroundStyle(.primary)
                        .contentTransition(.numericText(value: env.portfolio.totals(router.period).volume))
                        .redacted(reason: env.portfolio.loading && !env.portfolio.hasLoaded ? .placeholder : [])
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Total volume \(router.period.label)")
            Menu {
                Picker("Period", selection: $router.period) {
                    ForEach(VolumePeriod.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2.weight(.semibold))
                    Text(router.period.label).font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .accessibilityLabel("Volume period")
        }
    }

    private func statColumn(_ title: LocalizedStringKey, value: Double, tint: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(PriceFormat.usdValue(value)).font(.headline).monospacedDigit().foregroundStyle(tint)
        }
    }

    private func splitStat(_ title: LocalizedStringKey, _ value: Double, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(PriceFormat.usdValue(value))
                .font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            HomeAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { showBridge = true }
            HomeAction(title: "Deposit", symbol: "creditcard") { showReceive = true }
            HomeAction(title: "Withdraw", symbol: "arrow.up") { showSend = true }
            HomeAction(title: "Transfer", symbol: "arrow.left.arrow.right") { showTransfer = true }
        }
        .disabled(session.address == nil)
    }

    // MARK: Allocation

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation").font(.headline)
            AllocationDonut(
                segments: [
                    .init(label: tr("Spot"), value: model.spotValue, color: .allocationSpot),
                    .init(label: tr("Perps"), value: model.perpsValue, color: .allocationPerps),
                    .init(label: tr("Launchpad"), value: model.launchpadValue, color: .allocationLaunchpad),
                    .init(label: tr("Moments"), value: model.momentsValue, color: .allocationMoments),
                ],
                total: model.totalValue ?? 0
            )
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: Top tokens

    private var topTokensCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Tokens").font(.headline)
            Picker("Filter", selection: $tokenTab) {
                ForEach(HomeTokenTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            let tokens = model.topTokens(tokenTab)
            if tokens.isEmpty {
                Text("Loading markets…").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tokens.prefix(6).enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: row) { TokenListRow(rank: index + 1, row: row, rankWidth: rankWidth) }
                            .buttonStyle(.plain)
                        if index < min(5, tokens.count - 1) { Divider().padding(.leading, TokenListRow.textInset(rankWidth: rankWidth)) }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    // MARK: Holdings

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
            }
            Picker("Category", selection: $holdingTab) {
                ForEach(HoldingCategory.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch holdingTab {
            case .spot:
                if model.holdings.isEmpty { holdingsEmpty("No spot balances", "Buy or swap a token and it appears here.") }
                else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.holdings.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: row) { HoldingRow(row: row, unverified: model.unverified.contains(row.id)) }.buttonStyle(.plain)
                            if index < model.holdings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .perps:
                if model.positions.isEmpty { holdingsEmpty("No open positions", "Open a perp from the Trade tab.") }
                else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.positions.enumerated()), id: \.element.id) { index, position in
                            Button { router.openPerp(id: position.perpId) } label: { PositionSummaryRow(position: position) }
                                .buttonStyle(.plain)
                            if index < model.positions.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .launchpad:
                if model.launchHoldings.isEmpty { holdingsEmpty("No launch holdings", "Buy or launch a coin on the Launch tab.") }
                else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.launchHoldings.enumerated()), id: \.element.id) { index, holding in
                            // Every launch holding opens its own Launch page, never Swap: a coin still on a curve (the
                            // live launchpad's or a retired one's) trades there, and a graduated one's page leads to Swap.
                            Button { router.openLaunch(holding.launch) } label: { LaunchHoldingRow(holding: holding, value: totals.value(of: holding.id, units: holding.units)) }
                                .buttonStyle(.plain)
                            if index < model.launchHoldings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .moments:
                if model.momentRows.isEmpty { holdingsEmpty("No Moments yet", "Collect a Moment on the Moments tab and your editions and coins appear here.") }
                else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.momentRows.enumerated()), id: \.element.id) { index, row in
                            Button { router.openMoment(row.moment) } label: { MomentHoldingRow(row: row, value: totals.value(of: row.moment.moment.coin, units: HomeModel.coins(row))) }
                                .buttonStyle(.plain)
                            if index < model.momentRows.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func holdingsEmpty(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Home building blocks

enum HomeTokenTab: String, CaseIterable, Identifiable {
    case popular, hot, gainers, losers
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: return tr(LocalizedStringResource("Popular", comment: "Top Tokens tab: the curated list [tight]"))
        case .hot: return tr(LocalizedStringResource("Hot", comment: "Top Tokens tab: the biggest moves either way [tight]"))
        case .gainers: return tr(LocalizedStringResource("Gainers", comment: "Top Tokens tab: rising most in 24h [tight]"))
        case .losers: return tr(LocalizedStringResource("Losers", comment: "Top Tokens tab: falling most in 24h [tight]"))
        }
    }
}

enum HoldingCategory: String, CaseIterable, Identifiable {
    case spot, perps, launchpad, moments
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spot: return tr(LocalizedStringResource("Spot", comment: "The wallet's own tokens, as against perpetual futures [tight]"))
        case .perps: return tr(LocalizedStringResource("Perps", comment: "Perpetual futures [tight]"))
        case .launchpad: return tr(LocalizedStringResource("Launch", comment: "A noun: the Launch tab, the launchpad's coins [tight]"))
        case .moments: return tr(LocalizedStringResource("Moments", comment: "The Moments feature's name [tight]"))
        }
    }
}

/// One of the four home actions: an SF Symbol over a label, filling its share of the row.
private struct HomeAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold))
                Text(title).font(.caption).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}

/// The allocation ring: a donut of the value split with a centered total and a legend of shares.
struct AllocationDonut: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    let total: Double

    private var hasValue: Bool { total > 0 && segments.contains { $0.value > 0 } }

    var body: some View {
        HStack(spacing: 20) {
            Chart(hasValue ? segments : placeholder) { segment in
                SectorMark(angle: .value("Value", segment.value), innerRadius: .ratio(0.66), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(segment.color)
            }
            .chartLegend(.hidden)
            .frame(width: 128, height: 128)
            .overlay {
                VStack(spacing: 1) {
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(total)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 9, height: 9)
                        Text(segment.label).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(NumberStyle.percent(hasValue ? segment.value / total * 100 : 0, fractionDigits: 1, signed: false))
                            .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var placeholder: [Segment] {
        segments.map { Segment(label: $0.label, value: 1, color: $0.color.opacity(0.28)) }
    }
}

/// A ranked market row for the Top Tokens list.
private struct TokenListRow: View {
    let rank: Int
    let row: MarketRow
    /// The rank column's width (`HomeView.rankWidth`).
    let rankWidth: CGFloat

    private static let spacing: CGFloat = 12
    private static let logoSize: CGFloat = 34

    /// Where the row's text starts, for the divider under it: rank, gap, logo, gap (74 pt at the default text size).
    static func textInset(rankWidth: CGFloat) -> CGFloat { rankWidth + spacing + logoSize + spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(verbatim: "\(rank)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary).frame(width: rankWidth, alignment: .center)
            TokenLogo(token: row.token, size: Self.logoSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    // Top Tokens lists no token the wallet was sent unasked (`HomeModel.topTokens`).
                    TokenBadgeView(token: row.token, receivedUnasked: false)
                }
                Text(row.token.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            USDText(price: row.usd, font: .subheadline.weight(.medium))
                .layoutPriority(1) // the price keeps its width; the name truncates first
            ChangeBadge(value: row.change24h)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A wallet holding row: logo, symbol + amount, value + 24h.
private struct HoldingRow: View {
    let row: MarketRow
    /// Found in the wallet's history, not chosen in the app (`KnownTokenStore.unverified`).
    var unverified = false

    var body: some View {
        HStack(spacing: 12) {
            TokenLogo(token: row.token, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    TokenBadgeView(token: row.token, receivedUnasked: unverified)
                }
                AmountText(amount: row.balance, token: row.token, compact: true, font: .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.notTradingYet {
                // A Moment still collecting: no pool yet, so no price, and no value to show.
                Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    USDText(value: row.value, font: .subheadline.weight(.medium))
                    // Always surface the per-unit price next to the 24h change, even for tokens with a small balance.
                    HStack(spacing: 5) {
                        USDText(price: row.usd, font: .caption2).foregroundStyle(.secondary)
                        ChangeText(value: row.change24h, style: .caption2)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A launch-coin holding row: artwork, the held amount, and its USD value — the user's position, not the market cap —
/// at the price Home counts it at (`HomeTotals`), "—" without one.
private struct LaunchHoldingRow: View {
    let holding: HomeModel.LaunchHolding
    let value: Double?

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: holding.launch.symbol, logo: holding.launch.logo, pointSize: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.launch.symbol).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(NumberStyle.units(holding.balance, decimals: 18, compact: true)) \(holding.launch.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: value, font: .subheadline.weight(.medium))
                (holding.launch.phase == .bonding ? Text("\(holding.launch.progressBps / 100)% to graduation") : Text(verbatim: holding.launch.phase.title))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A perps position summarised for the holdings list.
private struct PositionSummaryRow: View {
    let position: PerpPosition

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(position.symbol).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(sideLabel) \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((position.side == .long ? Color.positive : Color.negative).opacity(0.15), in: Capsule())
                        .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                }
                Text("\(NumberStyle.number(position.size)) at \(NumberStyle.number(position.entry))", comment: "A perp position's size, then the price it was opened at")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(PriceFormat.usdValue(position.unrealized, signed: true))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
                Text("Unrealized", comment: "Under a perp position's unrealized profit or loss [tight]").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The position's side, for the chip beside its leverage ("Long 5×").
    private var sideLabel: String {
        position.side == .long
            ? tr(LocalizedStringResource("Long", comment: "A perp position's side: betting the price rises [tight]"))
            : tr(LocalizedStringResource("Short", comment: "A perp position's side: betting the price falls [tight]"))
    }
}

extension View {
    /// The standard grouped card: secondary surface, continuous corners, hairline separation from the ground.
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A token as the Home screen shows it: price, movement, and the signed-in wallet's balance. `info` is the price read as
/// it came (a DyorHQ coin's "vs MON", "New" and price source); `notTradingYet` marks a Moment still collecting, which
/// has no price yet.
struct MarketRow: Identifiable, Hashable {
    let token: Token
    let usd: Double?
    let change24h: Double?
    let balance: BigUInt
    var info: PriceInfo? = nil
    var notTradingYet = false
    var id: Address { token.address }
    var value: Double? { usd.map { Amount.units(balance, decimals: token.decimals) * $0 } }
}

@Observable
@MainActor
final class HomeModel {
    /// A launch coin the wallet holds (or created), with the Launch tab's price for it: Spot's, else its own decimal
    /// price (`DyorPrice.launch`); nil when neither is known.
    struct LaunchHolding: Identifiable, Hashable {
        let launch: Launch
        let balance: BigUInt
        let priceUSD: Double?
        var id: Address { launch.token }
        /// Whole coins held.
        var units: Double { Amount.units(balance, decimals: 18) }
        var valueUSD: Double? { priceUSD.map { units * $0 } }
    }

    private(set) var rows: [MarketRow] = []
    private(set) var launches: [Launch] = []
    private(set) var launchHoldings: [LaunchHolding] = []
    private(set) var positions: [PerpPosition] = []
    private(set) var perpEquity: Double?
    /// The wallet's Moments stakes (editions, entitlements, coins), valued at each graduated pool's price.
    private(set) var momentRows: [MomentPortfolioRow] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    /// Tokens the wallet was sent rather than chose (`KnownTokenStore.unverified`): marked in holdings, and never
    /// ranked in Top Tokens.
    private(set) var unverified: Set<Address> = []
    /// Whose data the model holds.
    private var loadedFor: Address?
    /// The registry taking in the coins of the launches and Moments the last load read (`DyorCoinsModel.ingest`).
    @ObservationIgnored private var ingesting: Task<Void, Never>?

    var holdings: [MarketRow] { rows.filter { $0.balance > 0 }.sorted { ($0.value ?? 0) > ($1.value ?? 0) } }

    /// Spot, Launch and Moments with every address counted once (`HomeTotals`): a DyorHQ coin stays listed in Spot but
    /// counts under Launch or Moments when that tab lists it, at the one price Spot shows for it.
    var totals: HomeTotals {
        HomeTotals(spot: holdings.map { HomeTotals.Line(address: $0.id, units: Amount.units($0.balance, decimals: $0.token.decimals), price: $0.usd) },
                   launch: launchHoldings.map { HomeTotals.Line(address: $0.id, units: $0.units, price: $0.priceUSD) },
                   moments: momentRows.map { HomeTotals.Line(address: $0.moment.moment.coin, units: Self.coins($0), price: WalletHoldings.momentPrice($0.moment)) })
    }

    /// A Moments stake's coins: held, plus still owed (entitled, not yet claimed).
    nonisolated static func coins(_ row: MomentPortfolioRow) -> Double {
        let owed = row.entitlement > row.claimed ? row.entitlement - row.claimed : 0
        return MomentsMath.coins(row.coinBalance) + MomentsMath.coins(owed)
    }

    /// The tokens no other tab counts (`HomeTotals.spot`).
    var spotValue: Double { totals.spot }
    var perpsValue: Double { perpEquity ?? 0 }
    /// Value of the launch coins the Launch tab lists. Feeds the allocation ring and total.
    var launchpadValue: Double { totals.launch }
    /// Value of the wallet's Moment coins (held plus still owed) at Spot's price or each pool's live one; a Moment with no
    /// market yet counts at zero.
    var momentsValue: Double { totals.moments }
    var availableBalance: Double { spotValue }
    var inUse: Double { perpsValue }

    var totalValue: Double? {
        rows.isEmpty ? nil : totals.total + perpsValue
    }

    /// Value-weighted 24h change of the wallet, when every priced holding has a change.
    var change24h: Double? {
        let priced = holdings.filter { $0.value != nil && $0.change24h != nil }
        let total = priced.compactMap(\.value).reduce(0, +)
        guard total > 0 else { return nil }
        return priced.reduce(0) { $0 + ($1.value! / total) * $1.change24h! }
    }

    /// Top-tokens list per tab. Popular keeps the curated order; the movers sort by 24h change; hot ranks by the
    /// strength of the move in either direction (a stand-in for volume, which the price service does not surface).
    func topTokens(_ tab: HomeTokenTab) -> [MarketRow] {
        let priced = rows.filter { $0.usd != nil && !unverified.contains($0.id) }
        switch tab {
        case .popular: return priced
        case .hot: return priced.sorted { abs($0.change24h ?? 0) > abs($1.change24h ?? 0) }
        case .gainers: return priced.filter { ($0.change24h ?? 0) > 0 }.sorted { ($0.change24h ?? 0) > ($1.change24h ?? 0) }
        case .losers: return priced.filter { ($0.change24h ?? 0) < 0 }.sorted { ($0.change24h ?? 0) < ($1.change24h ?? 0) }
        }
    }

    private var discoveredFor: Address?

    func poll(env: AppEnvironment, address: Address?) async {
        while !Task.isCancelled {
            await load(env: env, address: address)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Finds ERC-20s the wallet holds on-chain that aren't in its universe yet (received outside the app, airdropped,
    /// bridged), persists them to the shared token store as Unverified, and reloads — so every held token appears in
    /// holdings, marked, while the swap picker lists it only when searched for (IOST-12). Runs once per wallet; the
    /// persisted tokens then price and balance like any curated asset.
    func discoverHeldTokens(env: AppEnvironment, address: Address?) async {
        guard let address, discoveredFor != address else { return }
        discoveredFor = address
        let known = Set(KnownTokenStore.universe(owner: address).map(\.address))
        let found = await env.walletDiscovery.heldTokens(wallet: address, known: known)
        guard !found.isEmpty else { return }
        // Give each discovered token an accurate logo from Kuru's directory (the venues don't serve icons).
        let logos = await env.kuruTokens.logos()
        for token in found {
            let enriched = token.logoURL == nil && logos[token.address] != nil
                ? Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logos[token.address], isLaunchpad: token.isLaunchpad)
                : token
            KnownTokenStore.addDiscovered(enriched, owner: address)
        }
        await load(env: env, address: address)
    }

    func load(env: AppEnvironment, address: Address?) async {
        loading = true
        defer { loading = false }
        // Another account: nothing of the previous one's may stay on screen, even when a read below fails.
        if address != loadedFor {
            rows = []; launchHoldings = []; positions = []; perpEquity = nil; momentRows = []; updatedAt = nil
            loadedFor = address
        }
        // The curated list plus anything the wallet has acquired (swapped into, launched), so held tokens like an
        // RWA or a launched coin still show up with a balance and a price.
        let tokens = KnownTokenStore.universe(owner: address).filter { $0.symbol != "WMON" }
        // Which of them are DyorHQ coins, from their factories (MON, the curated tokens and coins already known cost
        // nothing): their pictures and labels, and the wallet's own coins below.
        async let proven: Void = env.dyorCoins.prove(tokens)
        async let prices = env.prices.prices(for: tokens)
        async let balances = walletBalances(env: env, address: address, tokens: tokens)
        async let launches = env.launchpad.launchListing(limit: 30)
        async let perps = loadPerps(env: env, address: address)
        async let moments = loadMoments(env: env, address: address)
        var priceMap: [Address: PriceInfo]?
        var priceError: Error?
        do { priceMap = try await prices } catch { priceError = error }
        // Moments still collecting, as the read just made found them: "Not trading yet" in place of a price.
        let notTrading = priceMap == nil ? [] : await env.prices.notTradingYet(tokens)
        let balanceMap = await balances
        // A launchpad whose launches couldn't be read keeps its last good ones, and the screen says so.
        let listing = await launches
        let launchList = listing.keeping(self.launches)
        let perpState = await perps
        let momentState = await moments
        // The registry takes in the coins of the launches and Moments just read without holding the rows back: their
        // pictures and labels follow once they are proven, as the coins model re-renders the rows. One at a time, so a
        // slow node never stacks them up across refreshes.
        if ingesting == nil {
            let readMoments = momentState?.map(\.moment) ?? []
            ingesting = Task {
                await env.dyorCoins.ingest(launchList)
                await env.dyorCoins.ingest(readMoments)
                ingesting = nil
            }
        }
        let holdings = await loadLaunchHoldings(env: env, address: address, launches: launchList, priceMap: priceMap ?? [:])
        await proven
        let ownCoins = address == nil ? [] : await env.dyorCoins.created(by: address ?? .zero)
        // A read that failed keeps what the last good one showed, and says so; a load cancelled part-way (the screen
        // went away, the account changed) publishes nothing (security audit 2026-09-26, RS-10).
        guard !Task.isCancelled, address == loadedFor else { return }
        // The coins the registry says this wallet made are its own, not Unverified: recorded as chosen through the helper
        // the Portfolio and the Send sheet use (`WalletTokens.markOwnCoins`). A coin it was only sent stays Unverified, out
        // of Top Tokens (IOST-12).
        if let address { WalletTokens.markOwnCoins(ownCoins, among: tokens, owner: address) }
        unverified = KnownTokenStore.unverified(owner: address)
        if let priceMap {
            let previous = Dictionary(rows.map { ($0.id, $0.balance) }, uniquingKeysWith: { first, _ in first })
            rows = tokens.map { token in
                // A price that isn't a positive number is none: the row shows "—", never "$0.00".
                let info = priceMap[token.address].flatMap { DyorPrice.valid($0.usd) != nil ? $0 : nil }
                return MarketRow(token: token, usd: info?.usd, change24h: info?.change24h,
                                 balance: balanceMap?[token.address] ?? previous[token.address] ?? 0, info: info, notTradingYet: notTrading.contains(token.address))
            }
        }
        if let priceError {
            error = describe(priceError)
        } else if balanceMap == nil {
            error = tr("Your balances couldn't be read just now — showing the last ones read.")
        } else if !listing.complete {
            error = tr("Some launch coins couldn't be read just now — showing the last ones read.")
        } else {
            error = nil
            updatedAt = .now
        }
        self.launches = launchList
        if let holdings, priceMap != nil { launchHoldings = holdings } // valued at the pair's price: not without one
        if let perpState {
            positions = perpState.positions
            perpEquity = perpState.equity
        }
        if let momentState { momentRows = momentState }
    }

    /// The wallet's Moments stakes, or nil when they couldn't be read.
    private func loadMoments(env: AppEnvironment, address: Address?) async -> [MomentPortfolioRow]? {
        guard let address, env.config.moments.isDeployed else { return [] }
        return (try? await env.moments.portfolio(account: address, limit: 100))?.rows
    }

    /// The wallet's balances of `tokens`, or nil when they couldn't be read (never read as zero).
    private func walletBalances(env: AppEnvironment, address: Address?, tokens: [Token]) async -> [Address: BigUInt]? {
        guard let address else { return [:] }
        return try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)
    }

    /// The wallet's launch-coin balances (and coins it created), each valued at the curve price × the pair asset's
    /// USD price, in one balanceOf multicall over the recent launches; nil when the balances couldn't be read.
    private func loadLaunchHoldings(env: AppEnvironment, address: Address?, launches: [Launch], priceMap: [Address: PriceInfo]) async -> [LaunchHolding]? {
        guard let address, !launches.isEmpty else { return [] }
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        guard let balances = try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall) else { return nil }
        return launches.compactMap { launch -> LaunchHolding? in
            let balance = balances[launch.token] ?? 0
            let created = launch.deployer == address
            // A coin the wallet created shows at a zero balance only while the board lists it: a retired launchpad's
            // sell-only coin shows only while held (owner decision 2026-09-29).
            guard balance > 0 || (created && launch.listsOnBoard) else { return nil }
            let pairUSD = launch.pair.isNative ? priceMap[Monad.native]?.usd : priceMap[launch.pairToken]?.usd
            return LaunchHolding(launch: launch, balance: balance, priceUSD: DyorPrice.launch(launch, spot: priceMap[launch.token]?.usd, pairUSD: pairUSD))
        }
        .sorted { ($0.valueUSD ?? 0) > ($1.valueUSD ?? 0) }
    }

    /// The Perpl account's positions and equity: none without an account, nil when a read failed.
    private func loadPerps(env: AppEnvironment, address: Address?) async -> (positions: [PerpPosition], equity: Double?)? {
        guard let address else { return ([], nil) }
        let found: PerpAccount?
        do { found = try await env.perpl.account(address) } catch { return nil }
        guard let account = found else { return ([], nil) }
        guard let markets = try? await env.perpl.markets(), let positions = try? await env.perpl.positions(account, markets: markets) else { return nil }
        let equity = Amount.units(account.balance, decimals: Perpl.collateralDecimals) + positions.reduce(0) { $0 + $1.unrealized }
        return (positions, equity)
    }
}

/// Price, 24h chart from on-chain history, and the actions that make sense for a token.
struct TokenDetailView: View {
    let row: MarketRow
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @State private var history: [PricePoint] = []
    @State private var loadingHistory = true
    /// Where the coin trades (`LaunchpadService.curveRoute(for:)`): Swap, or, while it is still on a launchpad's bonding
    /// curve (the live launchpad's or a retired one's), its Launch page, since no Swap venue routes a curve. Nil until
    /// read; `.unchecked` when the check failed, which keeps Swap and offers to check again.
    @State private var curveRoute: CurveRoute?
    @State private var checkingCurve = false
    /// The price read by the page itself, for a token Home's list didn't price (one opened from search, or a Moment Home
    /// last saw collecting).
    @State private var loaded: PriceInfo?
    /// Whether the page's own read found its Moment still collecting; nil until it has read, and Home's mark stands.
    @State private var loadedNotTrading: Bool?

    /// The price as shown: Home's read, else the page's own (`loaded`).
    private var info: PriceInfo? { row.info ?? loaded }
    private var price: Double? { row.usd ?? loaded.flatMap { DyorPrice.valid($0.usd) } }
    private var change: Double? { row.usd != nil ? row.change24h : loaded?.change24h }
    /// A Moment still collecting: no price and no chart, "Not trading yet" in their place. The page's own read decides
    /// once it has one, so a Moment that graduated since Home's read shows its price.
    private var notTradingYet: Bool { loadedNotTrading ?? row.notTradingYet }

    /// Sent to the wallet rather than chosen in the app (`KnownTokenStore.unverified`).
    private var received: Bool { KnownTokenStore.isUnverified(row.token.address, owner: session.address) }
    /// Its label (`TokenBadge`): a DyorHQ coin's, a look-alike's warning, Unverified, or none.
    private var badge: TokenBadge { env.dyorCoins.badge(row.token, receivedUnasked: received) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        TokenLogo(token: row.token, size: 44)
                        if notTradingYet {
                            Text("Not trading yet").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                USDText(price: price, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                                if info?.isNew == true { NewBadge() } else { ChangeBadge(value: change) }
                            }
                        }
                    }
                    // A DyorHQ coin: its move against its pair asset, then where its price comes from.
                    if !notTradingYet, let pairChange = info?.pairChangeText {
                        Text(pairChange).font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !notTradingYet, let source = info?.sourceLine {
                        Text(source).font(.footnote).foregroundStyle(.secondary)
                    }
                    if notTradingYet {
                        Text("Its Moment hasn't graduated yet, so the coin has no market. It trades once the Moment graduates.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Past 24 hours").font(.footnote).foregroundStyle(.secondary)
                        PriceChart(points: history, isLoading: loadingHistory, tint: (change ?? 0) < 0 ? Color.negative : Color.positive)
                            .frame(height: 180)
                    }
                }
                .padding(.vertical, 6)
            }
            if badge.isImitation, let title = badge.title {
                // A look-alike keeps its warning, whatever made it (a DyorHQ launch called USDC included).
                Section {
                    Label(title, systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Text("This token carries the name of another token but is a different contract. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if badge.isDyorHQ, let coin = env.dyorCoins.coin(row.token.address) {
                launchedOnDyorHQ(coin)
            } else if received || badge == .unverified {
                Section {
                    Label("Unverified token", systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Text(received
                         ? "This token arrived in your wallet without you choosing it in DyorHQ. Anyone can send any token to any wallet, with any name — including a real token's. Check the contract below before you trade it, and never follow a link or site its name points to."
                         : "This token's name or symbol has characters that can make it read as another. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if row.balance > 0 {
                Section("Your Balance") {
                    LabeledContent("Amount") { AmountText(amount: row.balance, token: row.token) }
                    LabeledContent("Value") {
                        if notTradingYet { Text("Not trading yet").foregroundStyle(.secondary) } else { USDText(value: price.map { Amount.units(row.balance, decimals: row.token.decimals) * $0 }) }
                    }
                }
            }
            Section("About") {
                LabeledContent("Name", value: row.token.displayName)
                if !row.token.isNative { AddressRow(title: "Contract", address: row.token.address) }
                LabeledContent("Decimals", value: String(row.token.decimals))
            }
            Section {
                if !SwapEngine.isTradable(row.token) {
                    // A retired cohort's Moment coin: past cohorts are claim-only, so no swap is offered.
                    Label("Past cohort · trading closed", systemImage: "lock").foregroundStyle(.secondary)
                } else if let route = curveRoute, route.isOnCurve, let title = route.actionTitle(row.token.symbol) {
                    // Never Swap: no venue routes a coin still on a launchpad's curve, live or retired. Its curve trades
                    // on its Launch page (Buy and Sell on the live launchpad, Sell only on a retired one), opened by
                    // reference when its launch couldn't be read.
                    Button(title, systemImage: "arrow.up.right.circle") { router.openLaunchPage(for: route) }
                } else {
                    Button("Swap \(row.token.symbol)", systemImage: "arrow.left.arrow.right") {
                        router.openSwap(tokenIn: row.token.symbol == "USDC" ? Token.mon : Token.usdc, tokenOut: row.token)
                    }
                    if curveRoute == .unchecked {
                        // The check failed: Swap stays, and so does the way to find out where the coin trades.
                        Button("Check Again", systemImage: "arrow.clockwise") { Task { await checkCurve() } }
                            .disabled(checkingCurve)
                    }
                }
                if let url = row.token.isNative ? nil : Monad.explorerToken(row.token.address) {
                    Link(destination: url) { Label("View on Monadscan", systemImage: "safari") }
                }
            } footer: {
                if SwapEngine.isTradable(row.token), let notice = curveRoute?.notice { Text(notice) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.token.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A token Home's list didn't price (opened from search, or a Moment Home last saw collecting) is priced here,
            // once: a Moment that graduated since shows its price and chart.
            if row.usd == nil {
                loaded = (try? await env.prices.prices(for: [row.token]))?[row.token.address]
                loadedNotTrading = await env.prices.notTradingYet([row.token]).contains(row.token.address)
            }
            if !notTradingYet { history = (try? await env.prices.history(for: row.token, points: 48)) ?? [] }
            loadingHistory = false
        }
        .task(id: row.token.address) { await checkCurve() }
    }

    /// Where a DyorHQ coin was made, from its factory's record (`DyorCoinsModel`): a launchpad or a Moments cohort, live
    /// or retired, the launch's phase once known (`curveRoute`), its creator, and a way to its Launch page or its Moment.
    /// It stands in for the Unverified card: a DyorHQ coin sent to the wallet is labelled for what it is, and anyone can
    /// launch one, which the footer says.
    private func launchedOnDyorHQ(_ coin: DyorCoin) -> some View {
        Section {
            LabeledContent("Made on", value: coin.isMoment ? (coin.retired ? tr("A past Moments cohort") : tr("DyorHQ Moments")) : (coin.retired ? tr("A retired DyorHQ launchpad") : tr("The DyorHQ launchpad")))
            if let phase = launchPhase { LabeledContent("Phase", value: phase.title) }
            AddressRow(title: "Creator", address: coin.creator)
            if let key = coin.momentKey {
                if let link = MomentLink(key: key) {
                    Button("Open the Moment", systemImage: "photo.on.rectangle") {
                        router.pendingMomentLink = link
                        router.tab = .moments
                    }
                }
            } else {
                Button("Open the Launch Page", systemImage: "arrow.up.right.circle") {
                    if let launch = curveRoute?.launch { router.openLaunch(launch) } else { router.openLaunch(LaunchReference(token: coin.address, factory: coin.factory)) }
                }
            }
        } header: {
            Text("Launched on DyorHQ")
        } footer: {
            Text("Anyone can launch a coin or publish a Moment on DyorHQ: this says where the coin was made, not that DyorHQ vouches for it.")
        }
    }

    /// A launch coin's phase, when the curve check read it: its launch's, or its factory's record's.
    private var launchPhase: LaunchPhase? {
        switch curveRoute {
        case .launchPage(let launch): return launch.phase
        case .launchUnread(_, _, let phase): return phase
        default: return nil
        }
    }

    /// Asks whether the coin is still on a launchpad's curve, and where it trades (one read of every known factory's
    /// record, then its launch). A graduated coin, or one no known launchpad launched, trades on Swap.
    private func checkCurve() async {
        checkingCurve = true
        defer { checkingCurve = false }
        let route = await env.launchpad.curveRoute(for: row.token)
        if Task.isCancelled { return }
        curveRoute = route
    }
}

/// "New" in place of a 24h change: a DyorHQ coin its factory hadn't recorded 24 hours ago (`PriceInfo.isNew`).
private struct NewBadge: View {
    var body: some View {
        Text("New", comment: "Badge for a coin too new to have a 24h change [tight]")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brand.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.brand)
    }
}

struct PriceChart: View {
    let points: [PricePoint]
    let isLoading: Bool
    let tint: Color

    /// The plotted range with a little headroom. An area mark anchors at zero by default, which flattens a
    /// 24-hour price line into a ruler, so the fill starts at this floor instead.
    private var domain: ClosedRange<Double> {
        let values = points.map(\.usd)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.08, abs(high) * 0.0005, 1e-12)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        if points.count >= 2 {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                AreaMark(x: .value("Time", point.time), yStart: .value("Floor", domain.lowerBound), yEnd: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: domain)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .chartYAxis {
                // Labels as fine as the plotted range needs (`PriceFormat.axis`), so a dust coin's ticks don't all read "0".
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let price = value.as(Double.self) { Text(PriceFormat.axis(price, span: domain.upperBound - domain.lowerBound)) } }
                }
            }
            .accessibilityLabel("Price over the past 24 hours")
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Price History", systemImage: "chart.line.downtrend.xyaxis", description: Text("This token has no pool with enough liquidity to chart."))
        }
    }
}


/// The home header, in the reference layout: the three-line menu button, a search field, and the profile avatar
/// on the right — the profile is one tap away from the top of the screen instead of a tab.
struct HomeHeader: View {
    @Binding var showSearch: Bool
    let error: String?
    let updatedAt: Date?
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social

    var body: some View {
        HStack(spacing: 10) {
            Button { Haptics.tap(); router.menuOpen = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel("Menu")

            Button { Haptics.tap(); showSearch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search tokens…").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let error {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.attention).accessibilityLabel(error)
                    } else if let updatedAt {
                        Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.body)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search tokens")

            Button { Haptics.tap(); router.presented = .notifications } label: {
                Image(systemName: NotificationHub.shared.unreadCount > 0 ? "bell.badge" : "bell")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.brand, Color.primary)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        let unread = NotificationHub.shared.unreadCount
                        if unread > 0 {
                            Text(verbatim: unread > 99 ? "99+" : "\(unread)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.negative, in: Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .accessibilityLabel("Notifications, \(NotificationHub.shared.unreadCount) unread")

            Button { Haptics.tap(); router.presented = .profile } label: {
                if let account = session.account, account.method == .watchOnly {
                    ZStack {
                        Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 44, height: 44)
                        Image(systemName: "eye").foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials, size: 44)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
}

/// A Moments stake row for the holdings list: media, name, editions and coins, then the value at the price Home counts
/// it at (`HomeTotals`); a Moment still collecting says "Not trading yet" in its place.
private struct MomentHoldingRow: View {
    let row: MomentPortfolioRow
    let value: Double?

    private var coins: Double { HomeModel.coins(row) }

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol, creator: row.moment.moment.creator)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(verbatim: "\(tr("\(row.nftBalance) editions")) · \(NumberStyle.number(coins, compact: true)) \(row.moment.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if row.moment.isNotTradingYet {
                    Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    USDText(value: value, font: .subheadline.weight(.medium))
                }
                Text(row.moment.graduated ? "Graduated" : row.moment.state == .expired ? "Expired" : "\(row.moment.progressBps / 100)% to graduation")
                    .font(.caption2).foregroundStyle(row.moment.graduated ? Color.positive : .secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
