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
            .navigationTitle("Swap")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.selection(); showSlippage = true } label: {
                        Label("Slippage \(NumberStyle.basisPoints(model.slippageBps))", systemImage: "slider.horizontal.3")
                            .labelStyle(.titleAndIcon)
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

    /// Your recent on-chain movements of the asset you're paying with — read from its Transfer events, per wallet.
    @ViewBuilder private var activitySection: some View {
        if session.canSign {
            Section {
                RecentActivityList(token: model.tokenIn, owner: session.address)
            } header: {
                Text("\(model.tokenIn.symbol) Activity")
            }
        }
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
            SwapConfirmation(model: model, quote: quote) {
                model.amountText = ""
                // Remember both sides so they show in holdings and the picker even if they aren't curated: the token
                // just acquired, and the one paid with (a partial swap leaves a balance still worth showing).
                KnownTokenStore.add(model.tokenOut, owner: session.address)
                KnownTokenStore.add(model.tokenIn, owner: session.address)
                if settings.notificationsEnabled, settings.notifyFills {
                    Notifications.swapped(model.amountIn, model.tokenIn, quote.amountOut, model.tokenOut)
                }
                Task { await model.refreshBalances(env: env, address: session.address) }
            }
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
    @Environment(Session.self) private var session

    var body: some View {
        ConfirmationSheet(title: "Review Swap", confirmTitle: "Swap", build: {
            guard let address = session.address else { throw SessionError.readOnly }
            return try await quote.build(address)
        }, onDone: onDone) {
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
                    Text("Slippage is how far the price may move between the moment you tap Swap and the moment it settles on-chain. If the market moves against you by more than this, the swap is cancelled instead of filling at a worse price.")
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

/// The wallet's recent transfers of one token, newest first, each linking to the explorer. Loaded on demand when the
/// selected asset changes.
struct RecentActivityList: View {
    let token: Token
    let owner: Address?
    @Environment(AppEnvironment.self) private var env
    @State private var items: [TokenActivity] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading, items.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading activity…").font(.subheadline).foregroundStyle(.secondary) }
            } else if items.isEmpty {
                Text("No recent \(token.symbol) activity for this wallet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items) { ActivityRow(item: $0, token: token) }
            }
        }
        .task(id: "\(token.address.hex)-\(owner?.hex ?? "")") {
            guard let owner else { items = []; loading = false; return }
            loading = true
            items = await env.activity.recent(token: token.address, wallet: owner)
            loading = false
        }
    }
}

private struct ActivityRow: View {
    let item: TokenActivity
    let token: Token

    private var incoming: Bool { item.direction == .incoming }

    var body: some View {
        Link(destination: Monad.explorerTransaction(item.hash)) {
            HStack(spacing: 12) {
                Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background((incoming ? Color.positive : Color.negative).opacity(0.14), in: Circle())
                    .foregroundStyle(incoming ? Color.positive : Color.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text(incoming ? "Received" : "Sent").font(.subheadline.weight(.medium))
                    Text("\(incoming ? "from" : "to") \(item.counterparty.short)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(incoming ? "+" : "−")\(NumberStyle.units(item.amount, decimals: token.decimals, compact: true)) \(token.symbol)")
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                        .foregroundStyle(incoming ? Color.positive : Color.primary)
                    Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(.primary)
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

    private var tokens: [Token] {
        let base = universe
        guard !query.isEmpty else { return base }
        return base.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
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
                    if tokens.isEmpty, custom == nil {
                        Text(lookingUp ? "Looking up this address" : "No token matches. Paste a contract address to add any Monad token.")
                    }
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
