import Charts
import DyorKit
import SwiftUI

/// The Portfolio for the whole of DyorHQ: cumulative volume across Spot, Perps, Launch and Moments for the chosen
/// period, then fees paid, P&L, claimed fees and trade counts — in total and per section — with the activity behind
/// the numbers. Opened from the side menu or by tapping Total Volume on Home; both share the same period.
struct PortfolioView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false
    @State private var assets = AssetsModel()
    @State private var pastMoments = PastMomentsModel()

    private var model: PortfolioModel { env.portfolio }
    /// The transfers into the wallet as the history has them: what the holdings are found in.
    private var transfersIn: HistoryStatus { env.history.snapshot.status(WalletHistoryScans.transfersInId) }

    var body: some View {
        @Bindable var router = router
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if session.address == nil {
                        ContentUnavailableView {
                            Label("Sign In to See Your Portfolio", systemImage: "chart.pie")
                        } description: {
                            Paragraph("Volume, fees and P&L are computed from your wallet's own on-chain history.")
                        }
                            .padding(.top, 40)
                    } else {
                        heroCard
                        breakdownCard
                        ForEach(PortfolioModel.Section.allCases) { section in sectionCard(section) }
                        AssetsCard(model: assets) { Task { await assets.load(env: env, address: session.address, force: true) } }
                        PastCohortsCard(model: pastMoments)
                        activityCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tr("Portfolio"))
            .navigationBarTitleDisplayMode(.inline)
            // A retired-cohort Moment opens its claim-only page, read from its own cohort (keyed by factory, id).
            .navigationDestination(for: PastMomentRoute.self) { route in
                if let cohort = env.retiredMoments(for: route.key.factory) {
                    // A claim or withdrawal moves balances and history too, not just the past-cohort positions.
                    RetiredMomentDetailView(cohort: cohort, info: route.info, onChanged: { Task { await reload(force: true) } })
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                        .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Period", selection: $router.period) {
                            ForEach(VolumePeriod.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(router.period.label).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                    }
                    .accessibilityLabel("Period")
                }
            }
            .refreshable { await reload(force: true) }
            .task(id: session.address) { await reload(force: false) }
            // The history fills in behind the screen (`HistoryModel`): the figures follow it, and the holdings — tokens and
            // NFTs, both found in the transfers into the wallet — are read again once the transfer history has been read in
            // full, and once it reads further back (the wallet's first transaction found: a new floor, read in one round
            // perhaps, so never seen incomplete) than NFTs already read were read from — not before the first read, which
            // the screen's own load makes.
            .task(id: env.history.version) { model.applyHistory(env.history.snapshot, version: env.history.version, for: session.address) }
            .task(id: "\(transfersIn.complete)-\(transfersIn.floor.map(String.init) ?? "")") {
                if transfersIn.complete, !assets.complete || !assets.nftsComplete || (assets.nftsRead && assets.nftsFloor != transfersIn.floor) {
                    await assets.load(env: env, address: session.address, force: true)
                }
            }
            // A Perpl key that appears (a passkey session unlocked) loads the perps history the last load lacked.
            .task(id: perplTrading.key != nil) { if perplTrading.key != nil { await reload(force: false) } }
        }
    }

    /// The Portfolio's three reads — volume / history, My Holdings and Past Cohorts — side by side, each read again in
    /// full on a pull (`force`). A pull reads the history on as well, behind them and never waited for
    /// (`HistoryModel.kick`): the figures follow it (`env.history.version`).
    private func reload(force: Bool) async {
        if force { env.history.kick(env: env) }
        async let portfolio: () = model.load(env: env, address: session.address, perplKey: perplTrading.key, force: force, passkey: session.isPasskeyAccount)
        async let holdings: () = assets.load(env: env, address: session.address, force: force)
        async let past: () = pastMoments.load(env: env, address: session.address, force: force)
        _ = await (portfolio, holdings, past)
    }

    // MARK: Hero

    private var totals: PortfolioModel.Stats { model.totals(router.period) }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cumulative Volume").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(router.period.label).font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.brand.opacity(0.12), in: Capsule())
                }
                Text(PriceFormat.usdValue(totals.volume))
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: totals.volume))
                    .redacted(reason: model.loading && !model.hasLoaded ? .placeholder : [])
                Paragraph("Across Spot, Perps, Launch and Moments").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("Fees paid", usd(totals.fees), tint: .primary)
                metric("P&L", signed(totals.pnl) + (totals.pnlComplete ? "" : "*"), tint: totals.pnl < 0 ? .negative : totals.pnl > 0 ? .positive : .primary)
                metric("Fees received", usd(totals.claimedFees), tint: totals.claimedFees > 0 ? .positive : .primary)
                metric("Trades", "\(totals.trades)", tint: .primary)
            }
            if model.loading, model.hasLoaded {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Refreshing…").font(.caption2).foregroundStyle(.tertiary) }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(Color.attention)
            } else if model.historyUnreachable {
                Label("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(Color.attention)
            } else if model.historyFilling(router.period, scans: WalletHistoryScans.ids) {
                // The store is still reading the period's window of the wallet's history, in every scan (fees received
                // show here, holder rewards among them): the figures grow as it does.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading your history… \(NumberStyle.percent(model.historyProgress(router.period, scans: WalletHistoryScans.ids) * 100, fractionDigits: 0, signed: false))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else if let updated = model.updatedAt {
                Text("Updated \(updated, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Breakdown

    private struct Slice: Identifiable {
        let section: PortfolioModel.Section
        let volume: Double
        var id: String { section.id }
    }

    private var slices: [Slice] { PortfolioModel.Section.allCases.map { Slice(section: $0, volume: model.stats($0, router.period).volume) } }

    private var breakdownCard: some View {
        let total = max(totals.volume, 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Volume by Section").font(.headline)
            if total > 0 {
                Chart(slices.filter { $0.volume > 0 }) { slice in
                    BarMark(x: .value("Volume", slice.volume))
                        .foregroundStyle(color(slice.section))
                        .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 22)
                .accessibilityLabel("Share of volume per section")
            } else {
                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 10)
            }
            VStack(spacing: 8) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(color(slice.section)).frame(width: 9, height: 9)
                        Text(slice.section.title).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(PriceFormat.usdValue(slice.volume)).font(.subheadline.weight(.medium)).monospacedDigit()
                        Text(NumberStyle.percent(total > 0 ? slice.volume / total * 100 : 0, fractionDigits: 0, signed: false))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func color(_ section: PortfolioModel.Section) -> Color {
        switch section {
        case .spot: return .allocationSpot
        case .perps: return .allocationPerps
        case .launch: return .allocationLaunchpad
        case .moments: return .allocationMoments
        case .bridge: return .brand
        }
    }

    // MARK: Sections

    private func sectionCard(_ section: PortfolioModel.Section) -> some View {
        let stats = model.stats(section, router.period)
        return VStack(alignment: .leading, spacing: 12) {
            Button { open(section) } label: {
                HStack(spacing: 10) {
                    Image(systemName: section.symbol)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(color(section), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(section.title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text(PriceFormat.usdValue(stats.volume)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(section.title)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                small("Volume", usd(stats.volume))
                small("Fees", usd(stats.fees))
                small("P&L", signed(stats.pnl) + (stats.pnlComplete ? "" : "*"), tint: stats.pnl < 0 ? .negative : stats.pnl > 0 ? .positive : .primary)
                small(section == .perps ? "Trades" : "Received", section == .perps ? "\(stats.trades)" : usd(stats.claimedFees), tint: section != .perps && stats.claimedFees > 0 ? .positive : .primary)
            }
            if section == .perps, let note = model.perpsNote {
                Paragraph(note).font(.caption2).foregroundStyle(.secondary)
            } else if section != .perps {
                Text("\(stats.trades) trades in the period").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func small(_ title: LocalizedStringKey, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Activity

    private var activityCard: some View {
        let items = model.activity(router.period)
        let shown = showAll ? items : Array(items.prefix(12))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Text(verbatim: "\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(model.hasLoaded ? "Nothing in this period." : "Loading…").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        PortfolioActivityRow(item: item, color: color(item.section))
                        if index < shown.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                if items.count > shown.count {
                    Button("Show all \(items.count)") { showAll = true }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func open(_ section: PortfolioModel.Section) {
        Haptics.tap()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            router.open(section.menuItem)
        }
    }

    private func usd(_ value: Double) -> String { PriceFormat.usdValue(value) }
    private func signed(_ value: Double) -> String {
        PriceFormat.usdValue(value, signed: true)
    }
}

private struct PortfolioActivityRow: View {
    let item: PortfolioModel.Activity
    let color: Color

    var body: some View {
        Group {
            if let hash = item.hash {
                Link(destination: Monad.explorerTransaction(hash)) { content }.foregroundStyle(.primary)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: item.section.symbol)
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
                .background(color.opacity(0.16), in: Circle())
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.subtitle.isEmpty ? item.section.title : item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let usd = item.usd { Text(PriceFormat.usdValue(usd)).font(.subheadline.weight(.medium)).monospacedDigit() }
                Text(item.time, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
