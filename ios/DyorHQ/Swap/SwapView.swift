import BigInt
import DyorKit
import SwiftUI

/// Spot swaps. Every venue is asked at once and the best output is preselected; the person can still pick another.
struct SwapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var model = SwapModel()
    @State private var picking: SwapModel.Side?
    /// The quote under review, frozen when the sheet opens. Quotes refresh every 15 s, and the sheet builds its plan
    /// once, so reading the live quote would let the details (and a passkey session's intent) drift from what's signed.
    @State private var reviewing: SwapReview?
    @State private var showSlippage = false
    @State private var historyWindow: SwapHistoryService.Window = .day
    @State private var swapHistory: [SwapHistoryItem] = []
    @State private var loadingHistory = false

    var body: some View {
        NavigationStack {
            List {
                paySection
                flipRow
                receiveSection
                actionSection
                quotesSection
                activitySection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Trade")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TradeModeSwitcher() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.selection(); showSlippage = true } label: {
                        Label("Slippage \(NumberStyle.basisPoints(model.slippageBps))", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .keyboardDoneButton()
            .sheet(item: $picking) { side in
                TokenPickerSheet(selected: side == .pay ? model.tokenIn : model.tokenOut, balances: model.balances, universe: KnownTokenStore.universe(owner: session.address),
                                 unverified: KnownTokenStore.unverified(owner: session.address)) { token in
                    // Remember any token the user picks (a pasted ERC-20 included) so it shows a balance and price in
                    // holdings and the picker from now on, not only after a completed swap.
                    KnownTokenStore.add(token, owner: session.address)
                    model.select(token, for: side)
                }
            }
            .sheet(item: $reviewing) { review in confirmation(review) }
            .sheet(isPresented: $showSlippage) { SlippageSheet(slippageBps: $model.slippageBps) }
            .task(id: session.address) { await model.refreshBalances(env: env, address: session.address) }
            .task(id: model.quoteKey) { await model.quote(env: env, account: session.address, exactApprovals: session.isPasskeyAccount) }
            .onChange(of: router.pendingSwap?.tokenOut) { _, _ in applyPending() }
            .onAppear { applyPending() }
        }
    }

    /// All the wallet's swaps over the selected range (not just the paying asset) — recorded swaps merged with an
    /// on-chain Transfer scan that backfills older ones, newest first.
    @ViewBuilder private var activitySection: some View {
        if session.canSign {
            Section {
                Picker("Range", selection: $historyWindow) {
                    ForEach(SwapHistoryService.Window.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if loadingHistory, swapHistory.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading swaps…").font(.subheadline).foregroundStyle(.secondary) }
                } else if swapHistory.isEmpty {
                    Text("No swaps in this range yet.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(swapHistory) { SwapHistoryRow(item: $0) }
                }
            } header: {
                Text("Swap History")
            }
            .task(id: "\(historyWindow.rawValue)-\(session.address?.hex ?? "")") { await loadHistory() }
        }
    }

    private func loadHistory() async {
        guard let address = session.address else { swapHistory = []; return }
        loadingHistory = true
        defer { loadingHistory = false }
        let tokens = Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let scanned = await env.swapHistory.swaps(wallet: address, window: historyWindow, decimals: tokens.mapValues(\.decimals))
        let cutoff = Date().addingTimeInterval(-historyWindow.seconds)
        var items: [SwapHistoryItem] = []
        var seen = Set<String>()
        // Recorded swaps first: exact legs, and they include native-MON legs the Transfer scan can't see.
        for record in ActivityLog.all(owner: address) where record.kind == .swap && record.time >= cutoff {
            guard let hashHex = record.txHashHex, seen.insert(hashHex).inserted else { continue }
            items.append(SwapHistoryItem(id: hashHex, hash: record.txHash, time: record.time, text: record.subtitle))
        }
        // On-chain reconstruction backfills swaps made before recording (or on another device).
        for swap in scanned where seen.insert(swap.hash.hexString).inserted {
            items.append(SwapHistoryItem(id: swap.hash.hexString, hash: swap.hash, time: swap.time, text: SwapHistoryItem.describe(swap, tokens: tokens)))
        }
        swapHistory = items.sorted { $0.time > $1.time }
    }

    private var paySection: some View {
        Section {
            tokenRow(side: .pay, token: model.tokenIn)
            AmountField(title: "0", text: $model.amountText, token: nil) {
                Haptics.selection(); useMax()
            }
            percentRow
        } header: {
            Text("You Pay")
        } footer: {
            HStack {
                if let balance = model.balances[model.tokenIn.address] {
                    Text("Balance: \(NumberStyle.units(balance, decimals: model.tokenIn.decimals)) \(model.tokenIn.symbol)")
                }
                Spacer()
                if let usd = model.payUSD { Text(usd, format: .currency(code: "USD")) }
            }
            // With the header below trimmed to match (`receiveSection`), the flip button sits 10 pt from the balance
            // line and 10 pt from "You Receive".
            .padding(.bottom, -8)
        }
        .listSectionSpacing(0)
    }

    /// Quick-size the pay amount to a share of the wallet balance — 25 / 50 / 75 / 100%. On a full send of native
    /// MON the swap's network fee is kept back.
    private var percentRow: some View {
        HStack(spacing: 8) {
            ForEach([25, 50, 75, 100], id: \.self) { pct in
                Button("\(pct)%") {
                    Haptics.selection()
                    if pct == 100 { useMax() } else { model.applyPercent(Double(pct)) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled((model.balances[model.tokenIn.address] ?? 0) == 0)
        .listRowSeparator(.hidden)
    }

    private func useMax() {
        Task { await model.applyMax(env: env, account: session.address) }
    }

    /// The flip button between the two cards, as tight as the list allows and the same gap above and below: no section
    /// spacing on either side of it, and a row exactly the button's height.
    private var flipRow: some View {
        Section {
            HStack {
                Spacer()
                Button { Haptics.selection(); model.flip() } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                }
                .accessibilityLabel("Swap direction")
                Spacer()
            }
            .frame(height: 40)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
    }

    /// The swap's action, in the page right under what it trades. Pinned to the bottom it sat on a bar over the quotes
    /// and the history.
    private var actionSection: some View {
        Section {
            PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.selectedQuote == nil) { reviewing = model.review }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var receiveSection: some View {
        Section {
            tokenRow(side: .receive, token: model.tokenOut)
            HStack {
                if let quote = model.selectedQuote {
                    AmountText(amount: quote.amountOut, token: model.tokenOut, font: .title2.weight(.medium))
                } else if model.awaitingQuote {
                    ProgressView().controlSize(.small)
                    Text("Finding the best price").foregroundStyle(.secondary)
                } else {
                    Text("0").font(.title2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } header: {
            Text("You Receive")
                .padding(.top, -10) // the same 10 pt from the flip button as the balance line above it (`paySection`)
        } footer: {
            HStack {
                if let balance = model.balances[model.tokenOut.address] {
                    Text("Balance: \(NumberStyle.units(balance, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol)")
                }
                Spacer()
                if let usd = model.receiveUSD { Text(usd, format: .currency(code: "USD")) }
            }
        }
    }

    @ViewBuilder private var quotesSection: some View {
        if let result = model.currentResult, model.amountIn > 0 {
            Section {
                ForEach(result.quotes) { quote in
                    Button { Haptics.selection(); model.selectedVenue = quote.venue; model.userPickedVenue = true } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(quote.venue.displayName).font(.headline)
                                    if quote.venue == result.quotes.first?.venue {
                                        Text("Best").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.positive.opacity(0.15), in: Capsule()).foregroundStyle(Color.positive)
                                    }
                                }
                                Text(quote.route).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                AmountText(amount: quote.amountOut, token: model.tokenOut, font: .body.weight(.medium))
                                if let impact = quote.priceImpactBps {
                                    Text("Impact \(NumberStyle.basisPoints(abs(impact)))").font(.footnote).foregroundStyle(abs(impact) > 100 ? Color.attention : .secondary)
                                }
                            }
                            Image(systemName: model.selectedVenue == quote.venue ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedVenue == quote.venue ? Color.accentColor : Color(.tertiaryLabel))
                        }
                    }
                    .foregroundStyle(.primary)
                }
                ForEach(result.errors.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { venue in
                    HStack {
                        Text(venue.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text(result.errors[venue] ?? "").font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                HStack {
                    Text("Quotes")
                    Spacer()
                    if model.quoting { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if let quote = model.selectedQuote {
                    Text("Minimum received \(NumberStyle.units(quote.minOut, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol) at \(NumberStyle.basisPoints(model.slippageBps)) slippage. Quotes refresh every 15 seconds.")
                }
            }
        } else if let error = model.currentError {
            Section { InlineError(message: error) }.listRowBackground(Color.clear)
        }
    }

    private func tokenRow(side: SwapModel.Side, token: Token) -> some View {
        Button { Haptics.selection(); picking = side } label: {
            HStack(spacing: 12) {
                TokenLogo(symbol: token.symbol, url: token.logoURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(token.symbol).font(.headline)
                        if KnownTokenStore.isUnverified(token.address, owner: session.address) { UnverifiedBadge() }
                    }
                    Text(token.name).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("\(side == .pay ? "Pay with" : "Receive") \(token.symbol)")
        .accessibilityHint("Choose a different token")
    }

    private func confirmation(_ review: SwapReview) -> some View {
        SwapConfirmation(review: review, onDone: {
            model.amountText = ""
            // Remember both sides so they show in holdings and the picker even if they aren't curated: the token
            // just acquired, and the one paid with (a partial swap leaves a balance still worth showing).
            KnownTokenStore.add(review.tokenOut, owner: session.address)
            KnownTokenStore.add(review.tokenIn, owner: session.address)
            // Bought here on purpose: no longer an unverified token that merely arrived in the wallet (IOST-12).
            KnownTokenStore.markChosen(review.tokenOut.address, owner: session.address)
            if settings.notificationsEnabled, settings.notifyFills {
                Notifications.swapped(review.amountIn, review.tokenIn, review.quote.amountOut, review.tokenOut)
            }
            Task { await model.refreshBalances(env: env, address: session.address) }
        }, onCompleted: { hash in
            // Record the swap so it shows in Swap History and Recent Activity with its exact legs (including a
            // native MON leg, which an on-chain Transfer scan can't recover): the ones reviewed and signed.
            let text = "\(NumberStyle.units(review.amountIn, decimals: review.tokenIn.decimals, compact: true)) \(review.tokenIn.symbol) → \(NumberStyle.units(review.quote.amountOut, decimals: review.tokenOut.decimals, compact: true)) \(review.tokenOut.symbol)"
            let usd = [review.payUSD, review.receiveUSD].compactMap { $0 }.first { $0 > 0 }
            ActivityLog.record(ActivityRecord(kind: .swap, title: "Swapped", subtitle: text, hash: hash, usd: usd), owner: session.address)
        })
    }

    private func applyPending() {
        guard let pending = router.pendingSwap else { return }
        router.pendingSwap = nil
        // A retired cohort's Moment coin never becomes a side (Router.openSwap refuses it first).
        guard SwapEngine.isTradablePair(pending.tokenIn, pending.tokenOut) else { return }
        if let tokenIn = pending.tokenIn { model.tokenIn = tokenIn }
        if let tokenOut = pending.tokenOut { model.tokenOut = tokenOut }
    }
}

/// What the review sheet shows and signs, frozen when Review is tapped: the quote with the request it answers (the
/// pair, amount and slippage it was quoted for, and their dollar values then). Quotes refresh every 15 s and a Max can
/// land late, but the sheet builds its plan once, so everything it shows, declares to a passkey session and records
/// comes from here — never from the live form.
struct SwapReview: Identifiable {
    let id = UUID()
    let quote: VenueQuote
    let tokenIn: Token
    let tokenOut: Token
    let amountIn: BigUInt
    let slippageBps: Int
    let payUSD: Double?
    let receiveUSD: Double?
}

/// Builds the plan for the reviewed quote, then hands it to the shared confirmation sheet.
private struct SwapConfirmation: View {
    let review: SwapReview
    let onDone: () -> Void
    var onCompleted: ((Data) -> Void)? = nil
    @Environment(Session.self) private var session

    var body: some View {
        let quote = review.quote
        ConfirmationSheet(title: "Review Swap", confirmTitle: "Swap", build: {
            guard let address = session.address else { throw SessionError.readOnly }
            return try await quote.build(address)
        }, onDone: onDone, onCompleted: onCompleted, intent: intent) {
            DetailRow("You pay", "\(NumberStyle.units(review.amountIn, decimals: review.tokenIn.decimals)) \(review.tokenIn.symbol)")
            DetailRow("You receive", "\(NumberStyle.units(quote.amountOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")
            DetailRow("Minimum received", "\(NumberStyle.units(quote.minOut, decimals: review.tokenOut.decimals)) \(review.tokenOut.symbol)")
            DetailRow("Venue", quote.venue.displayName)
            DetailRow("Route", quote.route)
            DetailRow("Slippage", NumberStyle.basisPoints(review.slippageBps))
        }
    }

    /// A swap (or wrap) of exactly what's shown, for the quoted output, valued at the input's price.
    private var intent: Mera.Intent {
        .swap(venue: review.quote.venue, pay: .init(token: review.tokenIn.address, amount: review.amountIn),
              receive: .init(token: review.tokenOut.address, amount: review.quote.amountOut), usd: review.payUSD)
    }
}

@Observable
@MainActor
final class SwapModel {
    enum Side: Identifiable { case pay, receive; var id: Self { self } }

    var tokenIn: Token = .mon
    var tokenOut: Token = .usdc
    var amountText = ""
    var slippageBps = 50
    var selectedVenue: Venue?
    /// True once the person taps a venue row; until then the selection follows the best quote on every refresh.
    var userPickedVenue = false
    private(set) var balances: [Address: BigUInt] = [:]
    private(set) var prices: [Address: PriceInfo] = [:]
    private(set) var result: QuoteResult?
    /// The `quoteKey` that `result` and `error` answer. The amount, pair or slippage can change while a re-quote is on
    /// its way (400 ms debounce, then every venue): until it lands, the old answer is kept out of sight and can't be
    /// reviewed (`currentResult`, `selectedQuote`).
    private(set) var resultKey: String?
    private(set) var quoting = false
    private(set) var error: String?

    var amountIn: BigUInt { Amount.parse(amountText, decimals: tokenIn.decimals) ?? 0 }
    var quoteKey: String { "\(tokenIn.address.hex)-\(tokenOut.address.hex)-\(amountIn)-\(slippageBps)" }
    /// A quote for what is on screen is on its way: the fetch, or the debounce before it after an edit (the old answer
    /// is already out of sight).
    var awaitingQuote: Bool { amountIn > 0 && tokenIn != tokenOut && (quoting || resultKey != quoteKey) }
    /// `result`, when it answers what is on screen now.
    var currentResult: QuoteResult? { resultKey == quoteKey ? result : nil }
    /// `error`, when it answers what is on screen now.
    var currentError: String? { resultKey == quoteKey ? error : nil }
    var selectedQuote: VenueQuote? {
        guard let result = currentResult, amountIn > 0 else { return nil }
        return result.quotes.first { $0.venue == selectedVenue } ?? result.quotes.first
    }
    /// What the review sheet shows and signs, frozen when Review is tapped (nil without a current quote).
    var review: SwapReview? {
        guard let quote = selectedQuote else { return nil }
        return SwapReview(quote: quote, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps,
                          payUSD: payUSD, receiveUSD: receiveUSD)
    }
    var payUSD: Double? { prices[tokenIn.address].map { Amount.units(amountIn, decimals: tokenIn.decimals) * $0.usd } }
    var receiveUSD: Double? {
        guard let quote = selectedQuote, let price = prices[tokenOut.address] else { return nil }
        return Amount.units(quote.amountOut, decimals: tokenOut.decimals) * price.usd
    }
    var actionTitle: String {
        if amountIn == 0 { return "Enter an Amount" }
        if let balance = balances[tokenIn.address], amountIn > balance { return "Insufficient \(tokenIn.symbol)" }
        if SwapEngine.isWrap(tokenIn, tokenOut) { return tokenIn.isNative ? "Wrap MON" : "Unwrap WMON" }
        return "Review Swap"
    }

    func select(_ token: Token, for side: Side) {
        // Trading a retired cohort's Moment coin is closed: the picker never offers one, and it is refused here too.
        guard SwapEngine.isTradable(token) else { return }
        let before = (tokenIn, tokenOut)
        switch side {
        case .pay:
            if token == tokenOut { tokenOut = tokenIn }
            tokenIn = token
        case .receive:
            if token == tokenIn { tokenIn = tokenOut }
            tokenOut = token
        }
        // Re-picking the same token changes nothing: its quotes stay (the running refresh keeps its key).
        guard (tokenIn, tokenOut) != before else { return }
        result = nil
        userPickedVenue = false
    }

    func flip() {
        // The quote's output becomes the new input: read it before the swap makes it answer another pair.
        let carried = selectedQuote
        swap(&tokenIn, &tokenOut)
        if let carried { amountText = Amount.exact(Amount.roundedDown(carried.amountOut, decimals: tokenIn.decimals), decimals: tokenIn.decimals) }
        result = nil
        userPickedVenue = false
    }

    /// Set the pay amount to `pct`% of the wallet balance. A full send of native MON keeps Monad's fallback fee back;
    /// the Max buttons use `applyMax`, which reads the real one. A share (or MON after its fee) is rounded down to six
    /// significant digits (`Amount.roundedDown`); 100% of a token stays exact, so all of it can be swapped.
    func applyPercent(_ pct: Double) {
        guard let balance = balances[tokenIn.address], balance > 0 else { return }
        var amount = balance
        if pct < 100 {
            amount = Amount.roundedDown(balance * BigUInt(UInt(pct)) / 100, decimals: tokenIn.decimals)
        } else if tokenIn.isNative {
            amount = Amount.roundedDown(NetworkFeeReserve.spendable(balance: balance, reserve: NetworkFeeReserve.monadFallback), decimals: tokenIn.decimals)
        }
        amountText = Amount.exact(amount, decimals: tokenIn.decimals)
    }

    /// Max (MERA-PLAN §5). For native MON: the balance less what the swap can be charged up front — the gas limit of
    /// the route on screen (estimated for this account) or a routed swap's budget, × (2 × base fee + tip) with headroom,
    /// 0.06 MON when the fee can't be read. Zero when the fee takes it all. Any other token: the whole balance.
    func applyMax(env: AppEnvironment, account: Address?) async {
        guard tokenIn.isNative, let balance = balances[tokenIn.address], balance > 0 else { applyPercent(100); return }
        let token = tokenIn
        var route: TransactionRequest?
        if let account, let quote = selectedQuote, let steps = try? await quote.build(account) {
            route = steps.lazy.compactMap { try? $0.request(at: Date()) }.first { $0.value > 0 }
        }
        let amount = await env.sender.maxValue(balance: balance, like: route, from: account, budget: NetworkFeeReserve.swapGasLimit)
        // The pair or the balance changed while the fee was read: that Max no longer applies.
        guard tokenIn == token, balances[token.address] == balance else { return }
        // Rounded down: a sliver more stays back with the fee reserve, and the field reads "2.16254", not 18 decimals.
        amountText = Amount.exact(Amount.roundedDown(amount, decimals: token.decimals), decimals: token.decimals)
    }

    func refreshBalances(env: AppEnvironment, address: Address?) async {
        let universe = KnownTokenStore.universe(owner: address)
        async let priceTask = env.prices.prices(for: universe)
        if let address { balances = (try? await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:] }
        prices = (try? await priceTask) ?? prices
    }

    /// Debounced by the caller's `.task(id:)`: the task is cancelled and restarted on every keystroke.
    /// `exactApprovals`: a passkey account's plans approve exactly the input (`SwapRequest.exactApprovals`).
    func quote(env: AppEnvironment, account: Address?, exactApprovals: Bool = false) async {
        guard amountIn > 0, tokenIn != tokenOut else {
            result = nil
            resultKey = nil
            error = nil
            // A fetch cancelled mid-flight (the amount cleared, or Done after a swap) returns without resetting it.
            quoting = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        while !Task.isCancelled {
            quoting = true
            let key = quoteKey
            let request = SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps, account: account ?? Address(literal: "0x000000000000000000000000000000000000dEaD"),
                                      exactApprovals: exactApprovals)
            let outcome = await env.swap.quotes(for: request)
            if Task.isCancelled { return }
            result = outcome
            resultKey = key
            error = outcome.quotes.isEmpty ? (outcome.errors.values.first ?? "No venue can route this pair right now.") : nil
            if !userPickedVenue || selectedVenue == nil || !outcome.quotes.contains(where: { $0.venue == selectedVenue }) { selectedVenue = outcome.quotes.first?.venue }
            quoting = false
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

/// Explains slippage in plain language, then lets the person pick a tolerance — presets with a one-line hint each,
/// or a custom percentage. The old control was a bare menu of numbers with no explanation.
struct SlippageSheet: View {
    @Binding var slippageBps: Int
    @Environment(\.dismiss) private var dismiss
    @State private var customText = ""
    private let presets = [10, 50, 100, 300]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("How far the price may move before your swap settles. Beyond this, it cancels instead of filling worse.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Tolerance") {
                    ForEach(presets, id: \.self) { bps in
                        Button {
                            Haptics.selection(); slippageBps = bps; customText = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(NumberStyle.basisPoints(bps)).foregroundStyle(.primary)
                                    Text(hint(bps)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if slippageBps == bps { Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold) }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Custom")
                        Spacer()
                        TextField("0.5", text: $customText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 80)
                            .onChange(of: customText) { _, value in
                                if let pct = Double(value), pct > 0, pct <= 50 { slippageBps = Int((pct * 100).rounded()) }
                            }
                        Text("%").foregroundStyle(.secondary)
                    }
                } footer: {
                    if slippageBps >= 500 {
                        Label("A high tolerance can fill at a much worse price. Use it only for volatile or thin pairs.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color.attention)
                    } else if slippageBps <= 10 {
                        Text("A tight tolerance protects your price, but a swap can fail in a fast-moving market.").font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Slippage")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hint(_ bps: Int) -> String {
        switch bps {
        case ...10: "Tightest price. Best for stable pairs."
        case 11...50: "Balanced — recommended for most swaps."
        case 51...100: "More forgiving when the market is moving."
        default: "For volatile or low-liquidity pairs."
        }
    }
}

/// One row in the swap-history list: a "sold → bought" line and when, linking to the transaction.
struct SwapHistoryItem: Identifiable, Hashable {
    let id: String
    let hash: Data?
    let time: Date
    let text: String

    /// A "sold → bought" line from a reconstructed swap, resolving symbols/decimals from the wallet's token set. When
    /// the token isn't known (so its decimals are unknown), the amount is omitted rather than shown with a guessed
    /// 18-decimal scale that could be wildly off — only the short address is shown.
    static func describe(_ swap: SwapRecord, tokens: [Address: Token]) -> String {
        func leg(_ address: Address, _ raw: BigUInt) -> String {
            guard let token = tokens[address] else { return address.short }
            return "\(NumberStyle.units(raw, decimals: token.decimals, compact: true)) \(token.symbol)"
        }
        return "\(leg(swap.soldToken, swap.soldAmount)) → \(leg(swap.boughtToken, swap.boughtAmount))"
    }
}

private struct SwapHistoryRow: View {
    let item: SwapHistoryItem

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
            Image(systemName: "arrow.left.arrow.right")
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if item.hash != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// Searchable token list. Any Monad token can be added by pasting its address.
struct TokenPickerSheet: View {
    let selected: Token
    let balances: [Address: BigUInt]
    var universe: [Token] = Token.core
    /// Choosing a swap side (the default): a retired cohort's Moment coin is never offered. Home's search passes false —
    /// it only opens a token's page, which shows such a coin as "Past cohort · trading closed" with no swap.
    var tradableOnly = true
    /// Tokens found in the wallet rather than chosen (`KnownTokenStore.unverified`): left out of the list, and shown —
    /// marked — only when a search matches them (security audit 2026-09-26, IOST-12).
    var unverified: Set<Address> = []
    let onPick: (Token) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var custom: Token?
    @State private var lookingUp = false
    @State private var remoteResults: [Token] = []

    private var tokens: [Token] {
        // A retired cohort's Moment coin is never offered as a swap side: trading it is closed in the app.
        let base = (tradableOnly ? universe.filter(SwapEngine.isTradable) : universe).filter { !unverified.contains($0.address) }
        let filtered = query.isEmpty ? base : base.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        // Assets the wallet holds float to the top, keeping the curated order within each group.
        return filtered.enumerated().sorted { a, b in
            let heldA = (balances[a.element.address] ?? 0) > 0
            let heldB = (balances[b.element.address] ?? 0) > 0
            return heldA != heldB ? heldA : a.offset < b.offset
        }.map(\.element)
    }

    /// Unverified tokens in the wallet that match the search, in their own marked section.
    private var unverifiedMatches: [Token] {
        guard !query.isEmpty else { return [] }
        return universe.filter { token in
            unverified.contains(token.address) && token.address != custom?.address && (!tradableOnly || SwapEngine.isTradable(token))
                && (token.symbol.localizedCaseInsensitiveContains(query) || token.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// Search hits for tokens not in the popular default list: the Uniswap/Monday venue list (accurate symbols +
    /// logos, matched locally) plus Kuru's directory. Only while searching — the default list stays popular-only.
    private var remoteMatches: [Token] {
        guard !query.isEmpty else { return [] }
        var seen = Set(tokens.map(\.address)).union(unverifiedMatches.map(\.address))
        if let custom { seen.insert(custom.address) }
        let venueHits = VenueTokenStore.all().filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        var out: [Token] = []
        for token in venueHits + remoteResults where (!tradableOnly || SwapEngine.isTradable(token)) && seen.insert(token.address).inserted { out.append(token) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if let custom {
                    Section("By address") {
                        if tradableOnly, !SwapEngine.isTradable(custom) { closedRow(custom) } else { row(custom) }
                    }
                }
                Section {
                    ForEach(tokens) { row($0) }
                } footer: {
                    if tokens.isEmpty, custom == nil, remoteMatches.isEmpty, unverifiedMatches.isEmpty {
                        Text(lookingUp ? "Looking up this token…" : "No token matches. Paste a contract address to add any Monad token.")
                    }
                }
                if !unverifiedMatches.isEmpty {
                    Section {
                        ForEach(unverifiedMatches) { row($0) }
                    } header: {
                        Text("Unverified — in your wallet")
                    } footer: {
                        Text("These arrived in your wallet without you choosing them here. Anyone can send any token, with any name — including a real token's. Check the contract before you trade.")
                    }
                }
                if !remoteMatches.isEmpty {
                    Section("More Monad tokens") { ForEach(remoteMatches) { row($0) } }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Symbol, name or address")
            .navigationTitle("Choose a Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                custom = nil
                guard let address = Address(query), Token.core(address) == nil else { return }
                lookingUp = true
                custom = try? await ERC20.metadata(address, multicall: env.multicall)
                lookingUp = false
            }
            .task(id: query) {
                // Search the broad Kuru token directory, debounced. Empty/short queries clear it.
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { remoteResults = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                remoteResults = await env.kuruTokens.search(q)
            }
        }
    }

    /// A pasted past-cohort Moment coin: named so the address is not a dead end, never pickable.
    private func closedRow(_ token: Token) -> some View {
        HStack(spacing: 12) {
            TokenLogo(symbol: token.symbol, url: token.logoURL, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.symbol).font(.headline)
                Text("Past cohort · trading closed").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func row(_ token: Token) -> some View {
        Button {
            Haptics.selection()
            onPick(token)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                TokenLogo(symbol: token.symbol, url: token.logoURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(token.symbol).font(.headline)
                        if unverified.contains(token.address) { UnverifiedBadge() }
                    }
                    // Only Home's search lists a retired coin; its page has no swap either.
                    Text(SwapEngine.isTradable(token) ? token.name : "Past cohort · trading closed").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if let balance = balances[token.address], balance > 0 {
                    Text(NumberStyle.units(balance, decimals: token.decimals, compact: true)).monospacedDigit().foregroundStyle(.secondary)
                }
                if token == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .foregroundStyle(.primary)
    }
}
