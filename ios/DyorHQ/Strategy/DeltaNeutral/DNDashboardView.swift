import BigInt
import DyorKit
import SwiftUI

/// The live dashboard of one delta-neutral position: entry progress, both legs, funding (rate, direction, accrued,
/// next settlement), P&L broken into funding / price / fees, health (liquidation distance, margin, drift), the event
/// log, and the actions — pause or resume the entry, add margin, exit, retry.
struct DNDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = DNDashboardModel()
    @State private var confirmExit = false
    @State private var confirmRemove = false
    @State private var showAddMargin = false
    @Environment(\.dismiss) private var dismiss

    let strategyID: String

    private var runner: DNRunner { env.dnRunner }
    private var isRunningThis: Bool { runner.runningID == strategyID }

    var body: some View {
        List {
            if let s = model.strategy {
                headerSection(s)
                if s.status == .entering || (s.status == .failed && !s.entryComplete) { progressSection(s) }
                if s.status == .exiting { exitingSection(s) }
                if let error = s.lastError, s.status == .failed { Section { InlineError(message: Self.brief(error)) } }
                actionsSection(s)
                legsSection(s)
                fundingSection(s)
                pnlSection(s)
                if s.status == .running || s.status == .entering { healthSection(s) }
                eventsSection(s)
            } else {
                Text("Strategy not found.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.strategy.map { "\($0.symbol) Delta Neutral" } ?? "Delta Neutral")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.address) { await model.refresh(env: env, owner: session.address, id: strategyID) }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(10)); await model.refresh(env: env, owner: session.address, id: strategyID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dnStrategyChanged)) { _ in Task { await model.refresh(env: env, owner: session.address, id: strategyID) } }
        .refreshable { await model.refresh(env: env, owner: session.address, id: strategyID) }
        .confirmationDialog("Exit this position?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Close the short and sell the spot", role: .destructive) { runner.beginExit(id: strategyID, env: env) }
        } message: {
            Text("Closes the Perpl short at market (no fee), then sells the spot back to USDC in \(model.strategy?.parameters.twapSlices ?? 1) slices. Keep the app open until it finishes.")
        }
        .confirmationDialog("Remove this strategy from the list?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { DNStore.remove(id: strategyID, owner: session.address); dismiss() }
        }
        .sheet(isPresented: $showAddMargin) { if let s = model.strategy, let market = model.market { AddMarginSheet(strategy: s, market: market, health: model.health) { Task { await model.refresh(env: env, owner: session.address, id: strategyID) } } } }
    }

    // MARK: Sections

    private func headerSection(_ s: DNStrategy) -> some View {
        Section {
            HStack(spacing: 12) {
                Image("scale.balance")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [.allocationPerps, .allocationPerps.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Long \(s.spotSymbol) · Short \(s.symbol)-PERP").font(.headline)
                    Text("Started \(s.startedAgo) ago · \(NumberStyle.number(s.parameters.perpLeverage, maximumFractionDigits: 1))× perp").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(status: s.status, paused: s.paused)
            }
            .padding(.vertical, 2)
        }
    }

    private func progressSection(_ s: DNStrategy) -> some View {
        Section {
            ProgressView(value: Double(s.slicesDone), total: Double(s.slices)) {
                Text("Slice \(min(s.slicesDone + 1, s.slices)) of \(s.slices)")
            } currentValueLabel: {
                Text("\(Int(Double(s.slicesDone) / Double(max(1, s.slices)) * 100))%")
            }
            .tint(.brand)
            if isRunningThis, let step = runner.stepLabel {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.footnote).foregroundStyle(.secondary) }
            } else if s.paused {
                Text("Paused. Resume to continue the remaining \(s.slices - s.slicesDone) slices.").font(.footnote).foregroundStyle(.secondary)
            } else if s.status == .failed {
                Text("Stopped after \(s.slicesDone) of \(s.slices) slices.").font(.footnote).foregroundStyle(.secondary)
            } else if !isRunningThis {
                Text("Not running — open the app and tap Resume to continue.").font(.footnote).foregroundStyle(Color.attention)
            }
            LabeledContent("Bought so far", value: "\(NumberStyle.number(s.spotAcquiredUnits, maximumFractionDigits: 6)) \(s.spotSymbol) for \(s.spotSpentUSD.formatted(.currency(code: "USD")))")
            LabeledContent("Shorted so far", value: "\(NumberStyle.number(s.perpShortSize, maximumFractionDigits: 6)) of \(NumberStyle.number(s.targetPerpSize, maximumFractionDigits: 6)) \(s.symbol)")
        } header: {
            Text("Entry")
        }
    }

    private func exitingSection(_ s: DNStrategy) -> some View {
        Section("Exit") {
            if isRunningThis, let step = runner.stepLabel {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text("Exit paused — tap Exit again to finish selling the spot.").font(.footnote).foregroundStyle(Color.attention)
            }
            LabeledContent("Spot sold", value: "\(NumberStyle.number(s.spotSoldUnits, maximumFractionDigits: 6)) \(s.spotSymbol) → \(s.spotProceedsUSD.formatted(.currency(code: "USD")))")
        }
    }

    private func legsSection(_ s: DNStrategy) -> some View {
        Section {
            let units = s.spotHeldUnits
            LabeledContent("Spot") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(NumberStyle.number(units, maximumFractionDigits: 6)) \(s.spotSymbol)").monospacedDigit()
                    if let value = model.spotValue { Text(value.formatted(.currency(code: "USD"))).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let p = model.position {
                LabeledContent("Perp short") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(NumberStyle.number(p.size, maximumFractionDigits: 6)) \(s.symbol) · entry \(NumberStyle.number(p.entry))").monospacedDigit()
                        Text("mark \(NumberStyle.number(p.mark)) · margin \(p.margin.formatted(.currency(code: "USD")))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Perp short", value: s.status == .closed ? "closed" : s.perpShortSize > 0 ? "not found on Perpl" : "not opened yet")
            }
            if let health = model.health, s.status != .closed {
                LabeledContent("Net delta") {
                    Text("\(health.netDelta.formatted(.currency(code: "USD").sign(strategy: .always()))) (\(NumberStyle.percent(health.driftPct, fractionDigits: 2, signed: false)))")
                        .monospacedDigit().foregroundStyle(health.driftPct > s.parameters.maxDeltaDriftPct ? Color.attention : .primary)
                }
            }
        } header: {
            Text("Legs")
        }
    }

    private func fundingSection(_ s: DNStrategy) -> some View {
        Section {
            if let market = model.market {
                let hourly = market.fundingRateHourly
                let direction = PerplFunding.direction(hourly: hourly)
                LabeledContent("Rate now") {
                    Text("\(hourly >= 0 ? "+" : "")\(NumberStyle.percent(hourly * 100, fractionDigits: 4, signed: false))/h · \(NumberStyle.percent(PerplFunding.annualized(hourly: hourly) * 100, fractionDigits: 1))/yr")
                        .monospacedDigit().foregroundStyle(hourly > 0 ? Color.positive : hourly < 0 ? Color.negative : .secondary)
                }
                Label(direction == .longsPayShorts ? "Longs pay shorts — you are earning" : direction == .shortsPayLongs ? "Shorts pay longs — you are paying" : "No funding this interval",
                      systemImage: direction == .longsPayShorts ? "arrow.down.right.circle.fill" : direction == .shortsPayLongs ? "exclamationmark.triangle.fill" : "minus.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(direction == .longsPayShorts ? Color.positive : direction == .shortsPayLongs ? Color.negative : .secondary)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    LabeledContent("Next settlement", value: model.countdown(at: ctx.date))
                }
                if let p = model.position {
                    LabeledContent("Accrued on the open short") { Text(p.premium.formatted(.currency(code: "USD").sign(strategy: .always()))).monospacedDigit().foregroundStyle(p.premium >= 0 ? Color.positive : Color.negative) }
                    LabeledContent("Projected per day", value: (p.size * market.mark * PerplFunding.daily(hourly: hourly)).formatted(.currency(code: "USD")))
                }
                if s.fundingRealizedAtExit != 0 { LabeledContent("Realized at exit", value: s.fundingRealizedAtExit.formatted(.currency(code: "USD").sign(strategy: .always()))) }
                if let realized = model.realizedFunding { LabeledContent("Paid out so far (history)", value: realized.formatted(.currency(code: "USD").sign(strategy: .always()))) }
                if s.intervalsBelowThreshold > 0 { LabeledContent("Intervals below exit threshold", value: "\(s.intervalsBelowThreshold) of \(s.parameters.exitAfterIntervals)") }
            }
        } header: {
            Text("Funding")
        } footer: {
            Text("Funding accrues on the short as `premium` and settles into your Perpl balance when the position closes. Perpl pays it about once an hour; the rate is recomputed every interval.")
        }
    }

    private func pnlSection(_ s: DNStrategy) -> some View {
        Section {
            let pnl = model.pnl(for: s)
            LabeledContent("Funding earned") { Text(pnl.funding.formatted(.currency(code: "USD").sign(strategy: .always()))).monospacedDigit().foregroundStyle(pnl.funding >= 0 ? Color.positive : Color.negative) }
            LabeledContent("Price P&L (both legs)") { Text(pnl.price.formatted(.currency(code: "USD").sign(strategy: .always()))).monospacedDigit().foregroundStyle(.secondary) }
            LabeledContent("Fees paid") { Text((-pnl.fees).formatted(.currency(code: "USD").sign(strategy: .always()))).monospacedDigit().foregroundStyle(.secondary) }
            LabeledContent("Net") { Text(pnl.net.formatted(.currency(code: "USD").sign(strategy: .always()))).font(.headline).monospacedDigit().foregroundStyle(pnl.net >= 0 ? Color.positive : Color.negative) }
        } header: {
            Text("P&L")
        } footer: {
            Text("Price P&L is the spot leg's gain plus the short's price move; on a clean hedge it stays near zero. Fees are the Perpl open fee plus the quoted execution cost of the spot slices.")
        }
    }

    private func healthSection(_ s: DNStrategy) -> some View {
        Section {
            if let health = model.health {
                if let liq = health.liquidationPrice, let distance = health.liquidationDistancePct {
                    LabeledContent("Short liquidation") {
                        Text("\(NumberStyle.number(liq)) · \(NumberStyle.percent(distance, fractionDigits: 1, signed: false)) away")
                            .monospacedDigit().foregroundStyle(distance < s.parameters.liquidationBufferPct ? Color.negative : .primary)
                    }
                }
                LabeledContent("Margin ratio", value: NumberStyle.percent(health.marginRatio * 100, fractionDigits: 1, signed: false))
                LabeledContent("Leg drift", value: "\(NumberStyle.percent(health.driftPct, fractionDigits: 2, signed: false)) (alert at \(NumberStyle.percent(s.parameters.maxDeltaDriftPct, fractionDigits: 1, signed: false)))")
            }
            if let last = env.dnWatcher.lastCheck {
                LabeledContent("Last check", value: last.formatted(date: .omitted, time: .standard))
            }
            Text("Monitoring runs only while DyorHQ is open. Funding flips, liquidation distance and drift raise a notification when seen.").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Health")
        }
    }

    private func actionsSection(_ s: DNStrategy) -> some View {
        Section {
            switch s.status {
            case .entering:
                if isRunningThis {
                    Button("Pause after this slice", systemImage: "pause.circle") { Haptics.tap(); runner.cancel() }
                } else {
                    Button("Resume entry", systemImage: "play.circle") { Haptics.tap(); runner.start(id: s.id, env: env) }.disabled(runner.isRunning || !session.canSign)
                }
                Button("Exit now", systemImage: "arrow.uturn.backward.circle", role: .destructive) { Haptics.tap(); confirmExit = true }.disabled(runner.isRunning || !session.canSign)
            case .running:
                Button("Add margin to the short", systemImage: "plus.circle") { Haptics.tap(); showAddMargin = true }.disabled(!session.canSign || model.position == nil)
                Button("Exit position", systemImage: "arrow.uturn.backward.circle", role: .destructive) { Haptics.tap(); confirmExit = true }.disabled(runner.isRunning || !session.canSign)
            case .exiting:
                if isRunningThis {
                    Button("Pause after this slice", systemImage: "pause.circle") { Haptics.tap(); runner.cancel() }
                } else {
                    Button("Continue exit", systemImage: "play.circle") { Haptics.tap(); runner.beginExit(id: s.id, env: env) }.disabled(runner.isRunning || !session.canSign)
                }
            case .failed:
                if !s.entryComplete {
                    Button("Retry entry", systemImage: "arrow.clockwise") { Haptics.tap(); runner.start(id: s.id, env: env) }.disabled(runner.isRunning || !session.canSign)
                }
                Button(s.entryComplete ? "Retry exit" : "Exit what was bought", systemImage: "arrow.uturn.backward.circle", role: .destructive) { Haptics.tap(); runner.beginExit(id: s.id, env: env) }.disabled(runner.isRunning || !session.canSign)
                Button("Mark as closed", systemImage: "checkmark.circle") { Haptics.tap(); model.markClosed(owner: session.address) }
            case .closed:
                Button("Remove from list", systemImage: "trash", role: .destructive) { confirmRemove = true }
            }
            Button("Trade \(s.symbol) on Perps", systemImage: "chart.line.uptrend.xyaxis") { router.openPerp(id: s.marketId) }
        } header: {
            Text("Actions")
        }
    }

    /// Keeps a node's raw revert payload from turning the banner into a wall of hex; the full text stays in Events.
    static func brief(_ message: String) -> String {
        message.count > 180 ? String(message.prefix(180)) + "…" : message
    }

    private func eventsSection(_ s: DNStrategy) -> some View {
        Section("Events") {
            if s.events.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                ForEach(s.events.prefix(40)) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Text(event.time, style: .time).font(.caption2).foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text).font(.footnote).lineLimit(6)
                            if let hash = event.txHash { Link("View transaction", destination: Monad.explorerTransaction(hash)).font(.caption2) }
                        }
                    }
                }
            }
        }
    }
}

private struct StatusPill: View {
    let status: DNStrategy.Status
    let paused: Bool
    var body: some View {
        Text(paused && status == .entering ? "Paused" : status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
    private var tint: Color {
        switch status {
        case .running: return .positive
        case .failed: return .negative
        case .closed: return .secondary
        case .entering, .exiting: return paused ? .secondary : .attention
        }
    }
}

/// Adds AUSD to the short's margin (from the Perpl account balance; deposit first if needed) to push liquidation away.
private struct AddMarginSheet: View {
    let strategy: DNStrategy
    let market: PerpMarket
    let health: DeltaNeutral.Health?
    let onDone: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "25"
    @State private var balance: Double?
    @State private var showConfirm = false

    private var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Text("Amount"); Spacer(); TextField("25", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 120); Text("AUSD").foregroundStyle(.secondary) }
                    if let balance { LabeledContent("Perpl balance (free)", value: balance.formatted(.currency(code: "USD"))) }
                    if let liq = health?.liquidationPrice { LabeledContent("Liquidation now", value: NumberStyle.number(liq)) }
                } footer: {
                    Text("Margin is taken from your free Perpl balance. Deposit AUSD on the Perps screen first if the balance is short.")
                }
            }
            .navigationTitle("Add Margin")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(amount <= 0 || (balance.map { amount > $0 } ?? false)) }
            }
            .task { if let address = session.address, let account = try? await env.perpl.account(address) { balance = PerplService.fromCNS(account.balance - account.locked) } }
            .sheet(isPresented: $showConfirm) {
                ConfirmationSheet(title: "Add Margin", confirmTitle: "Add \(NumberStyle.number(amount, maximumFractionDigits: 2)) AUSD", build: { env.perpl.addMarginPlan(market: market, amount: amount) }, onDone: { dismiss(); onDone() }) {
                    DetailRow("Market", "\(market.asset)-PERP short")
                    DetailRow("Margin added", "\(NumberStyle.number(amount, maximumFractionDigits: 2)) AUSD")
                }
            }
        }
    }
}

@Observable
@MainActor
final class DNDashboardModel {
    private(set) var strategy: DNStrategy?
    private(set) var market: PerpMarket?
    private(set) var position: PerpPosition?
    private(set) var spotValue: Double?
    private(set) var spotPrice: Double?
    private(set) var health: DeltaNeutral.Health?
    private(set) var realizedFunding: Double?
    private(set) var head: UInt64 = 0
    private(set) var headAt = Date()

    struct PnL { let funding: Double; let price: Double; let fees: Double; var net: Double { funding + price - fees } }

    func refresh(env: AppEnvironment, owner: Address?, id: String) async {
        // Every property is assigned only when it really changed: each write re-renders the List, and needless
        // re-renders make it re-measure its tall rows and jump under the user's finger.
        let found = DNStore.find(id: id, owner: owner)
        if found != strategy { strategy = found }
        guard let s = strategy else { return }
        async let marketTask = env.perpl.markets(ids: [s.marketId])
        async let headTask = env.rpc.blockNumber()
        if let fresh = (try? await marketTask)?.first, fresh != market { market = fresh }
        if let block = try? await headTask { head = block; headAt = Date() }
        let units = s.spotHeldUnits
        let token = s.spotTokenModel
        let price = (try? await env.prices.prices(for: [token]))?[token.address]?.usd ?? market?.mark
        if price != spotPrice { spotPrice = price }
        let value = price.map { units * $0 }
        if value != spotValue { spotValue = value }
        var freshPosition: PerpPosition? = nil
        if let owner, let market, let account = try? await env.perpl.account(owner) {
            freshPosition = (try? await env.perpl.positions(account, markets: [market]))?.first { $0.perpId == s.marketId && $0.side == .short }
        }
        if freshPosition != position { position = freshPosition }
        if let market {
            let fresh = DeltaNeutral.health(spotUnits: units, spotPrice: price ?? market.mark, position: position, mark: market.mark, maintenanceFraction: market.maintMarginFraction)
            if fresh != health { health = fresh }
        }
        // Realized funding payments from Perpl's account history, when the trading key is enrolled.
        if let key = env.perplTrading.key, s.status != .closed || s.exitedAt != nil {
            var total = 0.0
            var cursor: String? = nil
            for _ in 0..<5 {
                guard let page = try? await env.perpl.accountHistory(key: key, count: 100, cursor: cursor) else { break }
                for event in page.items where event.kind == .funding && event.marketId == s.marketId && event.time >= s.createdAt { total += event.amount }
                if page.items.last.map({ $0.time < s.createdAt }) ?? true { break }
                guard let next = page.next else { break }
                cursor = next
            }
            if total != realizedFunding { realizedFunding = total }
        }
    }

    func countdown(at date: Date) -> String {
        guard let market, head > 0 else { return "—" }
        let elapsedBlocks = UInt64(max(0, date.timeIntervalSince(headAt)) / PerplFunding.assumedBlockSeconds)
        let seconds = max(0, Int(PerplFunding.secondsToNextSettlement(startBlock: market.fundingStartBlock, head: head + elapsedBlocks)))
        return String(format: "≈ %02d:%02d", seconds / 60, seconds % 60)
    }

    func pnl(for s: DNStrategy) -> PnL {
        let funding = (position?.premium ?? 0) + s.fundingRealizedAtExit + (realizedFunding ?? 0)
        let spotHeld = spotValue ?? 0
        let spotCost = s.spotSpentUSD - s.spotProceedsUSD
        let perpPrice = position.map { $0.unrealized - $0.premium } ?? 0
        let price = spotHeld - spotCost + perpPrice
        let fees = s.perpEntryFeeUSD + s.spotImpactCostUSD
        return PnL(funding: funding, price: price, fees: fees)
    }

    func markClosed(owner: Address?) {
        guard var s = strategy else { return }
        s.status = .closed
        s.exitedAt = Date()
        s.log("Marked closed by you.")
        DNStore.upsert(s, owner: owner)
        strategy = s
    }
}
