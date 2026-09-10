import BigInt
import DyorKit
import SwiftUI

/// Live status for a running automated MM strategy: cumulative session volume, PnL (realized + unrealized), estimated
/// fees, open positions, open orders and the fills feed — refreshed from on-chain reads and the manager's fill log.
struct MMStatusView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let strategyID: String

    @State private var strategy: MMStrategy?
    @State private var positions: [PerpPosition] = []
    @State private var orders: [PerpOrder] = []
    @State private var balance: Double = 0
    @State private var loaded = false
    @State private var stopping = false
    @State private var confirmStop = false
    @State private var stopError: String?

    // Estimated maker round-trip fee (Perpl maker 1.5bp + builder 1.0bp per leg → ~5bp round trip).
    private let feeRateBp = 5.0

    private var realizedPnL: Double { guard let s = strategy, loaded else { return 0 }; return balance - s.startBalance }
    private var unrealizedPnL: Double { positions.reduce(0) { $0 + $1.unrealized } }
    private var totalPnL: Double { realizedPnL + unrealizedPnL }
    private var estFees: Double { (strategy?.volume ?? 0) * feeRateBp / 10_000 }

    var body: some View {
        List {
            if let strategy {
                headerSection(strategy)
                statsSection
                positionsSection
                ordersSection
                fillsSection(strategy)
                if strategy.active || !positions.isEmpty || !orders.isEmpty { stopSection }
            } else {
                Text("Strategy not found.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Strategy Status")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.address) { await refresh() }
        .task {
            // Poll live while on screen; the manager posts mmStrategyChanged on fills/recycle.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(8)); await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mmStrategyChanged)) { _ in Task { await refresh() } }
        .refreshable { await refresh() }
        .confirmationDialog("Stop this strategy?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop & Flatten", role: .destructive) { Task { await stop() } }
        } message: {
            Text("Cancels every resting order and closes any open position for this market.")
        }
    }

    private func refresh() async {
        strategy = MMStore.strategies(owner: session.address).first { $0.id == strategyID }
        guard let s = strategy, let owner = session.address else { return }
        let markets = (try? await env.perpl.markets()) ?? []
        guard let account = try? await env.perpl.account(owner) else { return }
        balance = Amount.units(account.balance, decimals: Perpl.collateralDecimals)
        let allPositions = (try? await env.perpl.positions(account, markets: markets)) ?? []
        let allOrders = (try? await env.perpl.openOrders(account, markets: markets)) ?? []
        positions = allPositions.filter { $0.perpId == s.marketId }
        orders = allOrders.filter { $0.perpId == s.marketId }
        loaded = true
    }

    private func stop() async {
        guard var s = strategy else { return }
        stopping = true
        stopError = nil
        s.active = false
        MMStore.upsert(s, owner: session.address) // mark stopped first so the manager won't recycle mid-teardown
        strategy = s
        let clean = await MMExecutor.stop(s, env: env)
        if !clean { stopError = "Some orders or a position may still be open. Tap Stop again to retry." }
        NotificationCenter.default.post(name: .mmStrategyChanged, object: nil)
        await refresh()
        stopping = false
    }

    // MARK: Sections

    private func headerSection(_ s: MMStrategy) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: s.isGrid ? "square.grid.3x3" : "arrow.left.and.right")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [.allocationSpot, .allocationSpot.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.mode.capitalized) · \(s.symbol)-PERP").font(.headline)
                    Text("Started \(RelativeTime.short(s.startedAt)) ago").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RunPill(active: s.active)
            }
            .padding(.vertical, 2)
        }
    }

    private var statsSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatTile(label: "Session PnL", value: totalPnL.formatted(.currency(code: "USD")), tint: totalPnL >= 0 ? .positive : .negative)
                    StatTile(label: "Volume", value: (strategy?.volume ?? 0).formatted(.currency(code: "USD").precision(.fractionLength(0))), tint: .primary)
                }
                HStack(spacing: 12) {
                    StatTile(label: "Unrealized", value: unrealizedPnL.formatted(.currency(code: "USD")), tint: unrealizedPnL >= 0 ? .positive : .negative)
                    StatTile(label: "Est. fees", value: estFees.formatted(.currency(code: "USD")), tint: .secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
        } footer: {
            Text("Realized PnL is your collateral change since start (net of fees). Fees are estimated at the maker rate. Take-profit and stop-loss are native Perpl triggers on each level — they fire even when the app is closed.")
        }
    }

    @ViewBuilder private var positionsSection: some View {
        Section("Open positions (\(positions.count))") {
            if positions.isEmpty {
                Text("Flat — no open position.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(positions) { p in
                    HStack {
                        Text(p.side.rawValue.uppercased()).font(.caption.weight(.bold))
                            .foregroundStyle(p.side == .long ? Color.positive : Color.negative).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(NumberStyle.number(p.size, maximumFractionDigits: 4)) \(p.symbol)").monospacedDigit()
                            Text("Entry \(NumberStyle.number(p.entry))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Text("\(p.unrealized >= 0 ? "+" : "")\(p.unrealized.formatted(.currency(code: "USD")))")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(p.unrealized >= 0 ? Color.positive : Color.negative)
                    }
                }
            }
        }
    }

    @ViewBuilder private var ordersSection: some View {
        Section("Open orders (\(orders.count))") {
            if orders.isEmpty {
                Text("No resting orders.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(orders) { o in
                    HStack {
                        Text(o.side == .buy ? "Buy" : "Sell").font(.caption.weight(.bold))
                            .foregroundStyle(o.side == .buy ? Color.positive : Color.negative).frame(width: 46, alignment: .leading)
                        Text(NumberStyle.number(o.price)).monospacedDigit()
                        Spacer()
                        Text("\(NumberStyle.number(o.size, maximumFractionDigits: 4)) \(o.symbol)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private func fillsSection(_ s: MMStrategy) -> some View {
        Section("Fills (\(s.fills.count))") {
            if s.fills.isEmpty {
                Text("No fills yet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(s.fills.reversed().prefix(20)) { fill in
                    HStack {
                        Text(fill.side == "long" ? "Buy" : "Sell").font(.caption.weight(.bold))
                            .foregroundStyle(fill.side == "long" ? Color.positive : Color.negative).frame(width: 46, alignment: .leading)
                        Text(NumberStyle.number(fill.price)).monospacedDigit()
                        Spacer()
                        Text("\(RelativeTime.short(fill.time)) ago").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var stopSection: some View {
        Section {
            Button(role: .destructive) { confirmStop = true } label: {
                HStack {
                    if stopping { ProgressView().controlSize(.small) }
                    Text(stopping ? "Stopping…" : "Stop Strategy").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
            }
            .disabled(stopping)
        } footer: {
            if let stopError { Text(stopError).foregroundStyle(Color.attention) }
        }
    }
}

private struct RunPill: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? Color.positive : Color.secondary).frame(width: 7, height: 7)
            Text(active ? "Running" : "Stopped").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background((active ? Color.positive : Color.secondary).opacity(0.14), in: Capsule())
        .foregroundStyle(active ? Color.positive : Color.secondary)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
