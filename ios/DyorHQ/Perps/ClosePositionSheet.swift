import BigInt
import DyorKit
import SwiftUI

/// Closes a position at market or with a resting reduce-only limit order (optionally post-only), all of it or 25 / 50 /
/// 75%. Sent as a wallet transaction, what it did is read from its receipt once it confirms — closed in full or in part,
/// resting on the book, or nothing filled — and said before Done (the transaction alone only says it ran: a market close
/// with nothing within its slippage confirms too). With one-click live for the account at the tap (`route`), it goes to
/// Perpl over the trading connection instead and its result is followed on Perpl's stream (p4 spec A.4.1): the same words,
/// as they happen, whether the sheet stays open or not.
struct ClosePositionSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let mark: Double
    /// The Perpl account the close is sent for: its own request is read from the receipt.
    var accountId: Int?
    /// The live TP/SL closing this position's side, to say what happens to them.
    var leftoverTriggers: [PerplOpenOrder] = []
    /// The trading connection's route for this close, fixed at the tap that opened the sheet; nil: the wallet transaction.
    var route: PerplTrading.ActionAccount? = nil
    /// The close is about to be sent (`whole`: the 100% chip), and — if it then fails before anything left the device, or
    /// it filled nothing — it didn't close: so the positions poll knows the position's disappearance is expected from the
    /// moment it could happen, not only once Done is tapped, and is news again when nothing closed. A partial close
    /// never notes a close of the position.
    var onSending: (_ whole: Bool) -> Void = { _ in }
    var onNotSent: () -> Void = {}
    /// The close's result was read: the caller reads the position again at once.
    var onSettled: () -> Void = {}
    /// The caller's reload, on Done.
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var kind: OrderKind = .market
    @State private var limitText = ""
    @State private var postOnly = false
    /// The size chip: 25, 50, 75 or 100 (% of the position as the chain reports it).
    @State private var percent = 100
    /// The desc id the plan sent signs (what finds the close in its receipt), fixed at the tap.
    @State private var sentDescId: UInt64?
    /// What the close did, once read from its receipt; nil while it is read.
    @State private var settled: PerplOutcomeText?
    /// The receipt is being read now, and Done is held for the first moments of it (`ReceiptResultBar.doneHold`).
    @State private var reading = false
    @State private var holdingDone = false
    /// The trading connection's close (`route`): where it is, from the confirm to Perpl's result.
    @State private var apiPhase: APIPhase = .review
    /// The one line under a not-sent failure (nil: refused on the device).
    @State private var failureLine: String?
    /// When the close started waiting for Perpl (the "you can close this" line shows after 3 s).
    @State private var waitingSince: Date?
    /// The result headline VoiceOver last announced.
    @State private var announcedHeadline: String?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    @Environment(\.perpsDemoTerms) private var demoTerms
    @Environment(\.perpsDemoTryAgain) private var demoTryAgain
    #endif

    enum APIPhase: Equatable {
        case review, authorizing, sending, tracking(UUID), failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    private var isLimit: Bool { kind == .limit }
    private var limitPrice: Double? { limitText.perpDouble }
    /// A limit close far through the mark would fill at once (a decimal slip): refused, as on the order ticket. The
    /// close trades the opposite side of the position.
    private var limitProblem: String? {
        guard isLimit, let limitPrice, limitPrice > 0 else { return nil }
        if let offTick = OrderTicket.offTickProblem(price: limitPrice, market: market) { return offTick }
        return OrderTicket.throughMarkProblem(price: limitPrice, side: position.side == .long ? .short : .long, mark: mark, market: market)
    }
    /// The size the chip closes, at the market's lot precision (nil: less than one lot).
    private func chipSize(_ percent: Int) -> Double? {
        PerplService.closeFractionSize(positionSize: position.size, lotDecimals: market.lotDecimals, percent: percent)
    }
    private var sentSize: Double { chipSize(percent) ?? position.size }
    private var canConfirm: Bool { session.canSign && !run.isRunning && (!isLimit || (limitPrice ?? 0) > 0) && limitProblem == nil && chipSize(percent) != nil }

    private var steps: [TransactionStep] {
        env.perpl.closePositionPlan(market: market, position: position, slippageBps: Self.slippageBps, kind: kind, limitPrice: limitPrice, postOnly: postOnly, size: sentSize)
    }

    /// The close this sheet follows over the trading connection.
    private var tracked: PerplTrackedOrder? {
        if case .tracking(let id) = apiPhase { return perplTrading.orders.order(id) }
        return nil
    }
    private var isTracking: Bool { if case .tracking = apiPhase { return true }; return false }
    /// Perpl's final word that the close executed nothing: Try Again, with the terms editable again.
    private var executedNothing: Bool { tracked?.entry?.executedNothing == true }
    /// Perpl refused the close because order forwarding is off (OrderForwardingNotAllowed, sr 34): the trading route rests,
    /// so no Try Again here — the reopened sheet sends it from the wallet, and the sheet says so.
    private var refusedForForwarding: Bool {
        if case .failed(let reason)? = tracked?.entry { return reason.reason == 34 }
        return false
    }
    /// The result is in and isn't "not confirmed": Done, not Close.
    private var isDecided: Bool { tracked?.entry.map { !PerplTracker.isUnconfirmed($0) } ?? false }
    /// The terms can't change: a close is being confirmed, sent or followed (until Perpl says it executed nothing), or the
    /// wallet's is signing or done.
    private var termsLocked: Bool {
        switch apiPhase {
        case .authorizing, .sending: return true
        case .tracking: return !executedNothing || refusedForForwarding
        case .review, .failed: return run.isRunning || run.isDone || run.sentSomething
        }
    }
    /// The close's result in words, a close Perpl never answered saying it may have gone through.
    private func closeText(_ order: PerplTrackedOrder, _ entry: PerplOrderOutcome) -> PerplOutcomeText {
        let words = PerplOutcomeText.close(entry, order.textContext)
        guard PerplTracker.isUnconfirmed(entry), !order.acknowledged else { return words }
        return PerplOutcomeText(headline: words.headline, detail: PerpActionCopy.closeUnknown, tone: words.tone)
    }
    private var trackedHeadline: String? {
        guard let order = tracked, let entry = order.entry else { return nil }
        return PerplOutcomeText.close(entry, order.textContext).headline
    }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: PositionText.amount(isLong: position.side == .long, size: position.size, asset: position.symbol), tint: position.side == .long ? .positive : .negative)
                    DetailRow("Mark price", NumberStyle.number(mark))
                    DetailRow("Unrealized", PriceFormat.usdValue(position.unrealized, signed: true), tint: position.unrealized < 0 ? .negative : .positive)
                }
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]").tag(OrderKind.market)
                        Text("Limit", comment: "Order type: rests at the price you set until it fills. [tight]").tag(OrderKind.limit)
                    }
                    .pickerStyle(.segmented)
                    .disabled(termsLocked)
                    HStack(spacing: 8) {
                        ForEach([25, 50, 75, 100], id: \.self) { chip in
                            Button { percent = chip } label: { Text(verbatim: "\(chip)%") }
                                .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                                .tint(percent == chip ? Color.brand : Color.secondary)
                                .disabled(termsLocked || chipSize(chip) == nil)
                                .accessibilityAddTraits(percent == chip ? .isSelected : [])
                        }
                    }
                    DetailRow("Size", verbatim: PositionText.amount(isLong: position.side == .long, size: sentSize, asset: position.symbol))
                    if isLimit {
                        HStack {
                            Text("Limit price").foregroundStyle(.secondary)
                            Spacer()
                            TextField(NumberStyle.number(mark), text: $limitText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                                .disabled(termsLocked)
                        }
                        // The price this close signs, read back from the typed text.
                        if let limitPrice, limitPrice > 0 { DetailRow("Limit at", NumberStyle.number(limitPrice, maximumFractionDigits: market.priceDecimals)) }
                        if let limitProblem { Paragraph(limitProblem).font(.footnote).foregroundStyle(Color.attention) }
                        Toggle("Post only (maker)", isOn: $postOnly).disabled(termsLocked)
                        Paragraph("Rests as a reduce-only limit at your price until it fills. It won't reduce your position until then.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DetailRow("Order", "Market, reduce-only, 1% slippage")
                    }
                } header: {
                    Text("Close order")
                } footer: {
                    if route != nil { Paragraph("Signed and forwarded by your Perpl API key over the trading connection.") }
                }
                if !leftoverTriggers.isEmpty {
                    Section("Take-profit / stop-loss") {
                        leftoverNote(count: leftoverTriggers.count)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events, neutralConfirmation: true) } }
                if let settled { PerpOrderOutcomeSection(text: settled) }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
                if let order = tracked, let entry = order.entry {
                    PerpOrderOutcomeSection(text: closeText(order, entry))
                }
                if case .failed(let message) = apiPhase {
                    Section {
                        InlineError(message: message)
                        if let failureLine { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Close Position"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isTracking {
                        Button(isDecided ? "Done" : "Close") { finish() }
                    } else {
                        Button(run.isDone ? "Done" : "Cancel") { finish() }.disabled(run.isRunning || holdingDone || apiPhase == .authorizing || apiPhase == .sending)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let route {
                        apiBar(route)
                    } else if run.isDone {
                        // What the close did, read from its receipt (Done held for the first moments of the read).
                        ReceiptResultBar(settled: settled, reading: reading, holdingDone: holdingDone) { finish() }
                    } else if case .failed = run.phase, run.sentSomething {
                        // Already on the network: no re-confirm (it would replay the plan), as in ConfirmationSheet.
                        Text(TransactionRun.alreadySent).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        // A passkey account's close always asks (MERA-PLAN §3): one Face ID when it's signed.
                        if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.closePosition.summary)) }
                        PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (isLimit ? "Place Limit Close" : "Close at Market"), isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm close")) { return }
                                onSending(percent == 100)
                                // The plan built once: the desc id read back from its receipt is the one it signs.
                                let plan = steps
                                sentDescId = PerplReceipt.descId(ofPlan: plan)
                                run.start(plan, session: session, sender: env.sender, action: session.isPasskeyAccount ? MeraSession.Action(.alwaysAsks(.closePosition)) : nil)
                            }
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning || holdingDone || apiPhase == .sending || apiPhase == .authorizing)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        // The result's tone, once read: a full close is a success, a partial one or nothing closed is not.
        .sensoryFeedback(trigger: settled?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        .sensoryFeedback(trigger: tracked?.entry?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        // Recorded when the close settles, not when the sheet is dismissed: a settled sheet can be swiped away.
        .onChange(of: run.phase) { _, phase in
            switch phase {
            case .done(let hash):
                onSending(percent == 100) // settled: expected from now on, whenever the poll next reads
                // At the receipt: the close was sent and its result isn't read yet. No volume until a fill is read.
                Activity.record(ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(position.symbol), subtitle: PerpOnChainCopy.closeSent, hash: hash,
                                               section: "perps", usd: nil), owner: session.address, notify: false)
                readResult(hash)
            case .failed where !run.sentSomething:
                onNotSent()
            case .idle, .running, .failed:
                break
            }
        }
        // The close over the trading connection: its result as Perpl reports it — the positions are read again, a close
        // that executed nothing is news again — and every new headline is announced.
        .onChange(of: tracked?.entry) { _, entry in
            guard let entry, !PerplTracker.isUnconfirmed(entry) else { return }
            onSettled()
            if entry.executedNothing { onNotSent() }
        }
        .onChange(of: trackedHeadline) { _, headline in
            guard let headline, headline != announcedHeadline else { return }
            announcedHeadline = headline
            AccessibilityNotification.Announcement(headline).post()
        }
        .onDisappear {
            if case .tracking(let id) = apiPhase { perplTrading.orders.setPresented(id, false) }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): its terms, and with Run this sheet's own confirm 2 s after it appears
        // (App Lock still asks); its Try Again when the script says.
        .task {
            guard perplTrading.isDemo else { return }
            if let demoTerms {
                percent = demoTerms.percent
                kind = demoTerms.limitText == nil ? .market : .limit
                limitText = demoTerms.limitText ?? ""
                postOnly = demoTerms.postOnly
            }
            guard let demoAutoConfirm, let route else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            confirmAPI(route)
        }
        .onChange(of: demoTryAgain) { _, _ in
            if perplTrading.isDemo, let route { tryAgain(route) }
        }
        #endif
    }

    /// Where the close button was, on the trading connection's path: the button (again after a failure before anything
    /// was sent), "Sending to Perpl…", then the live status — waiting, its result with Done (and Try Again when Perpl
    /// said it executed nothing), or "not confirmed" with Close.
    @ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {
        switch apiPhase {
        case .review, .failed, .authorizing:
            if !session.canSign {
                Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.closePosition.summary)) }
                PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : (isLimit ? "Place Limit Close" : "Close at Market"),
                              isBusy: apiPhase == .authorizing, isDisabled: !canConfirm) {
                    confirmAPI(route)
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tracking:
            if let order = tracked {
                if let entry = order.entry, !PerplTracker.isUnconfirmed(entry) {
                    VStack(spacing: 8) {
                        PerpOrderStatusBar(text: closeText(order, entry))
                        if refusedForForwarding {
                            // One-click is off on Perpl: this route can't take it, the wallet's can.
                            Paragraph(verbatim: perplTrading.nothingSentLine(for: route)).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                        } else if entry.executedNothing {
                            // Perpl's final word: nothing executed, so a new close can't double it.
                            PrimaryButton(title: "Try Again", systemImage: "arrow.clockwise", isDisabled: !canConfirm) { tryAgain(route) }
                            Button("Done") { finish() }.font(.subheadline.weight(.semibold))
                        } else {
                            PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                        }
                    }
                } else if let entry = order.entry {
                    VStack(spacing: 8) {
                        PerpOrderStatusBar(text: closeText(order, entry))
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
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
                            PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                        }
                    }
                }
            }
        }
    }

    /// The confirm on the trading connection (A.3.1): ignored unless nothing is under way, and busy at once, before the
    /// App Lock prompt — a double tap can never start a second close.
    private func confirmAPI(_ route: PerplTrading.ActionAccount) {
        guard apiPhase == .review || apiPhase.isFailed else { return }
        apiPhase = .authorizing
        failureLine = nil
        Task { await closeOverAPI(route) }
    }

    /// Try Again after Perpl's final word that the close executed nothing: its result is marked seen (no status row for
    /// it), then a new confirm — App Lock, a passkey account's new step-up, a new request.
    private func tryAgain(_ route: PerplTrading.ActionAccount) {
        guard case .tracking(let old) = apiPhase, executedNothing, !refusedForForwarding else { return }
        perplTrading.orders.setPresented(old, false)
        perplTrading.orders.dismissBanner(old)
        apiPhase = .review
        confirmAPI(route)
    }

    /// The close over the trading connection: App Lock (as the wallet's close asks it), then the passkey session held for
    /// the send, then `submitClose` — a passkey account's close always asks first (MERA-PLAN §3) — and Perpl's
    /// result followed (`track`, whether this sheet stays open or not). Nothing is ever resent from here.
    private func closeOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm close")) {
            onNotSent()
            apiPhase = .review
            return
        }
        // A passkey session (and its trading socket) outlives leaving the app until this close is sent.
        session.mera.beginAction()
        defer { session.mera.endAction() }
        apiPhase = .sending
        let request = PerplTrading.CloseRequest(market: market, position: position, percent: percent, kind: kind, limitPrice: isLimit ? limitPrice : nil,
                                                postOnly: isLimit && postOnly)
        let whole = percent == 100
        let expectation = perplTrading.expectOrder(PerplService.closeInput(market: market, position: position, size: sentSize, slippageBps: Self.slippageBps),
                                                   held: (position.side, position.size))
        var followed = false
        defer { if !followed { perplTrading.releaseOrderExpectation(expectation) } }
        do {
            let (result, sent) = try await perplTrading.submitClose(request, account: route, env: env, approval: approval, onWriting: { whole in onSending(whole) })
            guard result.entry, let tracking = result.tracking else {
                // Perpl's gateway refused it: nothing was forwarded.
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(result.error ?? tr("Perpl rejected the order."))
                return
            }
            let id = perplTrading.track(tracking, input: sent, takeProfit: nil, stopLoss: nil, closes: position.side, held: (position.side, position.size), ttlBlocks: 100,
                                        before: position, beforeReadAt: nil, restingOnSide: false, expectation: expectation, purpose: .close(wholePosition: whole))
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            apiPhase = .tracking(id)
        } catch is MeraSession.StepUpRequired where approval == nil {
            // MERA-PLAN §3: one pinned passkey ceremony approves this close, then it is sent.
            do {
                let approval = try await session.mera.stepUp()
                await closeOverAPI(route, approval: approval)
            } catch where isUserCancellation(error) {
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(TransactionRun.notSent)
            } catch {
                onNotSent()
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(describe(error))
            }
        } catch let unanswered as PerplTrading.EntryUnanswered {
            // Written and never answered: it may have gone through. Followed like any order (I7), never resent.
            let id = perplTrading.track(unanswered.tracking, input: unanswered.input, takeProfit: nil, stopLoss: nil, closes: position.side,
                                        held: (position.side, position.size), ttlBlocks: 100, before: position, beforeReadAt: nil, restingOnSide: false,
                                        expectation: expectation, purpose: .close(wholePosition: whole))
            followed = true
            perplTrading.orders.setPresented(id, true)
            waitingSince = Date()
            apiPhase = .tracking(id)
        } catch {
            onNotSent()
            // Refused on the device: the message says why, and nothing else needs saying.
            failureLine = (error as? PerplTradeError)?.isInvalidOrder == true ? nil : perplTrading.nothingSentLine(for: route)
            apiPhase = .failed(describe(error))
        }
    }

    /// What the close says of the position, from what it was sent as.
    private var closeContext: PerplOutcomeText.Context {
        PerplOutcomeText.Context(asset: market.asset, priceDecimals: market.priceDecimals, lotDecimals: market.lotDecimals,
                                 requestedSize: sentSize, limitPrice: isLimit ? limitPrice : nil, isMarket: !isLimit, reducesPosition: true,
                                 slippageBps: Self.slippageBps, acknowledged: false)
    }

    /// The market close's slippage (`closePositionPlan`).
    private static let slippageBps = PerplTrading.CloseRequest.slippageBps

    /// Reads the close's receipt in a task of its own (a dismissed sheet still upgrades its row), and records what it did:
    /// closed or partly closed with the volume that filled at the price it filled at, a close resting on the book (no
    /// volume), or nothing filled (the close noted when it was sent is voided). A receipt that can't be read keeps the
    /// row it was sent with. One notice, with the result.
    private func readResult(_ hash: Data) {
        reading = true
        holdingDone = true
        Task { @MainActor in
            try? await Task.sleep(for: ReceiptResultBar.doneHold)
            holdingDone = false
        }
        let owner = session.address
        let symbol = position.symbol
        let context = closeContext
        let ordered = PositionText.amount(isLong: position.side == .long, size: sentSize, asset: position.symbol)
        let partOnly = percent < 100
        let accountId = accountId
        let descId = sentDescId
        let perpl = env.perpl
        Task { @MainActor in
            let background = BackgroundTime("Perpl result") // not localized: the background task's name, never shown
            defer { background.end() }
            let requests = try? await perpl.receiptRequests(hash)
            let outcome = accountId.flatMap { PerplReceipt.orderOutcome(requests, accountId: $0, descId: descId.map { BigUInt($0) }) }
            let row: ActivityRecord
            switch outcome {
            case .filled(let fill)?, .partlyFilled(let fill, _)?:
                let closed = PerplOutcomeText.amount(fill.size(lotDecimals: context.lotDecimals), context)
                let partly: Bool = { if case .partlyFilled? = outcome { return true }; return false }()
                let subtitle: String
                if let price = fill.price(priceDecimals: context.priceDecimals), price > 0 {
                    let at = NumberStyle.number(price, maximumFractionDigits: context.priceDecimals)
                    subtitle = partly
                        ? PerpOnChainCopy.partlyClosedAt(closed, of: PerplOutcomeText.amount(Double(fill.requestedSizeRaw) / pow(10, Double(context.lotDecimals)), context), price: at)
                        : PerpOnChainCopy.closedAt(closed, price: at)
                } else {
                    subtitle = closed
                }
                // Partly closed when the receipt says so, or the chip closed only part of the position.
                row = ActivityRecord(kind: .perp, title: partly || partOnly ? PerpOnChainCopy.partlyClosedTitle(symbol) : tr("Closed \(symbol)"), subtitle: subtitle, hash: hash, section: "perps",
                                     usd: outcome?.volumeUSD(priceDecimals: context.priceDecimals, lotDecimals: context.lotDecimals),
                                     feeUsd: fill.feeUSD.flatMap { $0 > 0 ? $0 : nil })
            case .resting?:
                let limit = tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
                row = ActivityRecord(kind: .perp, title: tr("Close order placed"), subtitle: "\(ordered) · \(limit)", hash: hash, section: "perps", usd: nil)
            case let decided? where decided.executedNothing:
                // Nothing closed: the position's ending is news again, and the row says the transaction filled nothing.
                onNotSent()
                PendingActivity.notFilled(hash, owner: owner)
                row = ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(symbol), subtitle: PerpOnChainCopy.nothingFilled, hash: hash, section: "perps", usd: nil)
            default:
                // Couldn't be read: the row it was sent with stays, said once.
                row = ActivityRecord(kind: .perp, title: PerpOnChainCopy.closeTitle(symbol), subtitle: PerpOnChainCopy.closeSent, hash: hash, section: "perps", usd: nil)
            }
            Activity.record(row, owner: owner)
            settled = outcome.map { PerplOutcomeText.close($0, context) }
                ?? PerplOutcomeText(headline: PerpOnChainCopy.unreadable, detail: nil, tone: .warning)
            reading = false
            holdingDone = false
            onSettled()
            if let settled { AccessibilityNotification.Announcement(settled.headline).post() }
        }
    }

    /// What happens to the position's TP/SL once it is closed, for its side and the kind of account. The count is a
    /// plural.
    @ViewBuilder private func leftoverNote(count: Int) -> some View {
        switch (session.isPasskeyAccount, position.side == .long) {
        case (true, true):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next long here).")
        case (true, false):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next short here).")
        case (false, true):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next long here. Check Orders afterwards.")
        case (false, false):
            Paragraph("This position has \(count) TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next short here. Check Orders afterwards.")
        }
    }

    private func finish() {
        // Done after a result (the wallet's or Perpl's): the screen behind reads the position again.
        let done = run.isDone || isTracking
        dismiss()
        if done { onDone() }
    }
}
