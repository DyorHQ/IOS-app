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
    @State private var model = HomeModel()
    @State private var tokenTab: HomeTokenTab = .popular
    @State private var holdingTab: HoldingCategory = .spot
    @State private var showReceive = false
    @State private var showSend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    quickActions
                    if model.totalValue ?? 0 > 0 || !model.holdings.isEmpty { allocationCard }
                    topTokensCard
                    holdingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MarketRow.self) { row in TokenDetailView(row: row) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = model.error {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.attention).help(error)
                    } else if let updated = model.updatedAt {
                        Text(updated, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .refreshable { await model.load(env: env, address: session.address) }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .task(id: session.address) { await model.discoverHeldTokens(env: env, address: session.address) }
            .overlay { if model.rows.isEmpty, model.loading { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showSend) { SendSheet() }
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portfolio").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.totalValue ?? 0, format: .currency(code: "USD"))
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: model.totalValue ?? 0))
                        .redacted(reason: model.totalValue == nil ? .placeholder : [])
                    Spacer(minLength: 0)
                }
                ChangeBadge(value: model.change24h)
            }

            Divider()

            HStack(alignment: .top) {
                statColumn("Avail. Balance", value: model.availableBalance, tint: .primary)
                Spacer()
                statColumn("In Use", value: model.inUse, tint: model.inUse > 0 ? .positive : .primary, alignment: .trailing)
            }

            Divider()

            HStack(spacing: 0) {
                splitStat("Spot", model.spotValue, .allocationSpot)
                splitStat("Perps", model.perpsValue, .allocationPerps)
                splitStat("Launchpad", model.launchpadValue, .allocationLaunchpad)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func statColumn(_ title: String, value: Double, tint: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value, format: .currency(code: "USD")).font(.headline).monospacedDigit().foregroundStyle(tint)
        }
    }

    private func splitStat(_ title: String, _ value: Double, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value, format: .currency(code: "USD")).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            HomeAction(title: "Buy", symbol: "cart") { router.openSwap(tokenIn: .usdc, tokenOut: .mon) }
            HomeAction(title: "Deposit", symbol: "creditcard") { showReceive = true }
            HomeAction(title: "Withdraw", symbol: "arrow.up") { showSend = true }
            HomeAction(title: "Transfer", symbol: "arrow.left.arrow.right") { showSend = true }
        }
        .disabled(session.address == nil)
    }

    // MARK: Allocation

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation").font(.headline)
            AllocationDonut(
                segments: [
                    .init(label: "Spot", value: model.spotValue, color: .allocationSpot),
                    .init(label: "Perps", value: model.perpsValue, color: .allocationPerps),
                    .init(label: "Launchpad", value: model.launchpadValue, color: .allocationLaunchpad),
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
                        NavigationLink(value: row) { TokenListRow(rank: index + 1, row: row) }
                            .buttonStyle(.plain)
                        if index < min(5, tokens.count - 1) { Divider().padding(.leading, 44) }
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
                            NavigationLink(value: row) { HoldingRow(row: row) }.buttonStyle(.plain)
                            if index < model.holdings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .perps:
                if model.positions.isEmpty { holdingsEmpty("No open positions", "Open a perp on the Perps tab.") }
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
                        ForEach(Array(model.launchHoldings.enumerated()), id: \.element.id) { index, holding in
                            Button { router.openLaunch(holding.launch) } label: { LaunchHoldingRow(holding: holding) }
                                .buttonStyle(.plain)
                            if index < model.launchHoldings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func holdingsEmpty(_ title: String, _ detail: String) -> some View {
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
    var label: String { rawValue.capitalized }
}

enum HoldingCategory: String, CaseIterable, Identifiable {
    case spot, perps, launchpad
    var id: String { rawValue }
    var label: String { self == .launchpad ? "Launch" : rawValue.capitalized }
}

/// One of the four home actions: an SF Symbol over a label, filling its share of the row.
private struct HomeAction: View {
    let title: String
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
                    Text(total, format: .currency(code: "USD")).font(.subheadline.weight(.semibold)).monospacedDigit()
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

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 16, alignment: .center)
            TokenLogo(symbol: row.token.symbol, url: row.token.logoURL, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.token.symbol).font(.subheadline.weight(.semibold))
                Text(row.token.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            USDText(value: row.usd, font: .subheadline.weight(.medium))
            ChangeBadge(value: row.change24h)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A wallet holding row: logo, symbol + amount, value + 24h.
private struct HoldingRow: View {
    let row: MarketRow

    var body: some View {
        HStack(spacing: 12) {
            TokenLogo(symbol: row.token.symbol, url: row.token.logoURL, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.token.symbol).font(.subheadline.weight(.semibold))
                AmountText(amount: row.balance, token: row.token, compact: true, font: .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: row.value, font: .subheadline.weight(.medium))
                // Always surface the per-unit price next to the 24h change, even for tokens with a small balance.
                HStack(spacing: 5) {
                    USDText(value: row.usd, font: .caption2).foregroundStyle(.secondary)
                    ChangeText(value: row.change24h, style: .caption2)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A launch-coin holding row: artwork, the held amount, and its USD value — the user's position, not the market cap.
private struct LaunchHoldingRow: View {
    let holding: HomeModel.LaunchHolding

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: holding.launch.symbol, logo: holding.launch.logo)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.launch.symbol).font(.subheadline.weight(.semibold))
                Text("\(NumberStyle.units(holding.balance, decimals: 18, compact: true)) \(holding.launch.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: holding.valueUSD, font: .subheadline.weight(.medium))
                Text(holding.launch.phase == .bonding ? "\(holding.launch.progressBps / 100)% to graduation" : holding.launch.phase.title)
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
                    Text("\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((position.side == .long ? Color.positive : Color.negative).opacity(0.15), in: Capsule())
                        .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                }
                Text("\(NumberStyle.number(position.size)) at \(NumberStyle.number(position.entry))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(position.unrealized, format: .currency(code: "USD").sign(strategy: .always()))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
                Text("Unrealized").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

extension View {
    /// The standard grouped card: secondary surface, continuous corners, hairline separation from the ground.
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A token as the Home screen shows it: price, movement, and the signed-in wallet's balance.
struct MarketRow: Identifiable, Hashable {
    let token: Token
    let usd: Double?
    let change24h: Double?
    let balance: BigUInt
    var id: Address { token.address }
    var value: Double? { usd.map { Amount.units(balance, decimals: token.decimals) * $0 } }
}

@Observable
@MainActor
final class HomeModel {
    /// A launch coin the wallet holds (or created), valued at its curve price in USD.
    struct LaunchHolding: Identifiable, Hashable {
        let launch: Launch
        let balance: BigUInt
        let valueUSD: Double
        var id: Address { launch.token }
    }

    private(set) var rows: [MarketRow] = []
    private(set) var launches: [Launch] = []
    private(set) var launchHoldings: [LaunchHolding] = []
    private(set) var positions: [PerpPosition] = []
    private(set) var perpEquity: Double?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?

    var holdings: [MarketRow] { rows.filter { $0.balance > 0 }.sorted { ($0.value ?? 0) > ($1.value ?? 0) } }

    var spotValue: Double { holdings.compactMap(\.value).reduce(0, +) }
    var perpsValue: Double { perpEquity ?? 0 }
    /// Value of the wallet's launch-coin holdings, priced from each curve. Feeds the allocation ring and total.
    var launchpadValue: Double { launchHoldings.reduce(0) { $0 + $1.valueUSD } }
    var availableBalance: Double { spotValue }
    var inUse: Double { perpsValue }

    var totalValue: Double? {
        rows.isEmpty ? nil : spotValue + perpsValue + launchpadValue
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
        let priced = rows.filter { $0.usd != nil }
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
    /// bridged), persists them to the shared token store, and reloads — so every held token appears in holdings and
    /// the swap picker. Runs once per wallet; the persisted tokens then price and balance like any curated asset.
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
            KnownTokenStore.add(enriched, owner: address)
        }
        await load(env: env, address: address)
    }

    func load(env: AppEnvironment, address: Address?) async {
        loading = true
        defer { loading = false }
        // The curated list plus anything the wallet has acquired (swapped into, launched), so held tokens like an
        // RWA or a launched coin still show up with a balance and a price.
        let tokens = KnownTokenStore.universe(owner: address).filter { $0.symbol != "WMON" }
        async let prices = env.prices.prices(for: tokens)
        async let balances = walletBalances(env: env, address: address, tokens: tokens)
        async let launches = env.launchpad.launches(limit: 30)
        async let perps = loadPerps(env: env, address: address)
        var priceMap: [Address: PriceInfo] = [:]
        do {
            priceMap = try await prices
            let balanceMap = await balances
            rows = tokens.map { token in
                MarketRow(token: token, usd: priceMap[token.address]?.usd, change24h: priceMap[token.address]?.change24h, balance: balanceMap[token.address] ?? 0)
            }
            error = nil
            updatedAt = .now
        } catch {
            self.error = describe(error)
        }
        let launchList = (try? await launches) ?? []
        self.launches = launchList
        launchHoldings = await loadLaunchHoldings(env: env, address: address, launches: launchList, priceMap: priceMap)
        let perpState = await perps
        positions = perpState.positions
        perpEquity = perpState.equity
    }

    private func walletBalances(env: AppEnvironment, address: Address?, tokens: [Token]) async -> [Address: BigUInt] {
        guard let address else { return [:] }
        return (try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:]
    }

    /// The wallet's launch-coin balances (and coins it created), each valued at the curve price × the pair asset's
    /// USD price, in one balanceOf multicall over the recent launches.
    private func loadLaunchHoldings(env: AppEnvironment, address: Address?, launches: [Launch], priceMap: [Address: PriceInfo]) async -> [LaunchHolding] {
        guard let address, !launches.isEmpty else { return [] }
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        let balances = (try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:]
        return launches.compactMap { launch -> LaunchHolding? in
            let balance = balances[launch.token] ?? 0
            let created = launch.deployer == address
            guard balance > 0 || created else { return nil }
            let pairUSD = launch.pair.isNative ? priceMap[Monad.native]?.usd : priceMap[launch.pairToken]?.usd
            let value = pairUSD.map { Amount.units(balance, decimals: 18) * LaunchpadService.priceNumber(launch) * $0 } ?? 0
            return LaunchHolding(launch: launch, balance: balance, valueUSD: value)
        }
        .sorted { $0.valueUSD > $1.valueUSD }
    }

    private func loadPerps(env: AppEnvironment, address: Address?) async -> (positions: [PerpPosition], equity: Double?) {
        guard let address, let account = try? await env.perpl.account(address) else { return ([], nil) }
        let markets = (try? await env.perpl.markets()) ?? []
        let positions = (try? await env.perpl.positions(account, markets: markets)) ?? []
        let equity = Amount.units(account.balance, decimals: Perpl.collateralDecimals) + positions.reduce(0) { $0 + $1.unrealized }
        return (positions, equity)
    }
}

/// Price, 24h chart from on-chain history, and the actions that make sense for a token.
struct TokenDetailView: View {
    let row: MarketRow
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var history: [PricePoint] = []
    @State private var loadingHistory = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        USDText(value: row.usd, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                        ChangeBadge(value: row.change24h)
                    }
                    Text("Past 24 hours").font(.footnote).foregroundStyle(.secondary)
                    PriceChart(points: history, isLoading: loadingHistory, tint: (row.change24h ?? 0) < 0 ? Color.negative : Color.positive)
                        .frame(height: 180)
                }
                .padding(.vertical, 6)
            }
            if row.balance > 0 {
                Section("Your Balance") {
                    LabeledContent("Amount") { AmountText(amount: row.balance, token: row.token) }
                    LabeledContent("Value") { USDText(value: row.value) }
                }
            }
            Section("About") {
                LabeledContent("Name", value: row.token.name)
                if !row.token.isNative { AddressRow(title: "Contract", address: row.token.address) }
                LabeledContent("Decimals", value: String(row.token.decimals))
            }
            Section {
                Button("Swap \(row.token.symbol)", systemImage: "arrow.left.arrow.right") {
                    router.openSwap(tokenIn: row.token.symbol == "USDC" ? Token.mon : Token.usdc, tokenOut: row.token)
                }
                if let url = row.token.isNative ? nil : Monad.explorerToken(row.token.address) {
                    Link(destination: url) { Label("View on Monadscan", systemImage: "safari") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.token.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            history = (try? await env.prices.history(for: row.token, points: 48)) ?? []
            loadingHistory = false
        }
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
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
            .accessibilityLabel("Price over the past 24 hours")
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Price History", systemImage: "chart.line.downtrend.xyaxis", description: Text("This token has no pool with enough liquidity to chart."))
        }
    }
}
