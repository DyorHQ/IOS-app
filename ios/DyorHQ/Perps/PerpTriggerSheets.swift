import DyorKit
import SwiftUI

/// Sets, moves or removes an open position's take-profit and stop-loss on Perpl (security audit GT-1). A new trigger is
/// linked to the position (`lp`), so Perpl cancels it when the position closes, and closes the position's whole size as
/// the trading stream reports it now. That size is fixed — it won't follow the position if it grows or shrinks later —
/// and the sheet says so (GT-5). Moving a trigger cancels the old one first, then places the new one once Perpl's list
/// confirms the cancel; every step's outcome is shown, and a gap it leaves is said plainly.
struct PositionTriggersSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let mark: Double
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var tpText = ""
    @State private var slText = ""
    @State private var removeTP = false
    @State private var removeSL = false
    @State private var phase: TriggerSheetPhase = .editing

    private var isLong: Bool { position.side == .long }
    private var sideName: String { isLong ? "long" : "short" }
    private var live: [PerplOpenOrder] {
        perplTrading.openOrders.filter { $0.marketId == market.id && $0.isTrigger && $0.isReduceOnly && $0.protectsLong == isLong }
    }
    private var currentTP: [PerplOpenOrder] { live.filter { !$0.isStopLoss } }
    private var currentSL: [PerplOpenOrder] { live.filter(\.isStopLoss) }
    private var livePosition: PerplLivePosition? {
        perplTrading.livePositions.first { $0.marketId == market.id && $0.isLong == isLong && $0.isOpen }
    }
    private var liveSize: Double? { livePosition.map { Double($0.sizeRaw) / pow(10, Double(market.lotDecimals)) } }

    /// Why nothing can be changed from here right now, if so.
    private var unavailable: String? {
        if !session.canSign { return SessionError.readOnly.localizedDescription }
        if !perplTrading.ordersAreLive {
            return perplTrading.isEnrolled
                ? "Perpl trading isn't connected, so this position's current TP/SL can't be read. Reconnect in Profile → Perpl Trading."
                : "Connect Perpl trading in Profile to set take-profit and stop-loss."
        }
        if perplTrading.status == .needsForwarding { return "Enable one-click trading in Profile to set take-profit and stop-loss." }
        if livePosition == nil { return "Perpl hasn't reported this position on the trading connection yet. Try again in a moment." }
        return nil
    }

    private var changes: [PerplTrading.TriggerChange] {
        var out: [PerplTrading.TriggerChange] = []
        for (kind, text, remove, current) in [(PerplTriggerKind.stopLoss, slText, removeSL, currentSL), (.takeProfit, tpText, removeTP, currentTP)] {
            if remove, !current.isEmpty { out.append(.init(kind: kind, price: nil, replacing: current)) }
            else if !remove, let price = text.perpDouble { out.append(.init(kind: kind, price: price, replacing: current)) }
        }
        return out
    }

    private var problem: String? {
        for (name, text, remove) in [("take-profit", tpText, removeTP), ("stop-loss", slText, removeSL)] where !remove {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, text.perpDouble == nil { return "Enter the \(name) as a number." }
        }
        for change in changes {
            guard let price = change.price else { continue }
            if change.kind == .stopLoss, market.maintMarginFraction == nil { return PerplTriggerRules.liquidationUnknownMessage }
            if let problem = PerplTriggerRules.problem(change.kind, price: price, side: position.side, reference: mark, liquidation: position.liquidation, priceDecimals: market.priceDecimals) {
                return problem.message(market: market, referenceName: "the mark price")
            }
        }
        return nil
    }

    private var busy: Bool { phase == .working }
    private var finished: Bool { if case .finished = phase { return true }; return false }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: "\(isLong ? "Long" : "Short") \(NumberStyle.number(position.size)) \(market.asset)", tint: isLong ? .positive : .negative)
                    DetailRow("Mark price", NumberStyle.number(mark))
                    DetailRow("Liq. price", position.liquidation.map { NumberStyle.number($0) } ?? "Unknown")
                }
                triggerSection(.stopLoss, text: $slText, remove: $removeSL, current: currentSL)
                triggerSection(.takeProfit, text: $tpText, remove: $removeTP, current: currentTP)
                Section {
                    if let liveSize {
                        Text("A new take-profit or stop-loss closes \(NumberStyle.number(liveSize)) \(market.asset), the whole position as it is now. That size is fixed: if you add to or reduce the position later, set TP/SL again. It is cancelled automatically when the position closes.")
                    }
                    Text("Moving one cancels the old trigger first, and places the new one once Perpl confirms the cancel.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                if session.isPasskeyAccount, !finished, !changes.isEmpty {
                    // A cancel and a reduce-only close always ask (MERA-PLAN §3): one Face ID covers the whole change.
                    let cancels = changes.contains { !$0.replacing.isEmpty }
                    Section { SessionScopeBadge(assessment: .faceID((cancels ? Mera.AlwaysAsk.cancelOrder : Mera.AlwaysAsk.closePosition).summary)) }
                }
                if let unavailable, !finished {
                    Section { InlineError(message: unavailable) }.listRowBackground(Color.clear)
                } else if let problem, !finished {
                    Section { InlineError(message: problem) }.listRowBackground(Color.clear)
                }
                TriggerSheetOutcomeSection(phase: phase)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("TP/SL · \(market.asset)-PERP")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { close() }.disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !finished {
                    PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Save TP/SL", isBusy: busy,
                                  isDisabled: unavailable != nil || problem != nil || changes.isEmpty) {
                        Task { await apply() }
                    }
                    .padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func triggerSection(_ kind: PerplTriggerKind, text: Binding<String>, remove: Binding<Bool>, current: [PerplOpenOrder]) -> some View {
        let name = kind == .takeProfit ? "Take profit" : "Stop loss"
        Section {
            if current.isEmpty {
                Text("None on Perpl").foregroundStyle(.secondary)
            } else {
                ForEach(current) { order in
                    DetailRow("Now", describeTrigger(order))
                }
            }
            HStack {
                Text(current.isEmpty ? "Set at" : "Move to").foregroundStyle(.secondary)
                Spacer()
                TextField(current.isEmpty ? "Optional" : "Keep", text: text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    .disabled(remove.wrappedValue || busy || finished)
                    .accessibilityLabel("\(name) price, USD")
                Text("USD").foregroundStyle(.secondary)
            }
            if !current.isEmpty {
                Toggle("Remove \(name.lowercased())", isOn: remove).disabled(busy || finished)
            }
        } header: {
            Text(name)
        } footer: {
            if current.count > 1 {
                Text("\(current.count) \(name.lowercased())s are live. A new one replaces all of them.")
            }
        }
    }

    private func describeTrigger(_ order: PerplOpenOrder) -> String {
        let price = Double(order.triggerPriceRaw ?? 0) / pow(10, Double(market.priceDecimals))
        let size = Double(order.sizeRaw) / pow(10, Double(market.lotDecimals))
        return "\(NumberStyle.number(price)) · \(NumberStyle.number(size)) \(market.asset)"
    }

    private func close() {
        let reload = finished
        dismiss()
        if reload { onDone() }
    }

    /// `approval`: a passkey account's step-up for this one change, when the session asked for one.
    private func apply(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers this like an order: it cancels and places triggers with the Perpl API key.
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm TP/SL")) { return }
        // Re-read on the retry after Face ID too: the position can close, or the stream reconnect, while the prompt is
        // open. Never left busy — the sheet couldn't be closed.
        guard let livePosition else {
            if phase == .working { phase = .failed("This position is no longer on Perpl's live list, so nothing was changed. Check Positions, then try again.") }
            return
        }
        let changes = self.changes
        guard !changes.isEmpty else {
            if phase == .working { phase = .failed("The TP/SL on Perpl changed meanwhile, so nothing was sent. Check them and try again.") }
            return
        }
        phase = .working
        do {
            let outcomes = try await perplTrading.changeTriggers(changes, market: market, position: livePosition, reference: mark, liquidation: position.liquidation, approval: approval)
            let size = Double(livePosition.sizeRaw) / pow(10, Double(market.lotDecimals))
            var lines: [TriggerSheetLine] = []
            var summary: [String] = []
            for change in changes {
                guard let outcome = outcomes[change.kind] else { continue }
                lines.append(line(for: change, outcome: outcome, size: size))
                let kind = PlacedTrigger.Kind(change.kind)
                switch outcome {
                case .placed, .placementUnknown:
                    if !change.replacing.isEmpty { TriggerStore.remove(perpId: market.id, kind: kind, positionLong: isLong, owner: session.address) }
                    // One that went unanswered may be live too, so this device keeps a record of it as well — shown as
                    // unverified until Perpl's list confirms or drops it (GT-3), as the order sheet does.
                    if let price = change.price {
                        TriggerStore.record([PlacedTrigger(perpId: market.id, symbol: market.asset, kind: kind, price: price, size: size, positionLong: isLong)], owner: session.address)
                        if outcome == .placed { summary.append("\(change.kind == .takeProfit ? "TP" : "SL") \(NumberStyle.number(price))") }
                    }
                case .removed, .unprotected:
                    if !change.replacing.isEmpty { TriggerStore.remove(perpId: market.id, kind: kind, positionLong: isLong, owner: session.address) }
                    if outcome == .removed { summary.append("\(change.kind == .takeProfit ? "TP" : "SL") removed") }
                case .unchanged, .partlyRemoved, .cancelUnknown, .cancelNotConfirmed:
                    break
                }
            }
            phase = .finished(lines)
            if !summary.isEmpty {
                Activity.record(ActivityRecord(kind: .perp, title: "TP/SL updated", subtitle: "\(market.asset)-PERP \(sideName) · \(summary.joined(separator: " · "))", hash: nil, section: "perps"), owner: session.address)
            }
        } catch is MeraSession.StepUpRequired where approval == nil {
            do {
                let approval = try await session.mera.stepUp()
                await apply(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed("Nothing was changed.")
            } catch {
                phase = .failed(describe(error))
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func line(for change: PerplTrading.TriggerChange, outcome: PerplTrading.TriggerChangeOutcome, size: Double) -> TriggerSheetLine {
        let name = change.kind == .takeProfit ? "take-profit" : "stop-loss"
        let title = change.kind == .takeProfit ? "Take-profit" : "Stop-loss"
        let price = change.price.map { NumberStyle.number($0) } ?? ""
        switch outcome {
        case .placed:
            return TriggerSheetLine(text: change.replacing.isEmpty
                ? "\(title) set at \(price), closing \(NumberStyle.number(size)) \(market.asset)."
                : "\(title) moved to \(price), closing \(NumberStyle.number(size)) \(market.asset). The old one was cancelled.", warning: false)
        case .removed:
            return TriggerSheetLine(text: "\(title) removed.", warning: false)
        case .unchanged(let why):
            return TriggerSheetLine(text: change.replacing.isEmpty
                ? "\(title) not placed: \(why)"
                : "\(title) not changed: \(why) The old one is still live.", warning: true)
        case .partlyRemoved(let why):
            return TriggerSheetLine(text: "Some of the old \(name)s were cancelled, but one was refused and is still live (\(why)). The new one wasn't placed. Check Orders.", warning: true)
        case .cancelUnknown:
            return TriggerSheetLine(text: "Perpl didn't confirm cancelling the old \(name), so the new one wasn't placed. Check Orders before trying again.", warning: true)
        case .cancelNotConfirmed:
            return TriggerSheetLine(text: change.price == nil
                ? "Cancel sent for the \(name), but Perpl hasn't confirmed it. Check Orders: it may still be live."
                : "Cancel sent for the old \(name), but Perpl hasn't confirmed it, so the new one wasn't placed (that could leave two). Check Orders: if the old one is gone, this position has no \(name) now.", warning: true)
        case .unprotected(let why):
            return TriggerSheetLine(text: "The old \(name) was cancelled, but Perpl refused the new one (\(why)). This position has no \(name) now.", warning: true)
        case .placementUnknown:
            return TriggerSheetLine(text: "Order status unknown — Perpl didn't confirm the new \(name). \(change.replacing.isEmpty ? "" : "The old one was cancelled. ")Check Open Orders before placing it again.", warning: true)
        }
    }
}

/// Cancels keeper triggers (TP/SL) on Perpl: one the user picked from the Orders list, or the ones left over on a
/// market with no position for them to close (security audit GT-1, GT-2).
struct CancelTriggersSheet: View {
    let market: PerpMarket
    let orders: [PerplOpenOrder]
    let title: String
    var note: String?
    let onDone: () -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: TriggerSheetPhase = .editing

    private var busy: Bool { phase == .working }
    private var finished: Bool { if case .finished = phase { return true }; return false }
    private var unavailable: String? {
        if !session.canSign { return SessionError.readOnly.localizedDescription }
        if !perplTrading.ordersAreLive { return "Perpl trading isn't connected. Reconnect in Profile → Perpl Trading to cancel." }
        if perplTrading.status == .needsForwarding { return "Enable one-click trading in Profile to cancel from the app." }
        return nil
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orders) { order in
                        DetailRow(order.isStopLoss ? "Stop loss" : "Take profit", triggerText(order), tint: order.isStopLoss ? .negative : .positive)
                    }
                } header: {
                    Text("\(market.asset)-PERP · on \(orders.first?.protectsLong == false ? "Short" : "Long")")
                } footer: {
                    if let note { Text(note) }
                }
                if session.isPasskeyAccount, !finished {
                    Section { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.cancelOrder.summary)) }
                }
                if let unavailable, !finished {
                    Section { InlineError(message: unavailable) }.listRowBackground(Color.clear)
                }
                TriggerSheetOutcomeSection(phase: phase)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Close") { let reload = finished; dismiss(); if reload { onDone() } }.disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !finished {
                    PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (orders.count == 1 ? "Cancel Trigger" : "Cancel \(orders.count) Triggers"),
                                  isBusy: busy, isDisabled: unavailable != nil || orders.isEmpty, foreground: .onStatus) {
                        Task { await apply() }
                    }
                    .tint(.negative)
                    .padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private func triggerText(_ order: PerplOpenOrder) -> String {
        let price = Double(order.triggerPriceRaw ?? 0) / pow(10, Double(market.priceDecimals))
        let size = Double(order.sizeRaw) / pow(10, Double(market.lotDecimals))
        return "\(NumberStyle.number(price)) · \(NumberStyle.number(size)) \(market.asset)"
    }

    private func apply(approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Cancel TP/SL")) { return }
        phase = .working
        do {
            let acks = try await perplTrading.cancel(orders: orders, approval: approval)
            var lines: [TriggerSheetLine] = []
            var cancelled = 0
            for order in orders {
                let what = "\(order.isStopLoss ? "stop-loss" : "take-profit") at \(triggerText(order))"
                guard let ack = acks[order.id] else { continue }
                if ack.accepted {
                    cancelled += 1
                    lines.append(TriggerSheetLine(text: "Cancel sent for the \(what). It leaves the list when Perpl confirms.", warning: false))
                    TriggerStore.remove(perpId: market.id, kind: order.isStopLoss ? .stopLoss : .takeProfit, positionLong: order.protectsLong, owner: session.address)
                } else if ack.outcomeUnknown {
                    lines.append(TriggerSheetLine(text: "Perpl didn't confirm cancelling the \(what). Check Orders before trying again.", warning: true))
                } else {
                    lines.append(TriggerSheetLine(text: "Perpl refused to cancel the \(what): \(ack.error ?? "no reason given"). It is still live.", warning: true))
                }
            }
            phase = .finished(lines)
            if cancelled > 0 {
                Activity.record(ActivityRecord(kind: .perp, title: cancelled == 1 ? "Cancelled TP/SL" : "Cancelled \(cancelled) TP/SL", subtitle: "\(market.asset)-PERP", hash: nil, section: "perps"), owner: session.address)
            }
        } catch is MeraSession.StepUpRequired where approval == nil {
            do {
                let approval = try await session.mera.stepUp()
                await apply(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed("Nothing was cancelled.")
            } catch {
                phase = .failed(describe(error))
            }
        } catch {
            phase = .failed(describe(error))
        }
    }
}

/// Where a TP/SL sheet is: editing, sending, done with a line per step, or failed before anything was sent.
enum TriggerSheetPhase: Equatable {
    case editing, working
    case finished([TriggerSheetLine])
    case failed(String)
}

struct TriggerSheetLine: Equatable, Hashable {
    let text: String
    let warning: Bool
}

/// The outcome block both TP/SL sheets end with.
struct TriggerSheetOutcomeSection: View {
    let phase: TriggerSheetPhase

    var body: some View {
        switch phase {
        case .finished(let lines):
            Section {
                ForEach(lines, id: \.self) { line in
                    Label(line.text, systemImage: line.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(line.warning ? Color.attention : Color.positive)
                        .font(.footnote)
                }
            }
        case .failed(let message):
            Section { InlineError(message: message) }.listRowBackground(Color.clear)
        case .editing, .working:
            EmptyView()
        }
    }
}
