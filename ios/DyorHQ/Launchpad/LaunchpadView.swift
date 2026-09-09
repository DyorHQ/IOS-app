import BigInt
import Charts
import DyorKit
import SwiftUI

/// The launchpad: coins on their bonding curves, graduated pools, and the form to launch a new one.
struct LaunchpadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @State private var model = LaunchpadModel()
    @State private var showCreate = false
    @State private var filter: LaunchFilter = .all

    var body: some View {
        NavigationStack {
            Group {
                if !env.config.launchpad.isDeployed {
                    ContentUnavailableView {
                        Label("Launchpad Not Live Yet", systemImage: "flame")
                    } description: {
                        Text("Launches appear here once the DyorHQ launchpad contracts are deployed on Monad.")
                    }
                } else if model.launches.isEmpty, !model.loading {
                    ContentUnavailableView {
                        Label("No Launches Yet", systemImage: "flame")
                    } description: {
                        Text("Be the first to launch a coin paired with a tokenized stock.")
                    } actions: {
                        Button("New Launch") { showCreate = true }.buttonStyle(.borderedProminent).disabled(!session.canSign)
                    }
                } else {
                    List {
                        if let info = model.protocolInfo {
                            Section {
                                LabeledContent("Launches", value: String(info.launchCount))
                                LabeledContent("Launch fee") { AmountText(amount: info.launchFee, token: .mon) }
                            }
                        }
                        Section {
                            ForEach(filtered) { launch in
                                NavigationLink(value: launch) { LaunchRow(launch: launch) }
                            }
                        } header: {
                            Picker("Filter", selection: $filter) {
                                ForEach(LaunchFilter.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .textCase(nil)
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Launch")
            .navigationDestination(for: Launch.self) { launch in LaunchDetailView(launch: launch) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Launch", systemImage: "plus") { showCreate = true }
                        .disabled(!env.config.launchpad.isDeployed || !session.canSign)
                }
            }
            .refreshable { await model.load(env: env) }
            .task { await model.poll(env: env) }
            .overlay { if model.launches.isEmpty, model.loading, env.config.launchpad.isDeployed { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCreate) { CreateLaunchView(protocolInfo: model.protocolInfo) { Task { await model.load(env: env) } } }
        }
    }

    private var filtered: [Launch] {
        switch filter {
        case .all: return model.launches
        case .live: return model.launches.filter { $0.phase == .bonding }
        case .graduated: return model.launches.filter { $0.phase == .graduated }
        }
    }
}

enum LaunchFilter: String, CaseIterable, Identifiable {
    case all, live, graduated
    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "All"
        case .live: return "On Curve"
        case .graduated: return "Graduated"
        }
    }
}

struct LaunchRow: View {
    let launch: Launch

    var body: some View {
        HStack(spacing: 12) {
            TokenLogo(symbol: launch.symbol, url: URL(string: launch.logo), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(launch.name).font(.headline).lineLimit(1)
                    Text(launch.symbol).font(.subheadline).foregroundStyle(.secondary)
                }
                if launch.phase == .bonding {
                    Gauge(value: Double(launch.progressBps) / 10_000) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(Color.accentColor)
                        .accessibilityLabel("Graduation progress")
                        .accessibilityValue("\(launch.progressBps / 100) percent")
                } else {
                    Text(launch.phase.title).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("Market cap").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@Observable
@MainActor
final class LaunchpadModel {
    private(set) var launches: [Launch] = []
    private(set) var protocolInfo: ProtocolInfo?
    private(set) var loading = false
    private(set) var error: String?

    func poll(env: AppEnvironment) async {
        while !Task.isCancelled {
            await load(env: env)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func load(env: AppEnvironment) async {
        guard env.config.launchpad.isDeployed else { return }
        loading = true
        defer { loading = false }
        do {
            async let info = env.launchpad.protocolInfo(extraPairTokens: Token.launchpadPairAssets)
            launches = try await env.launchpad.launches(limit: 60)
            protocolInfo = try? await info
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

/// One coin: price and progress, the curve's trades as candles, and the buy/sell ticket.
struct LaunchDetailView: View {
    let launch: Launch
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var detail: LaunchDetail?
    @State private var account: LaunchAccountView?
    @State private var candles: [Candle] = []
    @State private var side: TradeSide = .buy
    @State private var amountText = ""
    @State private var buyQuote: BuyQuote?
    @State private var sellQuote: SellQuote?
    @State private var showConfirm = false
    @State private var showClaim = false

    private enum TradeSide { case buy, sell }
    private var token: Token { Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18, logoURL: URL(string: launch.logo), isLaunchpad: true) }
    private var pairToken: Token { Token(address: launch.pair.address, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals) }
    private var rawAmount: BigUInt { Amount.parse(amountText, decimals: side == .buy ? launch.pair.decimals : 18) ?? 0 }

    var body: some View {
        List {
            headerSection
            if !candles.isEmpty { chartSection }
            if launch.phase == .bonding { ticketSection } else { graduatedSection }
            if let account, account.tokenBalance > 0 || account.pendingRewards > 0 { holdingsSection(account) }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(launch.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: "\(side)-\(rawAmount)") { await quote() }
        .sheet(isPresented: $showConfirm) { confirmation }
        .sheet(isPresented: $showClaim) {
            ConfirmationSheet(title: "Claim Rewards", confirmTitle: "Claim", build: { await env.launchpad.claimRewardsPlan(launch: launch, view: account) }, onDone: { Task { await load() } }) {
                if let account { DetailRow("Pending rewards", "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    TokenLogo(symbol: launch.symbol, url: URL(string: launch.logo), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(launch.name).font(.title3.weight(.semibold))
                        Text(launch.phase.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(NumberStyle.number(LaunchpadService.priceNumber(launch))) \(launch.pair.symbol)")
                        .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)").monospacedDigit().fontWeight(.medium)
                        Text("Market cap").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if launch.phase == .bonding {
                    Gauge(value: Double(launch.progressBps) / 10_000) {
                        Text("Graduation")
                    } currentValueLabel: {
                        Text("\(launch.progressBps / 100)%")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Text("Graduates at \(NumberStyle.units(launch.graduationThreshold, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol) raised. Liquidity then moves to a locked Uniswap v4 pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chartSection: some View {
        Section("Price") {
            Chart(candles) { candle in
                RectangleMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(candle.time))), yStart: .value("Open", candle.open), yEnd: .value("Close", candle.close), width: 5)
                    .foregroundStyle(candle.close >= candle.open ? Color.positive : Color.negative)
                RuleMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(candle.time))), yStart: .value("Low", candle.low), yEnd: .value("High", candle.high))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(candle.close >= candle.open ? Color.positive : Color.negative)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 180)
            .accessibilityLabel("Price candles from curve trades")
        }
    }

    private var ticketSection: some View {
        Section {
            Picker("Side", selection: $side) {
                Text("Buy").tag(TradeSide.buy)
                Text("Sell").tag(TradeSide.sell)
            }
            .pickerStyle(.segmented)
            AmountField(title: "0", text: $amountText, token: side == .buy ? pairToken : token) {
                guard let account else { return }
                amountText = side == .buy ? Amount.exact(account.pairBalance, decimals: launch.pair.decimals) : Amount.exact(account.tokenBalance, decimals: 18)
            }
            if side == .buy, let q = buyQuote, rawAmount > 0 {
                DetailRow("You receive", "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                DetailRow("Curve fee", "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.snipe > 0 { DetailRow("Early-buy tax", "\(NumberStyle.units(q.snipe, decimals: launch.pair.decimals)) \(launch.pair.symbol)", tint: Color.attention) }
                if q.refund > 0 { DetailRow("Refunded (curve full)", "\(NumberStyle.units(q.refund, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            if side == .sell, let q = sellQuote, rawAmount > 0 {
                DetailRow("You receive", "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                DetailRow("Curve fee", "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.tax > 0 { DetailRow("Creator tax", "\(NumberStyle.units(q.tax, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            PrimaryButton(title: side == .buy ? "Buy \(launch.symbol)" : "Sell \(launch.symbol)", isDisabled: rawAmount == 0 || !session.canSign) { showConfirm = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Trade on the Curve")
        } footer: {
            if !session.canSign { Text("Sign in to trade.") }
            else if let account { Text("Balance: \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)) \(launch.symbol) · \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
        }
    }

    private var graduatedSection: some View {
        Section {
            Button("Swap \(launch.symbol) on Uniswap", systemImage: "arrow.left.arrow.right") {
                router.openSwap(tokenIn: pairToken.isNative ? Token.mon : pairToken, tokenOut: token)
            }
            if let detail, let key = detail.poolKey {
                LabeledContent("Pool fee", value: NumberStyle.basisPoints(key.fee / 100))
            }
        } header: {
            Text(launch.phase == .graduated ? "Graduated" : launch.phase.title)
        } footer: {
            Text(launch.phase == .graduated ? "The curve's liquidity is locked in a Uniswap v4 pool. Trades now route through the swap screen." : "This launch is between phases. Trading resumes when migration completes.")
        }
    }

    private func holdingsSection(_ account: LaunchAccountView) -> some View {
        Section("Your Holdings") {
            LabeledContent("Balance") { AmountText(amount: account.tokenBalance, token: token, compact: true) }
            if account.pendingRewards > 0 {
                LabeledContent("Pending rewards") { Text("\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
                Button("Claim Rewards", systemImage: "gift") { showClaim = true }.disabled(!session.canSign)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            if !launch.description.isEmpty { Text(launch.description).font(.subheadline) }
            AddressRow(title: "Token", address: launch.token)
            AddressRow(title: "Creator", address: launch.deployer)
            LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps))
            LabeledContent("Holder fee sharing", value: launch.holderFeeSharing ? "On" : "Off")
            ForEach(socialLinks, id: \.0) { label, url in
                Link(destination: url) { Label(label, systemImage: "link") }
            }
        }
    }

    private var socialLinks: [(String, URL)] {
        [("Website", launch.socials.website), ("X", launch.socials.twitter), ("Telegram", launch.socials.telegram), ("Discord", launch.socials.discord), ("Farcaster", launch.socials.farcaster)]
            .compactMap { label, value in URL(string: value).flatMap { $0.scheme != nil ? ($0.host() != nil ? (label, $0) : nil) : nil } }
    }

    @ViewBuilder private var confirmation: some View {
        if let address = session.address {
            if side == .buy, let q = buyQuote {
                ConfirmationSheet(title: "Buy \(launch.symbol)", confirmTitle: "Buy", build: { await env.launchpad.buyPlan(launch: launch, quoteIn: rawAmount, minTokensOut: q.tokensOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; Task { await load() } }) {
                    DetailRow("You pay", "\(NumberStyle.units(rawAmount, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("You receive", "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.tokensOut * 99 / 100, decimals: 18, compact: true)) \(launch.symbol) (1% slippage)")
                }
            } else if side == .sell, let q = sellQuote {
                ConfirmationSheet(title: "Sell \(launch.symbol)", confirmTitle: "Sell", build: { await env.launchpad.sellPlan(launch: launch, tokensIn: rawAmount, minQuoteOut: q.quoteOut * 99 / 100, recipient: address) }, onDone: { amountText = ""; Task { await load() } }) {
                    DetailRow("You sell", "\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("You receive", "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(q.quoteOut * 99 / 100, decimals: launch.pair.decimals)) \(launch.pair.symbol) (1% slippage)")
                }
            }
        }
    }

    private func load() async {
        async let d = env.launchpad.launch(token: launch.token)
        async let t = env.launchpad.trades(curve: launch.curve, pair: launch.pair)
        if let address = session.address { account = try? await env.launchpad.accountView(launch, account: address) }
        detail = try? await d
        if let trades = try? await t { candles = LaunchpadService.candles(from: trades, interval: 300) }
    }

    private func quote() async {
        guard rawAmount > 0, launch.phase == .bonding else { buyQuote = nil; sellQuote = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        if side == .buy {
            buyQuote = try? await env.launchpad.quoteBuy(curve: launch.curve, quoteIn: rawAmount, recipient: session.address ?? .zero)
        } else {
            sellQuote = try? await env.launchpad.quoteSell(curve: launch.curve, tokensIn: rawAmount)
        }
    }
}

/// Launch a coin: name it, describe it, pick the pairing asset and economics, optionally buy first.
struct CreateLaunchView: View {
    let protocolInfo: ProtocolInfo?
    let onLaunched: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var description = ""
    @State private var logo = ""
    @State private var website = ""
    @State private var twitter = ""
    @State private var telegram = ""
    @State private var pair: Address = .zero
    @State private var creatorTaxBps = 0
    @State private var holderFeeSharing = true
    @State private var initialBuyText = ""
    @State private var showConfirm = false

    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && symbolValid }
    private var pairInfo: PairInfo? { protocolInfo?.pairs.first { $0.pair.address == pair }?.pair }
    private var initialBuy: BigUInt { Amount.parse(initialBuyText, decimals: pairInfo?.decimals ?? 18) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Coin") {
                    TextField("Name", text: $name)
                    TextField("Ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                    TextField("Image URL", text: $logo).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Links") {
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("X profile", text: $twitter).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Telegram", text: $telegram).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Paired with", selection: $pair) {
                        ForEach(protocolInfo?.pairs.filter(\.approved) ?? [], id: \.pair.address) { Text($0.pair.symbol).tag($0.pair.address) }
                    }
                    Stepper("Creator tax \(NumberStyle.basisPoints(creatorTaxBps))", value: $creatorTaxBps, in: 0...(protocolInfo?.maxCreatorTaxBps ?? 0), step: 25)
                    Toggle("Share fees with holders", isOn: $holderFeeSharing)
                } header: {
                    Text("Economics")
                } footer: {
                    Text("The creator tax is charged on curve trades. Fee sharing splits pool fees with everyone who holds the coin after graduation.")
                }
                Section {
                    AmountField(title: "0", text: $initialBuyText, token: pairInfo.map { Token(address: $0.address, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) })
                } header: {
                    Text("Initial Buy (Optional)")
                } footer: {
                    if let info = protocolInfo { Text("Launch fee: \(NumberStyle.units(info.launchFee, decimals: 18)) MON. Supply: \(NumberStyle.units(info.supply, decimals: 18, compact: true)) \(symbol.isEmpty ? "tokens" : symbol).") }
                }
            }
            .navigationTitle("New Launch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(!valid) }
            }
            .sheet(isPresented: $showConfirm) {
                if let address = session.address, let info = protocolInfo {
                    ConfirmationSheet(title: "Review Launch", confirmTitle: "Launch \(symbol)", build: { await env.launchpad.launchPlan(input, launchFee: info.launchFee, from: address) }, onDone: { dismiss(); onLaunched() }) {
                        DetailRow("Coin", "\(name) (\(symbol))")
                        DetailRow("Paired with", pairInfo?.symbol ?? "MON")
                        DetailRow("Creator tax", NumberStyle.basisPoints(creatorTaxBps))
                        DetailRow("Launch fee", "\(NumberStyle.units(info.launchFee, decimals: 18)) MON")
                        if initialBuy > 0 { DetailRow("Initial buy", "\(initialBuyText) \(pairInfo?.symbol ?? "MON")") }
                    }
                }
            }
            .onAppear { if let first = protocolInfo?.pairs.first(where: \.approved) { pair = first.pair.address } }
        }
    }

    private var input: LaunchInput {
        LaunchInput(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, description: description, logo: logo, socials: Socials(twitter: twitter, telegram: telegram, discord: "", website: website, farcaster: ""), creatorTaxBps: creatorTaxBps, holderFeeSharing: holderFeeSharing, pairToken: pair, initialBuy: initialBuy)
    }
}
