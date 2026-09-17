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
    @State private var showConfirm = false
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
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.selectedQuote == nil) { showConfirm = true }
                    .padding()
                    .background(.bar)
            }
            .sheet(item: $picking) { side in
                TokenPickerSheet(selected: side == .pay ? model.tokenIn : model.tokenOut, balances: model.balances, universe: KnownTokenStore.universe(owner: session.address)) { token in
                    // Remember any token the user picks (a pasted ERC-20 included) so it shows a balance and price in
                    // holdings and the picker from now on, not only after a completed swap.
                    KnownTokenStore.add(token, owner: session.address)
                    model.select(token, for: side)
                }
            }
            .sheet(isPresented: $showConfirm) { confirmation }
            .sheet(isPresented: $showSlippage) { SlippageSheet(slippageBps: $model.slippageBps) }
            .task(id: session.address) { await model.refreshBalances(env: env, address: session.address) }
            .task(id: model.quoteKey) { await model.quote(env: env, account: session.address) }
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
                Haptics.selection(); model.applyPercent(100)
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
        }
    }

    /// Quick-size the pay amount to a share of the wallet balance — 25 / 50 / 75 / 100%. On a full send of native
    /// MON a little is kept back for gas.
    private var percentRow: some View {
        HStack(spacing: 8) {
            ForEach([25, 50, 75, 100], id: \.self) { pct in
                Button("\(pct)%") { Haptics.selection(); model.applyPercent(Double(pct)) }
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
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var receiveSection: some View {
        Section {
            tokenRow(side: .receive, token: model.tokenOut)
            HStack {
                if let quote = model.selectedQuote {
                    AmountText(amount: quote.amountOut, token: model.tokenOut, font: .title2.weight(.medium))
                } else if model.quoting {
                    ProgressView().controlSize(.small)
                    Text("Finding the best price").foregroundStyle(.secondary)
                } else {
                    Text("0").font(.title2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } header: {
            Text("You Receive")
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
        if let result = model.result, model.amountIn > 0 {
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
        } else if let error = model.error {
            Section { InlineError(message: error) }.listRowBackground(Color.clear)
        }
    }

    private func tokenRow(side: SwapModel.Side, token: Token) -> some View {
        Button { Haptics.selection(); picking = side } label: {
            HStack(spacing: 12) {
                TokenLogo(symbol: token.symbol, url: token.logoURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(token.symbol).font(.headline)
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

    @ViewBuilder private var confirmation: some View {
        if let quote = model.selectedQuote {
            SwapConfirmation(model: model, quote: quote, onDone: {
                let paidIn = model.amountIn // capture before clearing, so the notification reports the real amount
                model.amountText = ""
                // Remember both sides so they show in holdings and the picker even if they aren't curated: the token
                // just acquired, and the one paid with (a partial swap leaves a balance still worth showing).
                KnownTokenStore.add(model.tokenOut, owner: session.address)
                KnownTokenStore.add(model.tokenIn, owner: session.address)
                if settings.notificationsEnabled, settings.notifyFills {
                    Notifications.swapped(paidIn, model.tokenIn, quote.amountOut, model.tokenOut)
                }
                Task { await model.refreshBalances(env: env, address: session.address) }
            }, onCompleted: { hash in
                // Record the swap so it shows in Swap History and Recent Activity with its exact legs (including a
                // native MON leg, which an on-chain Transfer scan can't recover).
                let text = "\(NumberStyle.units(model.amountIn, decimals: model.tokenIn.decimals, compact: true)) \(model.tokenIn.symbol) → \(NumberStyle.units(quote.amountOut, decimals: model.tokenOut.decimals, compact: true)) \(model.tokenOut.symbol)"
                let paidUSD = Amount.units(model.amountIn, decimals: model.tokenIn.decimals) * (model.prices[model.tokenIn.address]?.usd ?? 0)
                let receivedUSD = Amount.units(quote.amountOut, decimals: model.tokenOut.decimals) * (model.prices[model.tokenOut.address]?.usd ?? 0)
                ActivityLog.record(ActivityRecord(kind: .swap, title: "Swapped", subtitle: text, hash: hash, usd: paidUSD > 0 ? paidUSD : (receivedUSD > 0 ? receivedUSD : nil)), owner: session.address)
            })
        }
    }

    private func applyPending() {
        guard let pending = router.pendingSwap else { return }
        if let tokenIn = pending.tokenIn { model.tokenIn = tokenIn }
        if let tokenOut = pending.tokenOut { model.tokenOut = tokenOut }
        router.pendingSwap = nil
    }
}

/// Builds the plan for the chosen quote, then hands it to the shared confirmation sheet.
private struct SwapConfirmation: View {
    let model: SwapModel
    let quote: VenueQuote
    let onDone: () -> Void
    var onCompleted: ((Data) -> Void)? = nil
    @Environment(Session.self) private var session

    var body: some View {
        ConfirmationSheet(title: "Review Swap", confirmTitle: "Swap", build: {
            guard let address = session.address else { throw SessionError.readOnly }
            return try await quote.build(address)
        }, onDone: onDone, onCompleted: onCompleted) {
            DetailRow("You pay", "\(NumberStyle.units(model.amountIn, decimals: model.tokenIn.decimals)) \(model.tokenIn.symbol)")
            DetailRow("You receive", "\(NumberStyle.units(quote.amountOut, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol)")
            DetailRow("Minimum received", "\(NumberStyle.units(quote.minOut, decimals: model.tokenOut.decimals)) \(model.tokenOut.symbol)")
            DetailRow("Venue", quote.venue.displayName)
            DetailRow("Route", quote.route)
            DetailRow("Slippage", NumberStyle.basisPoints(model.slippageBps))
        }
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
    private(set) var quoting = false
    private(set) var error: String?

    var amountIn: BigUInt { Amount.parse(amountText, decimals: tokenIn.decimals) ?? 0 }
    var quoteKey: String { "\(tokenIn.address.hex)-\(tokenOut.address.hex)-\(amountIn)-\(slippageBps)" }
    var selectedQuote: VenueQuote? {
        guard let result, amountIn > 0 else { return nil }
        return result.quotes.first { $0.venue == selectedVenue } ?? result.quotes.first
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
        switch side {
        case .pay:
            if token == tokenOut { tokenOut = tokenIn }
            tokenIn = token
        case .receive:
            if token == tokenIn { tokenIn = tokenOut }
            tokenOut = token
        }
        result = nil
        userPickedVenue = false
    }

    func flip() {
        swap(&tokenIn, &tokenOut)
        if let quote = selectedQuote { amountText = Amount.exact(quote.amountOut, decimals: tokenIn.decimals) }
        result = nil
        userPickedVenue = false
    }

    /// Set the pay amount to `pct`% of the wallet balance. A full send of native MON keeps ~0.02 MON back for gas.
    func applyPercent(_ pct: Double) {
        guard let balance = balances[tokenIn.address], balance > 0 else { return }
        var amount = balance
        if pct < 100 {
            amount = balance * BigUInt(UInt(pct)) / 100
        } else if tokenIn.isNative {
            let gasBuffer = BigUInt(2) * BigUInt(10).power(16) // ~0.02 MON
            amount = balance > gasBuffer ? balance - gasBuffer : balance
        }
        amountText = Amount.exact(amount, decimals: tokenIn.decimals)
    }

    func refreshBalances(env: AppEnvironment, address: Address?) async {
        let universe = KnownTokenStore.universe(owner: address)
        async let priceTask = env.prices.prices(for: universe)
        if let address { balances = (try? await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:] }
        prices = (try? await priceTask) ?? prices
    }

    /// Debounced by the caller's `.task(id:)`: the task is cancelled and restarted on every keystroke.
    func quote(env: AppEnvironment, account: Address?) async {
        guard amountIn > 0, tokenIn != tokenOut else {
            result = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        while !Task.isCancelled {
            quoting = true
            let request = SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, slippageBps: slippageBps, account: account ?? Address(literal: "0x000000000000000000000000000000000000dEaD"))
            let outcome = await env.swap.quotes(for: request)
            if Task.isCancelled { return }
            result = outcome
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
    let onPick: (Token) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var custom: Token?
    @State private var lookingUp = false
    @State private var remoteResults: [Token] = []

    private var tokens: [Token] {
        let base = universe
        let filtered = query.isEmpty ? base : base.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        // Assets the wallet holds float to the top, keeping the curated order within each group.
        return filtered.enumerated().sorted { a, b in
            let heldA = (balances[a.element.address] ?? 0) > 0
            let heldB = (balances[b.element.address] ?? 0) > 0
            return heldA != heldB ? heldA : a.offset < b.offset
        }.map(\.element)
    }

    /// Search hits for tokens not in the popular default list: the Uniswap/Monday venue list (accurate symbols +
    /// logos, matched locally) plus Kuru's directory. Only while searching — the default list stays popular-only.
    private var remoteMatches: [Token] {
        guard !query.isEmpty else { return [] }
        var seen = Set(tokens.map(\.address))
        if let custom { seen.insert(custom.address) }
        let venueHits = VenueTokenStore.all().filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        var out: [Token] = []
        for token in venueHits + remoteResults where seen.insert(token.address).inserted { out.append(token) }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if let custom {
                    Section("By address") { row(custom) }
                }
                Section {
                    ForEach(tokens) { row($0) }
                } footer: {
                    if tokens.isEmpty, custom == nil, remoteMatches.isEmpty {
                        Text(lookingUp ? "Looking up this token…" : "No token matches. Paste a contract address to add any Monad token.")
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

    private func row(_ token: Token) -> some View {
        Button {
            Haptics.selection()
            onPick(token)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                TokenLogo(symbol: token.symbol, url: token.logoURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(token.symbol).font(.headline)
                    Text(token.name).font(.footnote).foregroundStyle(.secondary)
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
