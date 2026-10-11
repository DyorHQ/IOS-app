import DyorKit
import SwiftUI

// The order sheet sent over the Perpl trading connection, and the trade ticket's state and number parsing.

/// Confirms and places an order through the authenticated Perpl trading connection (entry + optional TP/SL).
///
/// With the live outcome on at the tap (`live`, the owner's switch `PerplTrading.liveOutcomes`), the sheet follows the
/// order to what Perpl reported it did: filled (at what price, for what fee), partly filled, resting on the book, not
/// filled, refused — or, when Perpl's report doesn't come in time, that its result isn't confirmed yet. It can be closed
/// while it waits: `PerplTrading.track` keeps following the order, and the trade screen's status row shows the result.
/// Off, it is today's one-click sheet (`placeLegacy`): Perpl's acknowledgement, and the app-wide watcher reports a fill.
/// Nothing is ever resent from here: a second order needs a new tap on the ticket (the path fixed at the tap).
struct AuthedOrderSheet: View {
    let market: PerpMarket
    let input: OrderInput
    let takeProfit: Double?
    let stopLoss: Double?
    let accountId: Int
    let sideColor: Color
    let summaryMargin: Double
    /// What the triggers close when it isn't the order's size: what is left on the new side of a position the order
    /// turns around, with a note saying so.
    var triggerSize: Double? = nil
    var triggerNote: String? = nil
    /// The account's positions and orders as the Exchange last reported them, for the checks made where it is sent.
    var onChainPositions: [PerpPosition] = []
    var onChainOrders: [PerpOrder] = []
    /// The live outcome switch as it stood at the tap that opened this review: on, the sheet shows Perpl's result.
    var live = false
    /// The side of the position the order closes (`PerpCloseOrder.closes`), nil when it opens or adds.
    var closes: PositionSide? = nil
    /// The position held on this market at the tap, its side and size: what the order can grow.
    var held: (side: PositionSide, size: Double)? = nil
    /// Perpl's window for the order (`MarketContext.orderTTLBlocks`).
    var ttlBlocks: Int? = nil
    /// The markets the account's positions are read over (a read must cover every one it holds).
    var markets: [PerpMarket] = []
    /// This market's position at the last read before the tap, and when that read was: what the chain is compared with
    /// if Perpl's own report never comes (`PerplPositionEvidence`).
    var before: PerpPosition? = nil
    var beforeReadAt: Date? = nil
    /// An order that can grow the same side rests on this market (on the chain, or on Perpl's live list).
    var restingOnSide = false
    /// The entry went out (Perpl admitted it, or never answered, so it may be live) — before Done is tapped.
    var onSent: () -> Void = {}
    /// The sheet closed after the order was sent. `clearTicket`: it may have executed (filled, rests, not confirmed), so
    /// the ticket is cleared; false when it provably executed nothing, so it can be sent again as it is.
    let onDone: (_ clearTicket: Bool) -> Void

    @Environment(PerplTrading.self) private var perplTrading
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review
    /// This market's position read when the sheet opened: the order's "before" when the read finished before the tap.
    @State private var freshBefore: (position: PerpPosition?, at: Date)?
    /// When the order started waiting for Perpl (the "you can close this" line shows after 3 s).
    @State private var waitingSince: Date?
    @State private var finished = false
    /// The result headline VoiceOver last announced: each new one is announced (not confirmed, then filled), once.
    @State private var announcedHeadline: String?
    @State private var leftoverCancel: TriggerCancelRequest?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    #endif

    enum Phase: Equatable { case review, sending, tracking(UUID), failed(String), legacyDone, legacyDoneWarning(String), legacyUnknown(String) }

    /// The order this sheet follows.
    private var tracked: PerplTrackedOrder? {
        if case .tracking(let id) = phase { return perplTrading.orders.order(id) }
        return nil
    }

    /// The entry's result, once Perpl (or the chain) decided it; nil while it waits.
    private var settled: PerplOrderOutcome? { tracked?.entry }

    /// The tone the order settled with, for the haptic (nil while waiting).
    private var settledTone: PerplOrderOutcome.Tone? { settled?.tone }

    /// The result's headline as it stands (nil while waiting): what VoiceOver announces each time it changes.
    private var settledHeadline: String? {
        guard let order = tracked, let entry = order.entry else { return nil }
        return PerplOutcomeText.order(entry, order.textContext).headline
    }

    private var isTracking: Bool { if case .tracking = phase { return true }; return false }

    /// The result is in and isn't "not confirmed": Done, not Close.
    private var isDecided: Bool { settled.map { !PerplTracker.isUnconfirmed($0) } ?? false }

    /// The legacy sheet: the entry was placed (with or without every trigger) — the sheet closes on "Done" and reloads.
    private var isPlaced: Bool { if case .legacyDone = phase { return true }; if case .legacyDoneWarning = phase { return true }; return false }

    /// The legacy sheet: the order was sent but Perpl never confirmed it: it may be live, so there is no resend.
    private var isUnknown: Bool { if case .legacyUnknown = phase { return true }; return false }

    /// Nothing was sent yet (or what was tried failed before it left): the order button shows.
    private var canOrder: Bool { phase == .review || { if case .failed = phase { return true }; return false }() }

    /// A passkey account's badge: its live session places an opening order on its own within the caps; a reduce-only
    /// close, or anything while locked, asks for Face ID (MERA-PLAN §3).
    private var scopeAssessment: MeraSession.Assessment? {
        guard session.isPasskeyAccount else { return nil }
        if input.reduceOnly { return .faceID(Mera.AlwaysAsk.closePosition.summary) }
        return session.mera.assessOrder(usd: Mera.SpendingCaps.notionalUSD(of: input))
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: "\(market.asset)-PERP"))
                        DetailRow("Side", input.side == .long ? "Long" : "Short", tint: sideColor)
                        if input.kind == .limit, let flagged = PerpOrderCopy.limitType(price: NumberStyle.number(input.price ?? market.mark, maximumFractionDigits: market.priceDecimals), postOnly: input.postOnly, reduceOnly: input.reduceOnly) {
                            DetailRow("Type", verbatim: flagged)
                        } else {
                            DetailRow("Type", input.kind == .market ? "Market · \(NumberStyle.basisPoints(input.slippageBps)) slippage" : "Limit at \(NumberStyle.number(input.price ?? market.mark, maximumFractionDigits: market.priceDecimals))")
                        }
                        DetailRow("Size", verbatim: "\(NumberStyle.number(input.size, maximumFractionDigits: market.lotDecimals)) \(market.asset)")
                        DetailRow("Leverage", verbatim: "\(NumberStyle.number(input.leverage, maximumFractionDigits: 1))×")
                        DetailRow("Margin", PriceFormat.usdValue(summaryMargin))
                        // Each closes this order's size, fixed when placed.
                        if let takeProfit { DetailRow("Take profit", "\(NumberStyle.number(takeProfit)) · closes \(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)", tint: .positive) }
                        if let stopLoss { DetailRow("Stop loss", "\(NumberStyle.number(stopLoss)) · closes \(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)", tint: .negative) }
                    } header: {
                        Text("Review Order · Perpl")
                    } footer: {
                        if let triggerNote, takeProfit != nil || stopLoss != nil {
                            Paragraph(verbatim: WordWrap.sentences(triggerNote, tr("Signed and forwarded by your Perpl API key over the trading connection.")))
                        } else {
                            Paragraph("Signed and forwarded by your Perpl API key over the trading connection.")
                        }
                    }
                    if canOrder, let scopeAssessment {
                        Section { SessionScopeBadge(assessment: scopeAssessment) }
                    }
                    if case .failed(let message) = phase {
                        Section { InlineError(message: message) }.listRowBackground(Color.clear)
                    }
                    if case .legacyUnknown(let message) = phase {
                        Section {
                            Label { Paragraph(verbatim: message) } icon: { Image(systemName: "questionmark.circle.fill") }
                                .modifier(ParagraphLabel())
                                .foregroundStyle(Color.attention).font(.footnote)
                        }
                    }
                    if phase == .legacyDone {
                        Section { Label("Order sent to Perpl.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive) }
                    }
                    if case .legacyDoneWarning(let message) = phase {
                        Section {
                            Label("Order sent to Perpl.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive)
                            Label { Paragraph(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                .modifier(ParagraphLabel())
                                .foregroundStyle(Color.attention).font(.footnote)
                        }
                    }
                    if let order = tracked {
                        outcomeSection(order).id("outcome")
                    }
                }
                .listStyle(.insetGrouped)
                // The result comes in under the review: it is scrolled to once, and every new headline is announced
                // (a "not confirmed" first, then what Perpl decided).
                .onChange(of: settledHeadline) { _, headline in
                    guard let headline, headline != announcedHeadline else { return }
                    let first = announcedHeadline == nil
                    announcedHeadline = headline
                    if first { withAnimation { proxy.scrollTo("outcome", anchor: .top) } }
                    AccessibilityNotification.Announcement(headline).post()
                }
                // A take-profit or stop-loss that isn't known to be live is said the moment the order is followed: it is
                // scrolled to before the sheet can be closed.
                .onChange(of: isTracking) { _, tracking in
                    guard tracking, let order = tracked, let warning = PerpOrderCopy.triggerWarning(order) else { return }
                    withAnimation { proxy.scrollTo("outcome", anchor: .top) }
                    AccessibilityNotification.Announcement(warning).post()
                }
            }
            .navigationTitle(tr("Place Order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isTracking {
                        Button(isDecided ? "Done" : "Close") { close() }
                    } else {
                        Button(isPlaced ? "Done" : isUnknown ? "Close" : "Cancel") { let reload = isPlaced || isUnknown; dismiss(); if reload { onDone(true) } }
                            .disabled(phase == .sending)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .interactiveDismissDisabled(phase == .sending)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: isPlaced)
        // The order's result, felt: success, a warning, or an error; a cancel made elsewhere is no news.
        .sensoryFeedback(trigger: settledTone) { _, tone in
            switch tone {
            case .success?: return .success
            case .warning?: return .warning
            case .failure?: return .error
            case .neutral?, nil: return nil
            }
        }
        .task {
            // The market's position now: what the order is compared with if Perpl's own report never comes.
            guard live, let owner = session.address, let read = perplTrading.readPositions else { return }
            if let positions = try? await read(owner, markets.isEmpty ? [market] : markets) {
                freshBefore = (positions.first { $0.perpId == market.id }, Date())
            }
        }
        .sheet(item: $leftoverCancel) { request in
            CancelTriggersSheet(market: market, orders: request.orders, title: request.title, note: request.note) {}
        }
        .onDisappear {
            guard case .tracking(let id) = phase else { return }
            perplTrading.orders.setPresented(id, false)
            if !finished {
                finished = true
                onDone(PerplTracker.clearsTicket(perplTrading.orders.order(id)?.entry))
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): with Run, this sheet's own live confirm 2 s after it appears (App Lock
        // still asks). Never the switch-off sheet, which writes Activity for the account on screen.
        .task {
            guard perplTrading.isDemo, live, let demoAutoConfirm else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            if phase == .review { await place() }
        }
        #endif
    }

    /// Where the order button was: the live status, so it shows at the sheet's medium height.
    @ViewBuilder private var bottomBar: some View {
        switch phase {
        case .review, .failed:
            PrimaryButton(title: scopeAssessment?.needsFaceID == true ? "Confirm with \(BiometricGate.promptName)" : (input.side == .long ? "Long \(market.asset)" : "Short \(market.asset)"), foreground: .onStatus) {
                Task { if live { await place() } else { await placeLegacy() } }
            }
            .tint(sideColor)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        case .tracking:
            trackingBar.padding().frame(maxWidth: .infinity).background(.bar)
        case .legacyDone, .legacyDoneWarning, .legacyUnknown:
            EmptyView()
        }
    }

    @ViewBuilder private var trackingBar: some View {
        if let order = tracked {
            if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {
                VStack(spacing: 8) {
                    PerpOrderStatusBar(text: PerplOutcomeText.order(entry, order.textContext))
                    if entry.executedNothing {
                        Paragraph(verbatim: PerpOrderCopy.stillInTicket).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PrimaryButton(title: "Done", systemImage: "checkmark") { close() }
                }
            } else if let entry = order.entry {
                VStack(spacing: 8) {
                    PerpOrderStatusBar(text: PerplOutcomeText.order(entry, order.textContext))
                    PrimaryButton(title: "Close", systemImage: "xmark") { close() }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                            Paragraph(verbatim: order.acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let waitingSince, context.date.timeIntervalSince(waitingSince) >= 3 {
                            Paragraph(verbatim: PerpOrderCopy.canClose(market: "\(market.asset)-PERP")).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        PrimaryButton(title: "Close", systemImage: "xmark") { close() }
                    }
                }
            }
        }
    }

    /// The order's result in the list: the headline and detail, its take-profit and stop-loss, any warning, and a
    /// "View" link to the transaction Perpl filled it in.
    @ViewBuilder private func outcomeSection(_ order: PerplTrackedOrder) -> some View {
        let lines = outcomeLines(order)
        if let entry = order.entry {
            let words = PerplOutcomeText.order(entry, order.textContext)
            // Perpl never answered the entry: its result can't be known yet, and the triggers weren't sent.
            let text = PerplTracker.isUnconfirmed(entry) && !order.acknowledged
                ? PerplOutcomeText(headline: words.headline, detail: PerpOrderCopy.unknown(takeProfit: order.takeProfit != nil, stopLoss: order.stopLoss != nil), tone: words.tone)
                : words
            let link = entry.fill?.txid.flatMap { Data(hex: $0) }.map(Monad.explorerTransaction)
            let leftovers = perplTrading.liveTriggers(of: order.id)
            PerpOrderOutcomeSection(text: text, lines: lines, link: link) {
                if !leftovers.isEmpty {
                    Button(leftovers.count == 1 ? "Cancel It" : "Cancel Them") {
                        leftoverCancel = TriggerCancelRequest(orders: leftovers, title: "Leftover TP/SL", note: "There is no open position on \(market.asset) for these to close.")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
            }
        } else if !lines.isEmpty {
            PerpOrderOutcomeSection(text: nil, lines: lines)
        }
    }

    /// The lines under the result: a provisional failure while waiting, each take-profit / stop-loss as it settles, and
    /// the warning about triggers that aren't known to be live — from the moment the order is followed, whatever the entry
    /// is doing (`PerpOrderCopy.triggerWarning`).
    private func outcomeLines(_ order: PerplTrackedOrder) -> [PerpOrderOutcomeLine] {
        var lines: [PerpOrderOutcomeLine] = []
        if order.entry == nil, let provisional = order.provisional {
            lines.append(PerpOrderOutcomeLine(text: PerplOutcomeText.provisional(provisional), tone: .warning))
        }
        let entry = order.entry
        let executedNothing = entry?.executedNothing == true
        let filled = entry?.fill != nil || entry.map(PerplTracker.isObserved) == true
        let closing = "\(NumberStyle.number(triggerSize ?? input.size)) \(market.asset)"
        var cancelledWith: [PerplTriggerKind] = []
        var stillArmed: [PerplTriggerKind] = []
        var mayBeArmed: [PerplTriggerKind] = []
        for kind in [PerplTriggerKind.takeProfit, .stopLoss] {
            // A refused, unanswered or never-sent trigger is said by the warning below.
            guard let child = order.child(kind), child.accepted else { continue }
            let price = NumberStyle.number(child.price)
            let tp = kind == .takeProfit
            switch child.outcome {
            case nil:
                lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.checking(kind), tone: nil))
            case .armed?:
                if executedNothing {
                    // "Cancelled with it" only on evidence: a live list read after the entry no longer has it.
                    if child.armedWithoutPosition { stillArmed.append(kind) }
                    else if child.checkedNotListed { cancelledWith.append(kind) }
                    else if perplTrading.isFollowing(order.id) { lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.checking(kind), tone: nil)) }
                    else { mayBeArmed.append(kind) }
                } else if filled {
                    lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit set at \(price), closing \(closing).") : tr("Stop-loss set at \(price), closing \(closing)."), tone: .success))
                } else {
                    lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.accepted(kind, price: price), tone: .success))
                }
            case .triggered?:
                // "At once" only when its own wait right after placing it saw it fire; later, Perpl's words for a trigger.
                lines.append(PerpOrderOutcomeLine(text: child.settledDuringFollow ? PerpOrderCopy.triggeredAtOnce(kind, price: price) : PerpOrderCopy.triggeredLater(kind),
                                                  tone: .warning))
            case .cancelled(let reason)?:
                if executedNothing { cancelledWith.append(kind) }
                else if child.settledDuringFollow {
                    lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit not placed: \(reason.message)") : tr("Stop-loss not placed: \(reason.message)"), tone: .warning))
                } else {
                    // Placed, then cancelled later (from Orders, or after the other one fired): no cause is guessed.
                    lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.cancelledLater(kind), tone: .warning))
                }
            case .failed(let reason)?:
                lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit not placed: \(reason.message)") : tr("Stop-loss not placed: \(reason.message)"), tone: .warning))
            case .expired?:
                lines.append(PerpOrderOutcomeLine(text: tp ? tr("Take-profit expired") : tr("Stop-loss expired"), tone: .warning))
            case .unconfirmed?:
                lines.append(PerpOrderOutcomeLine(text: PerpOrderCopy.notListed(kind), tone: .warning))
            case .filled?, .partlyFilled?, .resting?, .notFilled?, .observed?:
                break
            }
        }
        if let text = PerpOrderCopy.cancelledWith(takeProfit: cancelledWith.contains(.takeProfit), stopLoss: cancelledWith.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .neutral))
        }
        if let text = PerpOrderCopy.stillArmed(takeProfit: stillArmed.contains(.takeProfit), stopLoss: stillArmed.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .warning))
        }
        // No live list could say yet whether they went with the entry: said, with the Cancel when Perpl lists them.
        if let text = PerpOrderCopy.mayStillBeArmed(takeProfit: mayBeArmed.contains(.takeProfit), stopLoss: mayBeArmed.contains(.stopLoss)) {
            lines.append(PerpOrderOutcomeLine(text: text, tone: .warning))
        }
        // Triggers never sent, refused or never answered: said from the start, whatever the entry is doing (the legacy
        // sheet said it at once too) — never only once the entry is in.
        if let warning = PerpOrderCopy.triggerWarning(order) {
            lines.append(PerpOrderOutcomeLine(text: warning, tone: .warning))
        }
        return lines
    }

    /// Closes the sheet once the order was sent: the order keeps being followed; the ticket is cleared unless the order
    /// provably executed nothing (a blind resend of an order that may have executed could double it).
    private func close() {
        let entry = tracked?.entry
        if case .tracking(let id) = phase { perplTrading.orders.setPresented(id, false) }
        dismiss()
        guard !finished else { return }
        finished = true
        onDone(PerplTracker.clearsTicket(entry))
    }

    /// Records the TP/SL Perpl admitted (or never answered: they may be live) on this device, shown as unverified until
    /// Perpl's list says otherwise (Perpl offers no read-back for keeper triggers). Returns each echo's id by kind: the
    /// order removes only its own echoes later, never another order's of the same kind.
    @discardableResult
    private func recordTriggerEchoes(_ result: PerplTrading.BracketResult) -> [PerplTriggerKind: UUID] {
        var placed: [PlacedTrigger] = []
        if let tp = takeProfit, result.takeProfit == true || result.takeProfitUnknown {
            placed.append(PlacedTrigger(perpId: market.id, symbol: market.asset, kind: .takeProfit, price: tp, size: input.size, positionLong: input.side == .long))
        }
        if let sl = stopLoss, result.stopLoss == true || result.stopLossUnknown {
            placed.append(PlacedTrigger(perpId: market.id, symbol: market.asset, kind: .stopLoss, price: sl, size: input.size, positionLong: input.side == .long))
        }
        var ids: [PerplTriggerKind: UUID] = [:]
        for echo in TriggerStore.record(placed, owner: session.address) { ids[echo.kind == .takeProfit ? .takeProfit : .stopLoss] = echo.id }
        return ids
    }

    /// The live outcome: the order is sent, then followed to Perpl's result (`PerplTrading.track`), which records its
    /// Activity row and posts its notice when the result is in — never at the acknowledgement.
    /// `approval`: a passkey account's step-up for this one order, when its session couldn't place it prompt-free.
    private func place(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers leveraged orders too (this path signs with the Perpl API key, not a confirmation sheet).
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm order")) { return }
        // A passkey session (and its trading socket) outlives leaving the app until this bracket is sent.
        session.mera.beginAction()
        defer { session.mera.endAction() }
        phase = .sending
        // From before the first frame: the app-wide watcher waits for this order's own result instead of announcing its
        // fill first (the entry's and its TP/SL's acknowledgements can take seconds). Let go unless the order is followed.
        let expectation = perplTrading.expectOrder(input, held: held)
        var followed = false
        defer { if !followed { perplTrading.releaseOrderExpectation(expectation) } }
        do {
            let result = try await perplTrading.submitBracket(input: input, accountId: accountId, takeProfit: takeProfit, stopLoss: stopLoss, env: env, ttlBlocks: 100, approval: approval,
                                                              onChainPositions: onChainPositions, onChainOrders: onChainOrders)
            guard result.entry, let tracking = result.tracking else { phase = .failed(result.error ?? tr("Perpl rejected the order.")); return }
            onSent()
            let echoes = recordTriggerEchoes(result)
            let id = perplTrading.track(tracking, input: input, takeProfit: takeProfit, stopLoss: stopLoss, closes: closes, held: held, ttlBlocks: ttlBlocks,
                                        before: freshBefore.map { $0.position } ?? before, beforeReadAt: freshBefore?.at ?? beforeReadAt, restingOnSide: restingOnSide,
                                        echoes: echoes, expectation: expectation)
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            phase = .tracking(id)
        } catch is MeraSession.StepUpRequired where approval == nil {
            // A passkey account whose session can't place this order prompt-free (locked, over a cap, a reduce-only
            // close): one pinned passkey ceremony approves this order and opens a new session, then it is placed.
            do {
                let approval = try await session.mera.stepUp()
                await place(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed(TransactionRun.notSent)
            } catch {
                phase = .failed(describe(error))
            }
        } catch let unanswered as PerplTrading.EntryUnanswered {
            // The entry went out and Perpl never answered: it may be live. It is followed like any other order (never
            // resent): Perpl's late report, its history or the chain may still say what it did. Its triggers weren't sent.
            onSent()
            let id = perplTrading.track(unanswered.tracking, input: input, takeProfit: takeProfit, stopLoss: stopLoss, closes: closes, held: held, ttlBlocks: ttlBlocks,
                                        before: freshBefore.map { $0.position } ?? before, beforeReadAt: freshBefore?.at ?? beforeReadAt, restingOnSide: restingOnSide,
                                        expectation: expectation)
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            phase = .tracking(id)
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// Today's one-click sheet (the live outcome off at the tap): Perpl's acknowledgement is the end of it, recorded and
    /// announced as an acknowledgement; the app-wide watcher reports the fill.
    private func placeLegacy(approval: MeraSession.StepUp? = nil) async {
        // App Lock covers leveraged orders too (this path signs with the Perpl API key, not a confirmation sheet).
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm order")) { return }
        // A passkey session (and its trading socket) outlives leaving the app until this bracket is sent.
        session.mera.beginAction()
        defer { session.mera.endAction() }
        phase = .sending
        do {
            // Bracket placement reports per-frame acceptance, so we record only the TP/SL Perpl actually admitted and
            // can warn if the entry opened without a requested protection (an unprotected position the user must know
            // about). Perpl offers no read-back for keeper triggers, so the accepted ones are remembered locally.
            let result = try await perplTrading.submitBracket(input: input, accountId: accountId, takeProfit: takeProfit, stopLoss: stopLoss, env: env, ttlBlocks: 100, approval: approval,
                                                              onChainPositions: onChainPositions, onChainOrders: onChainOrders)
            guard result.entry else { phase = .failed(result.error ?? tr("Perpl rejected the order.")); return }
            onSent()
            recordTriggerEchoes(result)

            let warning = triggerWarning(tp: takeProfit == nil || result.takeProfit == true ? nil : result.takeProfitUnknown,
                                         sl: stopLoss == nil || result.stopLoss == true ? nil : result.stopLossUnknown)
            phase = warning.map { .legacyDoneWarning($0) } ?? .legacyDone
            // notify:false — this advanced path posts its own fills-gated notification just below, so a unified
            // notification here would double it.
            // KNOWN EXCEPTION to "volume only from what filled" (owner decision pending, real-time spec §8): with the live
            // outcome switched off, this path never learns whether the order filled, so its row carries the requested
            // notional at the mark, as it always has — an order that fills nothing still adds to platform_volume. It
            // applies only while the owner's kill switch `perpsLiveOutcome` is off (the live path records only fills). Recording nil
            // here instead would drop all switch-off volume to zero, since the watcher's fill notice carries none.
            let perp = "\(market.asset)-PERP"
            let kind = input.kind == .market
                ? tr(LocalizedStringResource("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]"))
                : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
            Activity.record(ActivityRecord(kind: .perp, title: input.side == .long ? tr("Long \(perp)") : tr("Short \(perp)"), subtitle: "\(NumberStyle.number(input.size)) \(market.asset) · \(kind)", hash: nil, usd: input.size * market.mark > 0 ? input.size * market.mark : nil), owner: session.address, notify: false)
            if settings.notificationsEnabled, settings.notifyFills {
                let side = input.side == .long
                    ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
                    : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
                Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side: side, market: "\(market.asset)-PERP", perpId: market.id)
            }
        } catch is MeraSession.StepUpRequired where approval == nil {
            // A passkey account whose session can't place this order prompt-free (locked, over a cap, a reduce-only
            // close): one pinned passkey ceremony approves this order and opens a new session, then it is placed.
            do {
                let approval = try await session.mera.stepUp()
                await placeLegacy(approval: approval)
            } catch where isUserCancellation(error) {
                phase = .failed(TransactionRun.notSent)
            } catch {
                phase = .failed(describe(error))
            }
        } catch is PerplTrading.EntryUnanswered {
            // The entry frame went out but was never acknowledged: it may be live. Resending would place a second
            // order, so this sheet only closes (and reloads orders and positions) from here. Its triggers are sent only
            // after the entry is answered, so none of them went out: if the entry is live, it has no TP/SL.
            onSent()
            phase = .legacyUnknown(PerpOrderCopy.unknown(takeProfit: takeProfit != nil, stopLoss: stopLoss != nil))
        } catch let error as PerplTradeError where error.outcomeUnknown {
            onSent()
            phase = .legacyUnknown(PerpOrderCopy.unknown(takeProfit: takeProfit != nil, stopLoss: stopLoss != nil))
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// What to say about requested triggers that aren't known to be live: `false` refused (or never sent), `true`
    /// sent but unanswered — it may be live, so it must not be placed again blindly. Refused
    /// ones are set again from the position's TP/SL, not by opening more size.
    /// In the app's language; each combination is a sentence of its own.
    private func triggerWarning(tp: Bool?, sl: Bool?) -> String? {
        var parts: [String] = []
        let market = input.kind == .market
        switch (tp == false, sl == false) {
        case (true, true):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the take-profit and stop-loss. Set them with TP/SL on the position once the order fills."))
        case (true, false):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the take-profit. Set it with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the take-profit. Set it with TP/SL on the position once the order fills."))
        case (false, true):
            parts.append(market ? tr("Position opened, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position.")
                                : tr("Order sent, but Perpl didn't accept the stop-loss. Set it with TP/SL on the position once the order fills."))
        case (false, false):
            break
        }
        switch (tp == true, sl == true) {
        case (true, true):
            parts.append(tr("Order status unknown for the take-profit and stop-loss — Perpl didn't confirm them. Check Open Orders before placing them again."))
        case (true, false):
            parts.append(tr("Order status unknown for the take-profit — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, true):
            parts.append(tr("Order status unknown for the stop-loss — Perpl didn't confirm it. Check Open Orders before placing it again."))
        case (false, false):
            break
        }
        return parts.isEmpty ? nil : WordWrap.sentences(parts)
    }
}

// MARK: - Order ticket state

struct OrderTicket {
    enum AmountUnit { case asset, usd }
    var side: PositionSide = .long
    var kind: OrderKind = .market
    var sizeText = ""
    var priceText = ""
    var leverage: Double = 2
    var reduceOnly = false
    var postOnly = false
    var maxSlippageEnabled = false
    var slippageBps = 50
    var tpslEnabled = false
    var takeProfitText = ""
    var stopLossText = ""
    var amountUnit: AmountUnit = .asset

    /// Reduce-Only / Post-Only are Limit-only flags; a Market order must never carry them (it would change the order's
    /// meaning and, for reduceOnly, skip the margin guard below). This is the single source of truth — even if a stale
    /// flag survives a mode switch, the effective value here is always false for a market order.
    var effectiveReduceOnly: Bool { kind == .limit && reduceOnly }
    var effectivePostOnly: Bool { kind == .limit && postOnly }
    /// TP/SL only on an order that opens or adds: on a reduce-only order its triggers would close
    /// the side the account doesn't hold. Also enforced in `PerplTrading`.
    var effectiveTPSL: Bool { tpslEnabled && !effectiveReduceOnly }

    func baseSize(market: PerpMarket, price: Double) -> Double {
        let typed = sizeText.perpDouble ?? 0
        guard typed > 0, price > 0 else { return 0 }
        let raw = amountUnit == .usd ? typed / price : typed
        let scale = pow(10, Double(market.lotDecimals))
        return (raw * scale).rounded(.down) / scale
    }

    /// What's wrong with the ticket, in the app's language.
    /// - mark: the live mark the order is measured against (the market's listed mark when the live one is unknown).
    func problem(market: PerpMarket, mark: Double, account: PerpAccount?, available: Double) -> String? {
        let ref = mark > 0 ? mark : market.mark
        let price = kind == .limit ? (priceText.perpDouble ?? ref) : ref
        let size = baseSize(market: market, price: price)
        guard size > 0 else { return amountUnit == .usd ? tr("Enter an amount in AUSD.") : tr("Enter a size in \(market.asset).") }
        if kind == .limit, (priceText.perpDouble ?? 0) <= 0 { return tr("Enter a limit price.") }
        if kind == .limit, let limit = priceText.perpDouble, let reason = Self.offTickProblem(price: limit, market: market) { return reason }
        if kind == .limit, let limit = priceText.perpDouble, let reason = Self.throughMarkProblem(price: limit, side: side, mark: mark, market: market) { return reason }
        if account == nil, !effectiveReduceOnly { return tr("Deposit AUSD to open a trading account first.") }
        if account != nil, !effectiveReduceOnly {
            if size * price / max(leverage, 1) > available * 1.0001 { return tr("Not enough available margin.") }
        }
        return nil
    }

    /// A limit more than 5% through the mark fills at once as a taker: most often a decimal slip (1000x, in any locale),
    /// not a price anyone meant. Purely numeric; an unknown mark (0) blocks nothing. A buy (long) is refused above
    /// mark x 1.05, a sell (short) below mark x 0.95.
    static func throughMarkProblem(price: Double, side: PositionSide, mark: Double, market: PerpMarket) -> String? {
        guard mark.isFinite, mark > 0, price.isFinite, price > 0 else { return nil }
        let above = side == .long && price > mark * 1.05
        let below = side == .short && price < mark * 0.95
        guard above || below else { return nil }
        let limit = NumberStyle.number(price, maximumFractionDigits: market.priceDecimals)
        let markText = NumberStyle.number(mark)
        return above ? tr("Limit \(limit) is above the mark (\(markText)) and would fill at once. Check the price.")
            : tr("Limit \(limit) is below the mark (\(markText)) and would fill at once. Check the price.")
    }

    /// A limit between ticks: refused rather than rounded, so the price reviewed is the price signed.
    static func offTickProblem(price: Double, market: PerpMarket) -> String? {
        guard PerplTriggerRules.ticks(price, decimals: market.priceDecimals) == nil else { return nil }
        let d = market.priceDecimals
        return d == 0 ? tr("The limit price must be a whole number on \(market.asset).")
            : tr("The limit price can have at most \(d) decimal places on \(market.asset).")
    }

    func input(market: PerpMarket, refPrice: Double) -> OrderInput {
        OrderInput(market: market, side: side, kind: kind, size: baseSize(market: market, price: refPrice), price: kind == .limit ? priceText.perpDouble : nil, leverage: leverage, reduceOnly: effectiveReduceOnly, slippageBps: slippageBps, postOnly: effectivePostOnly)
    }
}

extension String {
    /// Parses a user-typed price, size or trigger (`Amount.fieldNumber`). The decimal pad shows the locale separator
    /// ("," across much of Europe/LatAm) while our own writers (`plainSize`) emit POSIX "."; a pasted "66,000" in en_US
    /// is 66000, never 66, and "0,5" is one half in every locale, never 5.
    var perpDouble: Double? { Amount.fieldNumber(self) }
}
