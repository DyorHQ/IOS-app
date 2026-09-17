import BigInt
import Charts
import DyorKit
import PhotosUI
import SwiftUI

/// The launchpad: a discovery board of coins — graduated pools and coins still climbing their bonding curve — as an
/// image-forward two-column grid, plus the flow to launch a new one. Modeled on the Ponsfamily launchpad, rebuilt in
/// DyorHQ's serif / monochrome system with the Monad-purple accent.
struct LaunchpadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = LaunchpadModel()
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var query = ""
    @State private var sort: LaunchSort = .newest
    @State private var path: [Launch] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !env.config.launchpad.isDeployed {
                    ContentUnavailableView {
                        Label("Launchpad Not Live Yet", systemImage: "flame")
                    } description: {
                        Text("Launches appear here once the DyorHQ launchpad contracts are deployed on Monad.")
                    }
                } else {
                    board
                }
            }
            .navigationTitle("Launch")
            .navigationDestination(for: Launch.self) { launch in LaunchDetailView(launch: launch) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showProfile = true } label: { Label("My Launchpad", systemImage: "person.crop.circle") }
                        .disabled(!env.config.launchpad.isDeployed || session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showCreate = true } label: { Label("New Launch", systemImage: "plus.circle.fill") }
                        .disabled(!env.config.launchpad.isDeployed || !session.canSign)
                }
            }
            .searchable(text: $query, prompt: "Search coins")
            .refreshable { await model.load(env: env) }
            .task { await model.poll(env: env) }
            .overlay { if model.launches.isEmpty, model.loading, env.config.launchpad.isDeployed { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCreate) { CreateLaunchView(protocolInfo: model.protocolInfo) { Task { await model.load(env: env) } } }
            .sheet(isPresented: $showProfile) { LaunchpadProfileView() }
            .onChange(of: router.pendingLaunch) { _, launch in
                guard let launch else { return }
                if path.last != launch { path.append(launch) }
                router.pendingLaunch = nil
            }
            .onAppear { if let launch = router.pendingLaunch { path = [launch]; router.pendingLaunch = nil } }
        }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if graduated.isEmpty, climbing.isEmpty, !model.loading {
                    emptyState
                } else {
                    if !graduated.isEmpty { section(title: "Graduated", count: graduated.count, subtitle: "Cleared the graduation threshold", coins: graduated) }
                    exploreSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func section(title: String, count: Int, subtitle: String, coins: [Launch]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: count, subtitle: subtitle)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(coins) { launch in
                    NavigationLink(value: launch) { LaunchCard(launch: launch) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var exploreSection: some View {
        if !climbing.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Explore", count: climbing.count, subtitle: "Coins still climbing toward graduation")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LaunchSort.allCases) { option in
                            let selected = sort == option
                            Button { if sort != option { Haptics.selection(); sort = option } } label: {
                                Text(option.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(climbing) { launch in
                        NavigationLink(value: launch) { LaunchCard(launch: launch) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.brand.opacity(0.14), in: Capsule()).foregroundStyle(Color.brand)
            }
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame").font(.largeTitle).foregroundStyle(Color.brand)
            Text("No Launches Yet").font(.headline)
            Text("Be the first to launch a coin on DyorHQ.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canSign)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var matching: [Launch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.launches }
        return model.launches.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.symbol.localizedCaseInsensitiveContains(q) }
    }

    private var graduated: [Launch] {
        matching.filter { $0.phase == .graduated }.sorted { $0.launchedAt > $1.launchedAt }
    }

    private var climbing: [Launch] {
        let live = matching.filter { $0.phase == .bonding }
        switch sort {
        case .newest: return live.sorted { $0.launchedAt > $1.launchedAt }
        case .marketCap: return live.sorted { $0.marketCap > $1.marketCap }
        case .progress: return live.sorted { $0.progressBps > $1.progressBps }
        }
    }
}

enum LaunchSort: String, CaseIterable, Identifiable {
    case newest, marketCap, progress
    var id: Self { self }
    var title: String {
        switch self {
        case .newest: return "Newest"
        case .marketCap: return "Market Cap"
        case .progress: return "Near Graduation"
        }
    }
}

/// One coin in the discovery grid: an image-forward card with its badge, name, market cap and — while on the curve —
/// its progress toward graduation.
struct LaunchCard: View {
    let launch: Launch

    private var isGraduated: Bool { launch.phase == .graduated }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // A fixed square sized to the cell width, with the artwork cropped to fill it. Defining the square
                // with a Color spacer (instead of `.aspectRatio(.fill)` on the image, which reports a size larger than
                // its frame) keeps every card's height — and its tap area — bounded, so a wide or tall image can no
                // longer overflow its cell and spill onto the filter chips above (which was hijacking their taps).
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { LaunchArtwork(symbol: launch.symbol, logo: launch.logo) }
                    .clipped()
                badge
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(launch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(launch.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Market cap").font(.caption2).foregroundStyle(.secondary)
                        Text("\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    Text(RelativeTime.short(launch.launchedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
                if launch.phase == .bonding {
                    progress
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) // tap area is exactly the card, never its neighbours
    }

    @ViewBuilder private var badge: some View {
        if isGraduated {
            Label("Graduated", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.positive)
        } else if launch.progressBps >= 8000 {
            Text("\(launch.progressBps / 100)%")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.brand)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                    Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, Double(launch.progressBps) / 10_000), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(launch.progressBps / 100)% to graduation").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A compact launch row for lists (the Home page's launchpad holdings), as opposed to the discovery-grid card.
struct LaunchRow: View {
    let launch: Launch

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: launch.symbol, logo: launch.logo)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(launch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(launch.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                if launch.phase == .bonding {
                    Text("\(launch.progressBps / 100)% to graduation").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(launch.phase.title).font(.caption).foregroundStyle(launch.phase == .graduated ? Color.positive : .secondary)
                }
            }
            Spacer()
            Text("\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                .font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .padding(.vertical, 8)
    }
}

/// A coin's artwork: its uploaded image, or a monogram on a tinted ground when it has none.
struct LaunchArtwork: View {
    let symbol: String
    let logo: String

    var body: some View {
        if let url = URL(string: logo), url.scheme != nil {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else if phase.error != nil { placeholder }
                else { ZStack { Color(.tertiarySystemFill); ProgressView().controlSize(.small) } }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(symbol.prefix(2).uppercased())
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brand)
        }
    }
}

/// Compact relative age like "3h" / "2d" for the coin cards.
enum RelativeTime {
    static func short(_ unix: Int) -> String {
        guard unix > 0 else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - unix)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

@Observable
@MainActor
final class LaunchpadModel {
    private(set) var launches: [Launch] = []
    private(set) var protocolInfo: ProtocolInfo?
    private(set) var loading = false
    private(set) var error: String?

    func poll(env: AppEnvironment) async {
        while !Task.isCancelled {
            await load(env: env)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func load(env: AppEnvironment) async {
        guard env.config.launchpad.isDeployed else { return }
        loading = true
        defer { loading = false }
        do {
            async let info = env.launchpad.protocolInfo(extraPairTokens: Token.launchpadPairAssets)
            launches = try await env.launchpad.launches(limit: 60)
            protocolInfo = try? await info
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

/// One coin: price and progress, the curve's trades as candles, and the buy/sell ticket.
struct LaunchDetailView: View {
    let launch: Launch
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var detail: LaunchDetail?
    @State private var account: LaunchAccountView?
    @State private var trades: [CurveTrade] = []
    @State private var priceSeries: [PricePoint] = []
    @State private var pairUSD: Double?
    @State private var holders: Int?
    @State private var loadingTrades = true
    @State private var side: TradeSide = .buy
    @State private var amountText = ""
    @State private var buyQuote: BuyQuote?
    @State private var sellQuote: SellQuote?
    @State private var showConfirm = false
    @State private var showClaim = false
    @State private var showCreatorClaim = false
    @State private var showGraduate = false
    @State private var showFallback = false

    private var isCreator: Bool { session.address != nil && session.address == launch.deployer }

    /// The coin's price and market cap in USD, when the pair asset has a known dollar price.
    private var priceUSD: Double? { pairUSD.map { LaunchpadService.priceNumber(launch) * $0 } }
    private var marketCapUSD: Double? { pairUSD.map { Amount.units(launch.marketCap, decimals: launch.pair.decimals) * $0 } }
    /// 24h trading volume in pair units, and in USD when priced.
    private var volume24: Double { trades.filter { Date().timeIntervalSince1970 - Double($0.time) <= 86_400 }.reduce(0) { $0 + Amount.units($1.quoteAmount, decimals: $1.quoteDecimals) } }
    private var volume24USD: Double? { pairUSD.map { volume24 * $0 } }

    private enum TradeSide { case buy, sell }
    private var token: Token { Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18, logoURL: URL(string: launch.logo), isLaunchpad: true) }
    private var pairToken: Token { Token(address: launch.pair.address, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals) }
    private var rawAmount: BigUInt { Amount.parse(amountText, decimals: side == .buy ? launch.pair.decimals : 18) ?? 0 }

    var body: some View {
        List {
            headerSection
            statsSection
            chartSection
            if launch.phase == .bonding { ticketSection } else { graduatedSection }
            if let account, account.tokenBalance > 0 || account.pendingRewards > 0 { holdingsSection(account) }
            feesSection
            if !trades.isEmpty { tradesSection }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(launch.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: "\(side)-\(rawAmount)") { await quote() }
        .sheet(isPresented: $showConfirm) { confirmation }
        .sheet(isPresented: $showGraduate) {
            ConfirmationSheet(title: "Retry Graduation", confirmTitle: "Graduate", build: { env.launchpad.graduatePlan(launch: launch) }, onDone: { Task { await load() } }) {
                DetailRow("Venue", launch.graduationVenue.title)
                DetailRow("Who pays", "You (gas only)")
            }
        }
        .sheet(isPresented: $showFallback) {
            ConfirmationSheet(title: "Graduate on Uniswap v4", confirmTitle: "Graduate", build: { env.launchpad.graduateFallbackPlan(launch: launch) }, onDone: { Task { await load() } }) {
                DetailRow("Venue", "Uniswap v4 (fallback)")
                DetailRow("Who pays", "You (gas only)")
            }
        }
        .sheet(isPresented: $showClaim) {
            ConfirmationSheet(title: "Claim Rewards", confirmTitle: "Claim", build: { await env.launchpad.claimRewardsPlan(launch: launch, view: account) }, onDone: { Task { await load() } }) {
                if let account { DetailRow("Pending rewards", "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
        }
        .sheet(isPresented: $showCreatorClaim) {
            ConfirmationSheet(title: "Claim Creator Fees", confirmTitle: "Claim Fees", build: { env.launchpad.claimEscrowPlan(launch: launch) }, onDone: { Task { await load() } }) {
                if let account { DetailRow("Claimable", "\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
                DetailRow("To", session.address?.short ?? "—")
            }
        }
    }

    /// Creator fees and holder-fee-sharing transparency, mirroring Pons: everyone sees the fee mode, the creator can
    /// claim their escrowed fees here. Fee-sharing coins route creator fees to holders instead.
    private var feesSection: some View {
        Section {
            LabeledContent("Fee mode", value: launch.holderFeeSharing ? "Shared with holders" : "To creator")
            if launch.creatorTaxBps > 0 { LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps)) }
            AddressRow(title: "Fee recipient", address: launch.creatorFeeRecipient.isZero ? launch.deployer : launch.creatorFeeRecipient)
            if isCreator, !launch.holderFeeSharing {
                if let account, account.escrowBalance > 0 {
                    LabeledContent("Your claimable fees") {
                        Text("\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                            .monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.brand)
                    }
                    Button("Claim Creator Fees", systemImage: "banknote") { Haptics.tap(); showCreatorClaim = true }.disabled(!session.canSign)
                } else {
                    Text("Nothing to claim yet — fees accrue as people trade your coin.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Creator Fees")
        } footer: {
            Text(launch.holderFeeSharing
                ? "This coin routes its creator fees to holders — each holder claims their pro-rata share (see Your Holdings, or My Launchpad)."
                : "The creator earns their share of trading fees plus the creator tax; they accrue in the fee escrow and can be claimed any time. One claim sweeps fees across all your launches paired in this asset.")
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TokenLogo(symbol: launch.symbol, url: URL(string: launch.logo), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(launch.name).font(.title3.weight(.semibold))
                        Text(launch.phase.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(NumberStyle.number(LaunchpadService.priceNumber(launch))) \(launch.pair.symbol)")
                            .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                        if let priceUSD { Text(priceUSD, format: .currency(code: "USD").precision(.fractionLength(2...8))).font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)").monospacedDigit().fontWeight(.medium)
                        if let marketCapUSD { Text(marketCapUSD, format: .currency(code: "USD").precision(.fractionLength(0...2))).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        else { Text("Market cap").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if launch.phase == .bonding {
                    Gauge(value: Double(launch.progressBps) / 10_000) {
                        Text("Graduation")
                    } currentValueLabel: {
                        Text("\(launch.progressBps / 100)%")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Text("Graduates at \(NumberStyle.units(launch.graduationThreshold, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol) raised. Liquidity then moves to a locked \(launch.graduationVenue.title) pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chartSection: some View {
        Section {
            PriceChart(points: priceSeries, isLoading: loadingTrades, tint: chartTint)
                .frame(height: 180)
                .padding(.vertical, 4)
                .accessibilityLabel("Price from curve trades")
        } header: {
            Text("Price")
        } footer: {
            if trades.isEmpty, !loadingTrades {
                Text("No trades yet — the chart moves up as people buy on the curve and down as they sell.").font(.caption)
            }
        }
    }

    private var chartTint: Color {
        guard let first = priceSeries.first?.usd, let last = priceSeries.last?.usd, first != last else { return Color.brand }
        return last >= first ? Color.positive : Color.negative
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                stat("24h Volume", volume24USD.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) } ?? "\(NumberStyle.number(volume24)) \(launch.pair.symbol)")
                Divider().frame(height: 34)
                stat("Holders", holders.map { "\($0)" } ?? "—")
                Divider().frame(height: 34)
                stat("Progress", "\(launch.progressBps / 100)%")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tradesSection: some View {
        Section("Recent Trades") {
            ForEach(trades.reversed().prefix(25)) { trade in
                LaunchTradeRow(trade: trade, symbol: launch.symbol, pair: launch.pair)
            }
        }
    }

    private var ticketSection: some View {
        Section {
            Picker("Side", selection: $side) {
                Text("Buy").tag(TradeSide.buy)
                Text("Sell").tag(TradeSide.sell)
            }
            .pickerStyle(.segmented)
            AmountField(title: "0", text: $amountText, token: side == .buy ? pairToken : token) {
                guard let account else { return }
                amountText = side == .buy ? Amount.exact(account.pairBalance, decimals: launch.pair.decimals) : Amount.exact(account.tokenBalance, decimals: 18)
            }
            if side == .buy, let q = buyQuote, rawAmount > 0 {
                DetailRow("You receive", "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                DetailRow("Curve fee", "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.snipe > 0 { DetailRow("Early-buy tax", "\(NumberStyle.units(q.snipe, decimals: launch.pair.decimals)) \(launch.pair.symbol)", tint: Color.attention) }
                if q.refund > 0 { DetailRow("Refunded (curve full)", "\(NumberStyle.units(q.refund, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            if side == .sell, let q = sellQuote, rawAmount > 0 {
                DetailRow("You receive", "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                DetailRow("Curve fee", "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.tax > 0 { DetailRow("Creator tax", "\(NumberStyle.units(q.tax, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            PrimaryButton(title: side == .buy ? "Buy \(launch.symbol)" : "Sell \(launch.symbol)", isDisabled: rawAmount == 0 || !session.canSign) { showConfirm = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Trade on the Curve")
        } footer: {
            if !session.canSign { Text("Sign in to trade.") }
            else if let account { Text("Balance: \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)) \(launch.symbol) · \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
        }
    }

    private var graduatedSection: some View {
        Section {
            Button("Swap \(launch.symbol) on \(launch.graduationVenue.title)", systemImage: "arrow.left.arrow.right") {
                router.openSwap(tokenIn: pairToken.isNative ? Token.mon : pairToken, tokenOut: token)
            }
            if let detail, let key = detail.poolKey {
                LabeledContent("Pool fee", value: NumberStyle.basisPoints(key.fee / 100))
            }
            if isStuck, let detail {
                LabeledContent("Stuck since", value: Date(timeIntervalSince1970: TimeInterval(detail.stuckSince)).formatted(date: .abbreviated, time: .shortened))
                Button("Retry Graduation", systemImage: "arrow.clockwise") { showGraduate = true }.disabled(!session.canSign)
                if launch.graduationVenue == .monday {
                    Button("Graduate on Uniswap v4 Instead", systemImage: "arrow.triangle.branch") { showFallback = true }.disabled(!session.canSign)
                }
            }
        } header: {
            Text(launch.phase == .graduated ? "Graduated" : launch.phase.title)
        } footer: {
            if launch.phase == .graduated {
                Text("The curve's liquidity is permanently locked in a \(launch.graduationVenue.title) pool — trades now route through the Swap screen. Ongoing pool swap fees stay with the locked liquidity and aren't distributed to holders or the creator.")
            } else if isStuck {
                Text(launch.graduationVenue == .monday
                     ? "The last graduation attempt failed. Anyone can retry it; if Monday Trade keeps rejecting it, the launch can graduate into a locked Uniswap v4 pool right away instead."
                     : "The last graduation attempt failed. Anyone can retry it; you only pay the gas.")
            } else {
                Text("This launch is between phases. Trading resumes when migration completes.")
            }
        }
    }

    /// A completed curve whose migration reverted (the factory records `stuckSince`): the audit's rescue paths apply.
    private var isStuck: Bool { launch.phase != .graduated && (detail?.stuckSince ?? 0) > 0 }

    private func holdingsSection(_ account: LaunchAccountView) -> some View {
        Section("Your Holdings") {
            LabeledContent("Balance") { AmountText(amount: account.tokenBalance, token: token, compact: true) }
            if account.pendingRewards > 0 {
                LabeledContent("Pending rewards") { Text("\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
                Button("Claim Rewards", systemImage: "gift") { showClaim = true }.disabled(!session.canSign)
            }
            if let detail, detail.queuedRewards > 0 {
                // Rewards wait one block before they are shared out (audit fix against flash-loan reward sniping).
                LabeledContent("Queued for holders") { Text("\(NumberStyle.units(detail.queuedRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            if !launch.description.isEmpty { Text(launch.description).font(.subheadline) }
            AddressRow(title: "Token", address: launch.token)
            AddressRow(title: "Creator", address: launch.deployer)
            LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps))
            LabeledContent("Holder fee sharing", value: launch.holderFeeSharing ? "On" : "Off")
            LabeledContent("Graduation venue", value: launch.graduationVenue.title)
            ForEach(socialLinks, id: \.0) { label, url in
                Link(destination: url) { Label(label, systemImage: "link") }
            }
        }
    }

    private var socialLinks: [(String, URL)] {
        [("Website", launch.socials.website), ("X", launch.socials.twitter), ("Telegram", launch.socials.telegram), ("Discord", launch.socials.discord), ("Farcaster", launch.socials.farcaster)]
            .compactMap { label, value in URL(string: value).flatMap { $0.scheme != nil ? ($0.host() != nil ? (label, $0) : nil) : nil } }
    }

    @ViewBuilder private var confirmation: some View {
        if let address = session.address {
            if side == .buy, let q = buyQuote {
                ConfirmationSheet(title: "Buy \(launch.symbol)", confirmTitle: "Buy", build: { await env.launchpad.buyPlan(launch: launch, quoteIn: rawAmount, minTokensOut: q.tokensOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; Task { await load() } }, onCompleted: { hash in
                    ActivityLog.record(ActivityRecord(kind: .buy, title: "Bought \(launch.symbol)", subtitle: "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(rawAmount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)", hash: hash), owner: session.address)
                }) {
                    DetailRow("You pay", "\(NumberStyle.units(rawAmount, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("You receive", "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.tokensOut * 99 / 100, decimals: 18, compact: true)) \(launch.symbol) (1% slippage)")
                }
            } else if side == .sell, let q = sellQuote {
                ConfirmationSheet(title: "Sell \(launch.symbol)", confirmTitle: "Sell", build: { await env.launchpad.sellPlan(launch: launch, tokensIn: rawAmount, minQuoteOut: q.quoteOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; Task { await load() } }, onCompleted: { hash in
                    ActivityLog.record(ActivityRecord(kind: .sell, title: "Sold \(launch.symbol)", subtitle: "\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)", hash: hash), owner: session.address)
                }) {
                    DetailRow("You sell", "\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("You receive", "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.quoteOut * 99 / 100, decimals: launch.pair.decimals)) \(launch.pair.symbol) (1% slippage)")
                }
            }
        }
    }

    private func load() async {
        async let d = env.launchpad.launch(token: launch.token)
        async let t = env.launchpad.trades(curve: launch.curve, pair: launch.pair)
        async let h = env.launchpad.holderCount(token: launch.token, excluding: [launch.curve])
        async let pu = pairUSDPrice()
        if let address = session.address { account = try? await env.launchpad.accountView(launch, account: address) }
        detail = try? await d
        pairUSD = await pu
        let curveTrades = (try? await t) ?? []
        trades = curveTrades
        priceSeries = Self.priceSeries(trades: curveTrades, launch: launch, unit: pairUSD ?? 1)
        loadingTrades = false
        holders = await h
    }

    private func pairUSDPrice() async -> Double? {
        (try? await env.prices.prices(for: [pairToken]))?[pairToken.address]?.usd
    }

    /// A price line for the chart: one point per curve trade, always ending on the live price, with a launch-time
    /// baseline prepended so a coin with no trades still draws a flat line rather than an empty box. Sequential ids
    /// keep points distinct even when trades share a block.
    private static func priceSeries(trades: [CurveTrade], launch: Launch, unit: Double) -> [PricePoint] {
        let current = LaunchpadService.priceNumber(launch) * unit
        var points: [PricePoint] = []
        var idx: UInt64 = 0
        for trade in trades where trade.price > 0 {
            points.append(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(trade.time)), usd: trade.price * unit)); idx += 1
        }
        points.append(PricePoint(block: idx, time: Date(), usd: current)); idx += 1
        if points.count < 2 {
            points.insert(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(launch.launchedAt)), usd: current), at: 0)
        }
        return points
    }

    private func quote() async {
        guard rawAmount > 0, launch.phase == .bonding else { buyQuote = nil; sellQuote = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        if side == .buy {
            buyQuote = try? await env.launchpad.quoteBuy(curve: launch.curve, quoteIn: rawAmount, recipient: session.address ?? .zero)
        } else {
            sellQuote = try? await env.launchpad.quoteSell(curve: launch.curve, tokensIn: rawAmount)
        }
    }
}

/// One curve fill in the token page's recent-trades list: buy/sell, the token amount, the pair amount, and when — a
/// tap opens the transaction on Monadscan.
private struct LaunchTradeRow: View {
    let trade: CurveTrade
    let symbol: String
    let pair: PairInfo

    var body: some View {
        Group {
            if let hash = trade.transactionHash {
                Link(destination: Monad.explorerTransaction(hash)) { rowContent }.foregroundStyle(.primary)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: trade.isBuy ? "arrow.down.left" : "arrow.up.right")
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .background((trade.isBuy ? Color.positive : Color.negative).opacity(0.14), in: Circle())
                .foregroundStyle(trade.isBuy ? Color.positive : Color.negative)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(trade.isBuy ? "Buy" : "Sell") \(NumberStyle.units(trade.tokenAmount, decimals: 18, compact: true)) \(symbol)")
                    .font(.subheadline.weight(.medium))
                Text(trade.trader.short).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(NumberStyle.units(trade.quoteAmount, decimals: pair.decimals, compact: true)) \(pair.symbol)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(trade.time)) ago").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Launch a coin: pick its image, name and ticker, describe it, choose the pairing asset and economics, optionally
/// buy first. A live "Your coin" card mirrors the discovery grid as you fill it in — the Ponsfamily create flow in
/// DyorHQ's system.
struct CreateLaunchView: View {
    let protocolInfo: ProtocolInfo?
    let onLaunched: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var description = ""
    @State private var logo = ""
    @State private var website = ""
    @State private var twitter = ""
    @State private var telegram = ""
    @State private var pair: Address = .zero
    @State private var venue: GraduationVenue = .uniswapV4
    @State private var creatorTaxBps = 0
    @State private var holderFeeSharing = true
    @State private var initialBuyText = ""
    @State private var showAdvanced = false
    @State private var showConfirm = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadingImage = false
    @State private var imageError: String?

    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && symbolValid }
    private var pairInfo: PairInfo? { protocolInfo?.pairs.first { $0.pair.address == pair }?.pair }
    private var initialBuy: BigUInt { Amount.parse(initialBuyText, decimals: pairInfo?.decimals ?? 18) ?? 0 }
    /// aBIL (and any `pairMondayOnly` pair) can only graduate on Monday Trade; the factory reverts `PairRequiresMonday`
    /// if a v4 venue is submitted for one. The picker is then forced to Monday and disabled.
    private var pairMondayOnly: Bool { protocolInfo?.pairs.first { $0.pair.address == pair }?.mondayOnly ?? false }
    /// The venue actually submitted: forced to Monday for Monday-only pairs regardless of the picker's state.
    private var effectiveVenue: GraduationVenue { pairMondayOnly ? .monday : venue }

    var body: some View {
        NavigationStack {
            Form {
                imageSection
                previewSection

                Section("Coin") {
                    TextField("Name", text: $name)
                    TextField("Ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                }
                Section("Links") {
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("X profile", text: $twitter).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Telegram", text: $telegram).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Paired with", selection: $pair) {
                        ForEach(protocolInfo?.pairs.filter(\.approved) ?? [], id: \.pair.address) { Text($0.pair.symbol).tag($0.pair.address) }
                    }
                    Picker("Graduates on", selection: $venue) {
                        Text(GraduationVenue.uniswapV4.title).tag(GraduationVenue.uniswapV4)
                        Text(GraduationVenue.monday.title).tag(GraduationVenue.monday)
                    }
                    .disabled(pairMondayOnly)
                    .onChange(of: pair) { _, _ in if pairMondayOnly { venue = .monday } }
                } header: {
                    Text("Pairing")
                } footer: {
                    if let info = protocolInfo, let pi = pairInfo {
                        Text("Graduates to a locked \(effectiveVenue.title) pool once the curve raises \(NumberStyle.units(pairGraduation, decimals: pi.decimals, compact: true)) \(pi.symbol).\(pairMondayOnly ? " \(pi.symbol) coins graduate on Monday Trade." : "") Launch fee \(NumberStyle.units(info.launchFee, decimals: 18)) MON.")
                    }
                }
                Section {
                    AmountField(title: "0", text: $initialBuyText, token: pairInfo.map { Token(address: $0.address, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) })
                } header: {
                    Text("Developer Buy (Optional)")
                } footer: {
                    Text("Buy your own coin in the same transaction — snipe-tax exempt.")
                }
                advancedSection
            }
            .navigationTitle("Launch a Coin")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { Haptics.tap(); showConfirm = true }.fontWeight(.semibold).disabled(!valid) }
            }
            .sheet(isPresented: $showConfirm) {
                if let address = session.address, let info = protocolInfo {
                    // Use the async plan: it reads the launch fee and the on-chain economics hash the factory
                    // requires (`expectedEconomics`). The sync overload leaves that hash zero → LaunchEconomicsMismatch.
                    ConfirmationSheet(
                        title: "Launch \(symbol)", confirmTitle: "Launch \(symbol)",
                        build: { try await env.launchpad.launchPlan(input, from: address) },
                        onDone: { dismiss(); onLaunched() },
                        onCompleted: { hash in
                            ActivityLog.record(ActivityRecord(kind: .launch, title: "Launched $\(symbol)", subtitle: name.isEmpty ? symbol : name, hash: hash), owner: session.address)
                        },
                        onView: { hash in
                            // Route to the coin's in-app page instead of the block explorer (the explorer link lives
                            // in Recent Activity). Resolve the new token from the launch tx, then open its page.
                            // "View" and "Done" are mutually exclusive, so record here too (de-duped by hash) — a
                            // launch tapped straight through to its page still lands in Recent Activity.
                            ActivityLog.record(ActivityRecord(kind: .launch, title: "Launched $\(symbol)", subtitle: name.isEmpty ? symbol : name, hash: hash), owner: session.address)
                            Task {
                                let detail = (try? await env.launchpad.launchResult(transaction: hash)).flatMap { $0 }
                                if let result = detail, let launch = (try? await env.launchpad.launch(token: result.token)) ?? nil {
                                    router.openLaunch(launch.launch)
                                    dismiss()
                                } else {
                                    _ = await UIApplication.shared.open(Monad.explorerTransaction(hash))
                                }
                            }
                        }
                    ) {
                        DetailRow("Coin", "\(name) ($\(symbol))")
                        DetailRow("Paired with", pairInfo?.symbol ?? "MON")
                        DetailRow("Graduation", pairInfo.map { "\(NumberStyle.units(pairGraduation, decimals: $0.decimals, compact: true)) \($0.symbol)" } ?? "—")
                        DetailRow("Graduation venue", effectiveVenue.title)
                        DetailRow("Creator tax", NumberStyle.basisPoints(creatorTaxBps))
                        DetailRow("Fee sharing", holderFeeSharing ? "On" : "Off")
                        DetailRow("Launch fee", "\(NumberStyle.units(info.launchFee, decimals: 18)) MON")
                        if initialBuy > 0 { DetailRow("Developer buy", "\(initialBuyText) \(pairInfo?.symbol ?? "MON")") }
                    }
                }
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await uploadImage(item) } } }
            .onAppear { if pair.isZero, let first = protocolInfo?.pairs.first(where: \.approved) { pair = first.pair.address } }
        }
    }

    private var imageSection: some View {
        Section {
            HStack(spacing: 16) {
                LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(logo.isEmpty ? "Choose Image" : "Change Image", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(uploadingImage)
                    if uploadingImage {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }
                    } else if let imageError {
                        Text(imageError).font(.caption).foregroundStyle(Color.attention)
                    } else {
                        Text("Square images look best.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var previewSection: some View {
        if valid {
            Section {
                LaunchPreviewCard(name: name, symbol: symbol, logo: logo, pairSymbol: pairInfo?.symbol ?? "MON")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Your Coin")
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper("Creator tax \(NumberStyle.basisPoints(creatorTaxBps))", value: $creatorTaxBps, in: 0...(protocolInfo?.maxCreatorTaxBps ?? 0), step: 25)
                Toggle("Share fees with holders", isOn: $holderFeeSharing).tint(.brand)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Creator tax is charged on curve trades and paid to you. Fee sharing splits post-graduation pool fees with everyone who holds the coin.")
        }
    }

    private var pairGraduation: BigUInt {
        protocolInfo?.pairs.first { $0.pair.address == pair }?.graduationThreshold ?? 0
    }

    private func uploadImage(_ item: PhotosPickerItem) async {
        uploadingImage = true; imageError = nil
        defer { uploadingImage = false; photoItem = nil }
        do {
            // Uploading needs a DyorHQ Social session (same wallet); connect on demand.
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { imageError = "Connect DyorHQ Social to upload an image."; return }
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.avatarJPEG(maxDimension: 640) else {
                imageError = "That image could not be read."
                return
            }
            logo = try await social.uploadLaunchImage(jpeg: jpeg).absoluteString
            Haptics.success()
        } catch {
            imageError = describe(error)
        }
    }

    private var input: LaunchInput {
        LaunchInput(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, description: description, logo: logo, socials: Socials(twitter: twitter, telegram: telegram, discord: "", website: website, farcaster: ""), creatorTaxBps: creatorTaxBps, holderFeeSharing: holderFeeSharing, graduationVenue: effectiveVenue, pairToken: pair, initialBuy: initialBuy)
    }
}

/// The live preview shown while creating a coin — the same shape as a discovery-grid card.
private struct LaunchPreviewCard: View {
    let name: String
    let symbol: String
    let logo: String
    let pairSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? "Your coin" : name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(symbol.isEmpty ? "TICKER" : symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("New").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.brand.opacity(0.14), in: Capsule())
                    Spacer()
                    Text("Pairs with \(pairSymbol)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
