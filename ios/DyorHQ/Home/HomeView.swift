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
                    if let split = model.split, split.total > 0 || !model.holdings.isEmpty { allocationCard(split) }
                    topTokensCard
                    holdingsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.snappy, value: funding.phase)
                // Nothing here is animated by a saved line: an animation keyed to one animates whatever changes with it —
                // the figures a read brought, the screen's first layout, a `Paragraph`'s words — and drew the Moments board
                // garbled on its first opening (build 23 speed work). Home's own line sits under the balance, beside Total
                // Volume's column, so the card keeps its height when it goes while that column is the taller (`savedLine`).
            }
            .background(Color(.systemGroupedBackground))
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { HomeHeader(showSearch: $showSearch, error: model.error ?? volumeError, updatedAt: model.updatedAt) }
            .navigationDestination(for: MarketRow.self) { row in TokenDetailView(row: row) }
            .navigationDestination(item: $searchTarget) { row in TokenDetailView(row: row) }
            // A pull awaits Home's own reads, side by side, never a round of the history: that reads on behind the screen
            // (`HistoryModel.kick`), and Total Volume follows it (`env.history.version`).
            // The reads run in a task of their own: SwiftUI cancels a pull's action when the list redraws under it (the
            // loads' own `loading` changes do), and a cancelled load publishes nothing, so a pull used to end with Home
            // unchanged. The spinner still waits for both. The reads the screens share are read again first
            // (`invalidateChainReads`): a pull asks for what is on chain now.
            .refreshable {
                env.invalidateChainReads()
                env.history.kick(env: env)
                await Task {
                    async let home: () = model.load(env: env, address: session.address)
                    async let portfolio: () = env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: true, passkey: session.isPasskeyAccount)
                    _ = await (home, portfolio)
                }.value
            }
            // What was saved for the wallet — Home's parts and the Portfolio's Total Volume — is in Home's first frame,
            // never placeholders under figures the phone has (`HomeModel.showSaved`, `PortfolioModel.showSaved`): small
            // files on the device, read here, before that frame, rather than in the loads' tasks, which start after it.
            // Never animated: nothing moves as they come in.
            .onAppear {
                withTransaction(\.disablesAnimations, true) {
                    model.showSaved(env: env, address: session.address)
                    env.portfolio.showSaved(env: env, address: session.address)
                }
            }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .task(id: session.address) { await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: false, passkey: session.isPasskeyAccount) }
            // The history fills in behind the screen (`HistoryModel`): Total Volume follows it, and the tokens it shows
            // the wallet received join the holdings.
            .task(id: env.history.version) {
                env.portfolio.applyHistory(env.history.snapshot, version: env.history.version, for: session.address)
                await model.discoverHeldTokens(env: env, address: session.address)
            }
            // A Perpl key that appears (a passkey session unlocked) loads the perps history the last load lacked.
            .task(id: perplTrading.key != nil) {
                if perplTrading.key != nil { await env.portfolio.load(env: env, address: session.address, perplKey: perplTrading.key, force: false, passkey: session.isPasskeyAccount) }
            }
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
                // Balances only once read in this session: never saved ones beside the search.
                TokenPickerSheet(selected: .mon, balances: model.reads.isSaved(.spot) ? [:] : Dictionary(uniqueKeysWithValues: model.rows.map { ($0.token.address, $0.balance) }), universe: KnownTokenStore.universe(owner: session.address), tradableOnly: false,
                                 unverified: KnownTokenStore.unverified(owner: session.address)) { token in
                    // Open the token's page; a token outside the priced list gets a bare row (price loads on the page).
                    searchTarget = model.rows.first { $0.token.address == token.address }.map(pageRow) ?? MarketRow(token: token, usd: nil, change24h: nil, balance: 0)
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
                // The total and the day's move in it wait for every part of the wallet (`HomeModel.totalValue`).
                let unread = model.totalValue == nil
                VStack(alignment: .leading, spacing: 4) {
                    Text(PriceFormat.usdValue(model.totalValue ?? 0))
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: model.totalValue ?? 0))
                        .unreadFigure(unread)
                    HStack(spacing: 8) {
                        Text(PriceFormat.usdValue(changeAmount, signed: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(unread ? Color.secondary : changeAmount < 0 ? Color.negative : Color.positive)
                        ChangeBadge(value: unread ? 0 : model.change24h ?? 0)
                    }
                    .unreadFigure(unread)
                    if let savedAt = model.savedAt { savedLine(savedAt) }
                }
                Spacer(minLength: 8)
                totalVolume
            }

            Divider()

            HStack(alignment: .top) {
                statColumn("Avail. Balance", value: model.availableBalance, tint: .primary)
                Spacer()
                statColumn("In Use", value: model.inUse, tint: (model.inUse ?? 0) > 0 ? .positive : .primary, alignment: .trailing)
            }

            Divider()

            HStack(spacing: 10) {
                splitStat(.spot, model.spotValue, .allocationSpot)
                splitStat(.perps, model.perpsValue, .allocationPerps)
                splitStat(.launchpad, model.launchpadValue, .allocationLaunchpad)
                splitStat(.moments, model.momentsValue, .allocationMoments)
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

    /// The wallet's chain history couldn't be read to the head, or the Portfolio's load landed with part of what Total
    /// Volume is built from unread — a launchpad, the Moments, a past cohort, the prices (`PortfolioModel.error`; the
    /// Portfolio says the same, in full): the header's warning, so a Total Volume short of some trades is never taken for
    /// the whole, and one saved when last read in full, kept meanwhile (`PortfolioModel.showsLive`), is said to be beside
    /// why.
    private var volumeError: String? {
        env.portfolio.historyUnreachable || env.portfolio.error != nil
            ? tr("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.") : nil
    }

    /// Total Volume for the period, right-aligned, with the period menu (24h · 7 days · 30 days · All) under it —
    /// the same figure the Portfolio breaks down by section. Tapping the number opens the Portfolio. Until the Portfolio
    /// has loaded and the chain history has been read at all, the figure saved when the wallet was last read in full,
    /// said to be ("Updated 3 hr ago", `volumeSavedAt`), else a placeholder (never "$0.00" ahead of it): the figure then
    /// follows the history as it fills in, said to be read on until the scans it is built from
    /// (`WalletHistoryScans.volume`) have read the period's own window — the last day long before the last month.
    private var totalVolume: some View {
        @Bindable var router = router
        let volume = shownVolume
        return VStack(alignment: .trailing, spacing: 4) {
            Button { Haptics.tap(); router.presented = .portfolio } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total Volume").font(.subheadline).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(volume ?? 0))
                        .font(.headline).monospacedDigit().foregroundStyle(.primary)
                        .contentTransition(.numericText(value: volume ?? 0))
                        .unreadFigure(volume == nil)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Total volume \(router.period.label)")
            if let volumeSavedAt {
                // The saved figure says when it was read right under it: Home's own parts can all be read again while the
                // Portfolio's heavier load hasn't landed, and its line under the balance is theirs alone.
                SavedLine(date: volumeSavedAt, reading: env.portfolio.loading)
            } else if liveVolume, env.history.snapshot.read, env.portfolio.historyFilling(router.period, scans: WalletHistoryScans.volume) {
                // The figure follows the history as it fills in: how far the period's window has got, so a figure short
                // of older trades is never taken for the whole. Not before the store's instant read has landed (`read`):
                // the figure is a placeholder until then, and the line would flash "0%".
                Text("Reading your history… \(NumberStyle.percent(env.portfolio.historyProgress(router.period, scans: WalletHistoryScans.volume) * 100, fractionDigits: 0, signed: false))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
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

    /// Total Volume shows the Portfolio's figure once its load has landed with the history's first read (`liveVolume`),
    /// unless that load left part of it unread while a figure saved when the wallet was last read in full stays
    /// (`PortfolioModel.showsLive`); until then the saved one (`PortfolioModel.savedTotals`), said to be under it
    /// (`volumeSavedAt`); else nil, a placeholder.
    private var liveVolume: Bool { env.portfolio.showsLive(router.period) && (session.address == nil || env.history.snapshot.anchor != nil) }
    private var shownVolume: Double? {
        liveVolume ? env.portfolio.totals(router.period).volume : env.portfolio.savedTotals(router.period)?.volume
    }

    /// When the saved Total Volume shown was read; nil while the figure is the Portfolio's load (`liveVolume`), or a
    /// placeholder.
    private var volumeSavedAt: Date? { liveVolume ? nil : env.portfolio.savedAt(router.period) }

    /// Said under the balance and its day's move while a part of the wallet shows what was saved when it was last read
    /// (`HomeModel.savedAt`), with a spinner while Home reads them again: a saved figure is never taken for a fresh one.
    /// Total Volume says its own under it (`volumeSavedAt`). In the balance's column, beside Total Volume's: while that
    /// column is the taller — Total Volume saying when its own saved figure was read, or how far the history has got, as
    /// on a warm launch, where Home's parts are read again first — the card keeps its height when the line goes, and
    /// nothing below it moves. Never animated (`HomeView.body`).
    private func savedLine(_ date: Date) -> some View {
        SavedLine(date: date, reading: model.loading)
    }

    /// `value` nil: the part it comes from isn't read for the wallet yet, so a placeholder (`unreadFigure`).
    private func statColumn(_ title: LocalizedStringKey, value: Double?, tint: Color, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(PriceFormat.usdValue(value ?? 0)).font(.headline).monospacedDigit().foregroundStyle(tint)
                .unreadFigure(value == nil)
        }
    }

    /// One of the four categories under the balance, named as My Holdings' switch names it. `value` nil: the category
    /// isn't read for the wallet yet (a failed read included), so a placeholder (`unreadFigure`).
    private func splitStat(_ category: HoldingCategory, _ value: Double?, _ dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(verbatim: category.label).font(.caption).foregroundStyle(.secondary)
            }
            Text(PriceFormat.usdValue(value ?? 0))
                .font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .unreadFigure(value == nil)
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

    /// Drawn once every part is read for the wallet (`HomeModel.split`), so no share is a part not read yet.
    private func allocationCard(_ split: HomeModel.Split) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation").font(.headline)
            AllocationDonut(
                segments: [
                    .init(label: tr("Spot"), value: split.spot, color: .allocationSpot),
                    .init(label: tr("Perps"), value: split.perps, color: .allocationPerps),
                    .init(label: tr("Launchpad"), value: split.launch, color: .allocationLaunchpad),
                    .init(label: tr("Moments"), value: split.moments, color: .allocationMoments),
                ],
                total: split.total
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
                        NavigationLink(value: pageRow(row)) { TokenListRow(rank: index + 1, row: row, rankWidth: rankWidth) }
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

            // A tab says it holds none only once its part of the wallet was read (`HomeReadState`): before, a loading row,
            // or that it couldn't be read, with Retry.
            switch holdingTab {
            case .spot:
                if model.holdings.isEmpty {
                    if model.reads.hasFigures(.spot) { holdingsEmpty("No spot balances", "Buy or swap a token and it appears here.") }
                    else { holdingsUnreadRow(.spot, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.holdings.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: pageRow(row)) { HoldingRow(row: row, unverified: model.unverified.contains(row.id)) }.buttonStyle(.plain)
                            if index < model.holdings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.spot)
            case .perps:
                // The positions are never saved (only the equity is): "none" only once they were read in this session.
                if model.positions.isEmpty {
                    if model.reads.isRead(.perps) { holdingsEmpty("No open positions", "Open a perp from the Trade tab.") }
                    else { holdingsUnreadRow(.perps, reading: "Reading your positions…") }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.positions.enumerated()), id: \.element.id) { index, position in
                            Button { router.openPerp(id: position.perpId) } label: { PositionSummaryRow(position: position) }
                                .buttonStyle(.plain)
                            if index < model.positions.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
            case .launchpad:
                if model.launchHoldings.isEmpty {
                    if model.reads.hasFigures(.launch) { holdingsEmpty("No launch holdings", "Buy or launch a coin on the Launch tab.") }
                    else { holdingsUnreadRow(.launch, reading: "Reading your balances…") }
                } else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.launchHoldings.enumerated()), id: \.element.id) { index, holding in
                            // Every launch holding opens its own Launch page, never Swap: a coin still on a curve (the
                            // live launchpad's or a retired one's) trades there, and a graduated one's page leads to Swap.
                            Button { openLaunch(holding.launch) } label: { LaunchHoldingRow(holding: holding, value: totals.value(of: holding.id, units: holding.units)) }
                                .buttonStyle(.plain)
                            if index < model.launchHoldings.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                    // Read from the launchpads read so far, while one never has been, or saved when last read and not read
                    // since: the rest are said to be missing.
                    if model.reads.status(.launch) == .failed { holdingsRetryRow("Some launch coins couldn't be read just now — showing the last ones read.") }
                }
                if model.launchHoldings.isEmpty { savedUnreadRow(.launch) }
            case .moments:
                if model.momentRows.isEmpty {
                    if model.reads.hasFigures(.moments) { holdingsEmpty("No Moments yet", "Collect a Moment on the Moments tab and your editions and coins appear here.") }
                    else { holdingsUnreadRow(.moments, reading: "Reading your Moments…") }
                } else {
                    VStack(spacing: 0) {
                        let totals = model.totals
                        ForEach(Array(model.momentRows.enumerated()), id: \.element.id) { index, row in
                            Button { openMoment(row.moment) } label: { MomentHoldingRow(row: row, value: totals.value(of: row.moment.moment.coin, units: HomeModel.coins(row))) }
                                .buttonStyle(.plain)
                            if index < model.momentRows.count - 1 { Divider().padding(.leading, 44) }
                        }
                    }
                }
                savedUnreadRow(.moments)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// The row a token's page opens with. While Spot shows what was saved when the wallet was last read
    /// (`HomeReadState.isSaved`), the token alone: the page reads its price and chart itself, and shows no balance not read
    /// in this session — a token page shows the row it is given as current.
    private func pageRow(_ row: MarketRow) -> MarketRow {
        model.reads.isSaved(.spot) ? MarketRow(token: row.token, usd: nil, change24h: nil, balance: 0) : row
    }

    /// A launch holding's page. One saved when the wallet was last read (`HomeReadState.isSaved`) opens by reference, so
    /// the page reads it now: a launch page shows the launch it is given as current — its price, its phase, which trades
    /// are open.
    private func openLaunch(_ launch: Launch) {
        if model.reads.isSaved(.launch) {
            router.openLaunch(LaunchReference(token: launch.token, factory: launch.factory))
        } else {
            router.openLaunch(launch)
        }
    }

    /// A Moment holding's page. One saved when the wallet was last read (`HomeReadState.isSaved`) opens by its link, so the
    /// page reads the Moment now (`MomentLinkView`): a Moment's page shows the Moment it is given as current — its state,
    /// its reserve, which actions are open.
    private func openMoment(_ moment: MomentInfo) {
        if model.reads.isSaved(.moments), let link = MomentLink(key: moment.key) {
            router.openMoment(link)
        } else {
            router.openMoment(moment)
        }
    }

    /// A part showing what was saved when it was last read whose read now failed (`HomeReadState.isSaved`, `.failed`):
    /// its saved figures stay, said to be saved above the balance, and the tab says the read failed, with Retry.
    @ViewBuilder private func savedUnreadRow(_ part: HomeReadState.Part) -> some View {
        if model.reads.isSaved(part), model.reads.status(part) == .failed {
            holdingsRetryRow(HomeModel.unreadMessage(part))
        }
    }

    private func holdingsEmpty(_ title: LocalizedStringKey, _ detail: LocalizedStringResource) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Paragraph(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// A tab whose part of the wallet isn't read yet (`HomeReadState`): a loading row while its first read runs, and once
    /// that failed, says so with Retry. Never "No … yet" for want of an answer.
    @ViewBuilder private func holdingsUnreadRow(_ part: HomeReadState.Part, reading: LocalizedStringKey) -> some View {
        if model.reads.status(part) == .failed {
            holdingsRetryRow(HomeModel.unreadMessage(part))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(reading).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// A read that failed, said with Retry; a spinner in its place while Home reads again (the Retry, or its refresh).
    private func holdingsRetryRow(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: message)
            Spacer(minLength: 8)
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry") { Task { await model.load(env: env, address: session.address) } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 12)
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
    /// The category's name where four share Home's card: My Holdings' switch and the balance card's split. Keys of their
    /// own, apart from the tabs' and the menu's names, so a language whose tab names are long can keep these short.
    var label: String {
        switch self {
        case .spot: return tr(LocalizedStringResource("homeCategory.spot", defaultValue: "Spot", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The wallet's own tokens, as against Perps"))
        case .perps: return tr(LocalizedStringResource("homeCategory.perps", defaultValue: "Perps", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. Perpetual futures"))
        case .launchpad: return tr(LocalizedStringResource("homeCategory.launch", defaultValue: "Launch", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The launchpad's coins (a noun), as the Launch tab"))
        case .moments: return tr(LocalizedStringResource("homeCategory.moments", defaultValue: "Moments", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split. The Moments feature's name"))
        }
    }
}

extension View {
    /// The standard grouped card: secondary surface, continuous corners, hairline separation from the ground.
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A figure not read yet (`unread`) — on Home, a part of the wallet; on My Launchpad, a stat, a holding's value or its
    /// profit and loss: drawn as the placeholder shape of one, and said by VoiceOver to be loading, never as the "$0.00"
    /// or "0" the shape is drawn from.
    @ViewBuilder func unreadFigure(_ unread: Bool) -> some View {
        if unread {
            redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Loading…"))
        } else {
            self
        }
    }
}
