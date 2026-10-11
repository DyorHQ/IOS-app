import BigInt
import DyorKit
import SwiftUI

/// Adds AUSD collateral to an open position — lowering its leverage and pushing the liquidation price away. Sent as a
/// wallet transaction, the margin the position received is read from the receipt once it confirms, and said before Done.
/// With one-click live for the account at the tap (`route`), it goes to Perpl over the trading connection instead, and
/// its result is Perpl's evidence (p4 spec A.4.3): added, refused, or not confirmed in time — said in the sheet while it
/// is open, else as a notification, and in Activity either way.
struct AddMarginSheet: View {
    let market: PerpMarket
    let position: PerpPosition
    let available: Double
    /// The Perpl account the margin is added for: its own request is read from the receipt.
    var accountId: Int?
    /// The trading connection's route for this margin, fixed at the tap that opened the sheet; nil: the wallet transaction.
    var route: PerplTrading.ActionAccount? = nil
    /// The margin's result was read: the caller reads the position again at once.
    var onSettled: () -> Void = {}
    let onDone: () -> Void

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var amountText = ""
    /// The desc id the plan sent signs (what finds it in its receipt), fixed at the tap.
    @State private var sentDescId: UInt64?
    /// What the transaction did, once read from its receipt; nil while it is read.
    @State private var settled: PerplOutcomeText?
    /// The receipt is being read now, and Done is held for the first moments of it (`ReceiptResultBar.doneHold`).
    @State private var reading = false
    @State private var holdingDone = false
    /// The trading connection's margin (`route`): where it is, from the confirm to Perpl's evidence.
    @State private var apiPhase: APIPhase = .review
    /// The request's row id once it was written (its result, live, is `PerplTrading.marginResults[id]`).
    @State private var marginId: UUID?
    /// This market's position read when the sheet opened, and when: the margin's "before" (else the position tapped).
    @State private var freshBefore: PerpPosition?
    @State private var freshBeforeAt: Date?
    /// The one line under a not-sent failure (nil: refused on the device).
    @State private var failureLine: String?
    @State private var announcedHeadline: String?
    #if DEBUG && targetEnvironment(simulator)
    @Environment(\.perpsDemoAutoConfirm) private var demoAutoConfirm
    @Environment(\.perpsDemoTerms) private var demoTerms
    #endif

    enum APIPhase: Equatable {
        case review, authorizing, sending
        case waiting(id: UUID, since: Date, acknowledged: Bool)
        case settled(PerplTrading.MarginResult)
        case failed(String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    private var amount: Double { amountText.perpDouble ?? 0 }
    private var overBalance: Bool { amount > available + 0.000001 }
    private var canConfirm: Bool { session.canSign && !run.isRunning && amount > 0 && !overBalance }

    private var projMargin: Double { position.margin + max(0, amount) }
    private var projLeverage: Double { projMargin > 0 ? position.notional / projMargin : position.leverage }
    private var projLiquidation: Double? {
        PerplService.liquidationPrice(side: position.side, entry: position.entry, size: position.size, margin: projMargin, premium: position.premium, maintenanceFraction: market.maintMarginFraction)
    }

    /// The margin's result as it stands: a later check may have changed what the wait said.
    private var apiResult: PerplTrading.MarginResult? {
        guard case .settled(let result) = apiPhase else { return nil }
        return marginId.flatMap { perplTrading.marginResults[$0] } ?? result
    }

    /// The result in words, with the tone its icon, colour and haptic follow.
    private var apiText: PerplOutcomeText? {
        switch apiResult {
        case .added(let cns)?:
            return PerplOutcomeText(headline: PerpOnChainCopy.marginAdded(NumberStyle.units(cns, decimals: 6)), detail: nil, tone: .success)
        case .refused(let why, _)?:
            return PerplOutcomeText(headline: PerpActionCopy.marginNotAdded, detail: why, tone: .failure)
        case .notConfirmed?:
            return PerplOutcomeText(headline: PerpActionCopy.marginNotConfirmed, detail: PerpActionCopy.marginCheck, tone: .warning)
        case nil:
            return nil
        }
    }

    /// The terms can't change once the margin is on its way, or the wallet's is signing or done.
    private var termsLocked: Bool { apiPhase != .review && !apiPhase.isFailed || run.isRunning || run.isDone || run.sentSomething }

    // A Moment link waits while this review is on screen (RootView's link gate).
    var body: some View { reviewContent.holdsMomentLinks() }

    @ViewBuilder private var reviewContent: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow("Position", verbatim: PositionText.amount(isLong: position.side == .long, size: position.size, asset: position.symbol), tint: position.side == .long ? .positive : .negative)
                    DetailRow("Current margin", PriceFormat.usdValue(position.margin))
                    DetailRow("Available", PriceFormat.usdValue(available))
                }
                Section {
                    HStack {
                        Text("Amount").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0" as String, text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                            .disabled(termsLocked)
                        Text("AUSD").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach([0.25, 0.5, 1.0], id: \.self) { frac in
                            Button { amountText = plainAmount(available * frac) } label: {
                                frac == 1.0 ? Text("Max", comment: "The most allowed: a button or chip that fills in the whole balance, or the highest leverage or amount [tight]") : Text(verbatim: "\(Int(frac * 100))%")
                            }
                            .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                            .disabled(termsLocked)
                        }
                    }
                    if overBalance { Text("More than your available balance.").font(.caption).foregroundStyle(.negative) }
                } header: {
                    Text("Add margin")
                } footer: {
                    if route != nil { Paragraph("Signed and forwarded by your Perpl API key over the trading connection.") }
                }
                if amount > 0, !overBalance {
                    Section("After") {
                        DetailRow("Margin", PriceFormat.usdValue(projMargin))
                        DetailRow("Leverage", verbatim: "\(NumberStyle.number(projLeverage, maximumFractionDigits: 1))×")
                        DetailRow("Liq. price", verbatim: projLiquidation.map { NumberStyle.number($0) } ?? (market.maintMarginFraction == nil ? PositionText.unknown : "—"))
                    }
                }
                if !run.events.isEmpty { Section("Progress") { TransactionProgress(events: run.events, neutralConfirmation: true) } }
                if let settled { PerpOrderOutcomeSection(text: settled) }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
                if let apiText {
                    PerpOrderOutcomeSection(text: apiText)
                    // A refusal at the gateway: nothing was forwarded, and the reopened sheet says how it will be sent.
                    if case .refused(_, true)? = apiResult, let failureLine {
                        Section { Paragraph(verbatim: failureLine).font(.footnote).foregroundStyle(.secondary) }.listRowBackground(Color.clear)
                    }
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
            .navigationTitle(tr("Add Margin"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Once the request is written it can't be called back: "Close" (Perpl may still add it, and the result
                    // comes as a notice), "Done" when it is in; "Cancel" only while nothing has been sent.
                    Button(run.isDone || apiResult != nil ? "Done" : (marginId != nil || apiPhase == .sending ? "Close" : "Cancel")) { finish() }
                        .disabled(run.isRunning || holdingDone || apiPhase == .authorizing || apiPhase == .sending)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let route {
                        apiBar(route)
                    } else if run.isDone {
                        // The margin the position received, read from the receipt (Done held for the first moments).
                        ReceiptResultBar(settled: settled, reading: reading, holdingDone: holdingDone) { finish() }
                    } else if case .failed = run.phase, run.sentSomething {
                        // Already on the network: no re-confirm (it would replay the plan), as in ConfirmationSheet.
                        Text(TransactionRun.alreadySent).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                    } else if !session.canSign {
                        Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        // Moving margin isn't in a passkey session's scope (MERA-PLAN §3): one Face ID when it's signed.
                        if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.unlisted.summary)) }
                        PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Add Margin", isBusy: run.isRunning, isDisabled: !canConfirm) {
                            Task {
                                if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm add margin")) { return }
                                let plan = env.perpl.addMarginPlan(market: market, amount: amount)
                                sentDescId = PerplReceipt.descId(ofPlan: plan)
                                run.start(plan, session: session, sender: env.sender)
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
        // The result's tone, once read: the margin read back is a success; a receipt that can't be read is a warning.
        .sensoryFeedback(trigger: settled?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        .sensoryFeedback(trigger: apiText?.tone) { _, tone in tone.flatMap(PerpOutcomeTone.feedback) }
        // Recorded when the margin settles, not when the sheet is dismissed: a settled sheet can be swiped away.
        .onChange(of: run.phase) { _, phase in
            if case .done(let hash) = phase {
                // A confirmed `revertOnFail` transaction already proves the margin went in: the row is true without a decode.
                Activity.record(ActivityRecord(kind: .deposit, title: tr("Added \(position.symbol) margin"), subtitle: "\(NumberStyle.number(amount)) AUSD", hash: hash, section: "perps", usd: amount), owner: session.address)
                readResult(hash)
            }
        }
        // Each new result headline over the trading connection, announced (not confirmed first, then added).
        .onChange(of: apiText?.headline) { _, headline in
            guard let headline, headline != announcedHeadline else { return }
            announcedHeadline = headline
            AccessibilityNotification.Announcement(headline).post()
        }
        .task {
            // The market's position now: what the margin is compared with on the chain.
            guard let route, let fresh = await perplTrading.readPosition(market: market, for: route) else { return }
            freshBefore = fresh.position
            freshBeforeAt = fresh.at
        }
        .onDisappear {
            // A result decided from now on posts its notice (and its Activity row, either way).
            if let marginId { perplTrading.setMarginPresented(marginId, false) }
        }
        #if DEBUG && targetEnvironment(simulator)
        // The scripted Perps demo only (`PerpsDemo`): its amount, and with Run this sheet's own confirm 2 s after it appears
        // (App Lock still asks).
        .task {
            guard perplTrading.isDemo else { return }
            if let amount = demoTerms?.amountText { amountText = amount }
            guard let demoAutoConfirm, let route else { return }
            try? await Task.sleep(for: demoAutoConfirm)
            confirmAPI(route)
        }
        #endif
    }

    /// Where the button was, on the trading connection's path: the button (again after a failure before anything was
    /// sent), "Sending to Perpl…", "Waiting for Perpl…" (closable after 3 s: the result comes as a notification and in
    /// Activity), then the result with Done.
    @ViewBuilder private func apiBar(_ route: PerplTrading.ActionAccount) -> some View {
        switch apiPhase {
        case .review, .failed, .authorizing:
            if !session.canSign {
                Paragraph(SessionError.readOnly.localizedDescription).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                if session.isPasskeyAccount { SessionScopeBadge(assessment: .faceID(Mera.AlwaysAsk.unlisted.summary)) }
                PrimaryButton(title: session.isPasskeyAccount ? "Confirm with \(BiometricGate.promptName)" : "Add Margin", isBusy: apiPhase == .authorizing, isDisabled: !canConfirm) {
                    confirmAPI(route)
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView()
                Paragraph(verbatim: PerpOrderCopy.sending).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .waiting(_, let since, let acknowledged):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Paragraph(verbatim: acknowledged ? PerpOrderCopy.waiting : PerpOrderCopy.stillListening).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if context.date.timeIntervalSince(since) >= 3 {
                        Paragraph(verbatim: PerpActionCopy.marginCanClose).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PrimaryButton(title: "Close", systemImage: "xmark") { finish() }
                }
            }
        case .settled:
            VStack(spacing: 8) {
                if let apiText { PerpOrderStatusBar(text: apiText) }
                PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
            }
        }
    }

    /// The confirm on the trading connection (A.3.1): ignored unless nothing is under way, and busy at once, before the
    /// App Lock prompt — a double tap can never send a second request.
    private func confirmAPI(_ route: PerplTrading.ActionAccount) {
        guard apiPhase == .review || apiPhase.isFailed else { return }
        apiPhase = .authorizing
        failureLine = nil
        Task { await addOverAPI(route) }
    }

    /// The margin over the trading connection: App Lock (as the wallet's margin asks it), the passkey session held for the
    /// send (GL-1), the amount checks the device can make before any step-up, then `PerplTrading.addMargin` — a passkey
    /// account's always asks first (MERA-PLAN §3) — which writes the row and, once this sheet is gone, the notice.
    private func addOverAPI(_ route: PerplTrading.ActionAccount, approval: MeraSession.StepUp? = nil) async {
        if approval == nil, settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm add margin")) {
            apiPhase = .review
            return
        }
        session.mera.beginAction()
        defer { session.mera.endAction() }
        // Refused on the device before any step-up: more than the account has free, or an amount that rounds to zero.
        if overBalance {
            apiPhase = .failed(PerpActionCopy.marginOverAvailable)
            return
        }
        if let problem = PerplOrders.problem(PerplOrders.addMargin(perpId: market.id, amountCNS: PerplService.toCNS(amount), accountId: route.accountId)) {
            apiPhase = .failed(problem)
            return
        }
        apiPhase = .sending
        do {
            let result = try await perplTrading.addMargin(market: market, amount: amount, account: route, before: freshBefore ?? position, approval: approval,
                                                          beforeAt: freshBefore != nil ? freshBeforeAt : nil) { id, acknowledged in
                marginId = id
                perplTrading.setMarginPresented(id, true)
                apiPhase = .waiting(id: id, since: Date(), acknowledged: acknowledged)
            }
            if case .refused(_, true) = result { failureLine = perplTrading.nothingSentLine(for: route) }
            apiPhase = .settled(result)
            onSettled()
        } catch is MeraSession.StepUpRequired where approval == nil {
            // MERA-PLAN §3: one pinned passkey ceremony approves this margin, then it is sent.
            do {
                let approval = try await session.mera.stepUp()
                await addOverAPI(route, approval: approval)
            } catch where isUserCancellation(error) {
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(TransactionRun.notSent)
            } catch {
                failureLine = perplTrading.nothingSentLine(for: route)
                apiPhase = .failed(describe(error))
            }
        } catch {
            // Refused on the device: the message says why, and nothing else needs saying.
            failureLine = (error as? PerplTradeError)?.isInvalidOrder == true ? nil : perplTrading.nothingSentLine(for: route)
            apiPhase = .failed(describe(error))
        }
    }

    /// Reads the receipt in a task of its own, only to word the result: the margin the position received, or — when it
    /// can't be read — that it confirmed and the position shows the margin (never that the margin is missing).
    private func readResult(_ hash: Data) {
        reading = true
        holdingDone = true
        Task { @MainActor in
            try? await Task.sleep(for: ReceiptResultBar.doneHold)
            holdingDone = false
        }
        let accountId = accountId
        let descId = sentDescId
        let perpl = env.perpl
        Task { @MainActor in
            let background = BackgroundTime("Perpl result") // not localized: the background task's name, never shown
            defer { background.end() }
            let requests = try? await perpl.receiptRequests(hash)
            if let accountId, let added = PerplReceipt.marginAdded(requests, accountId: accountId, descId: descId.map { BigUInt($0) }) {
                let amount = NumberStyle.units(added, decimals: 6)
                settled = PerplOutcomeText(headline: PerpOnChainCopy.marginAdded(amount), detail: nil, tone: .success)
            } else {
                settled = PerplOutcomeText(headline: PerpOnChainCopy.marginUnreadable, detail: nil, tone: .warning)
            }
            reading = false
            holdingDone = false
            onSettled()
            if let settled { AccessibilityNotification.Announcement(settled.headline).post() }
        }
    }

    private func plainAmount(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private func finish() {
        // Done after a result (the wallet's or Perpl's), or closed while Perpl's is awaited: the screen behind reads again.
        let done = run.isDone || marginId != nil
        dismiss()
        if done { onDone() }
    }
}
