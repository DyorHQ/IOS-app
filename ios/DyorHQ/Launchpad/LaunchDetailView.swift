import BigInt
import DyorKit
import SwiftUI

/// One coin: price and progress, the curve's trades as candles, and the buy/sell ticket while the curve takes trades —
/// sell only for a coin on a retired launchpad (`Launch.isRetiredLaunchpad`, owner decision 2026-09-28) and in refund
/// mode. A completed curve waiting to graduate (stuck), a migrating launch and a graduated one get the graduation section.
struct LaunchDetailView: View {
    let launch: Launch
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var detail: LaunchDetail?
    /// The latest read of `detail` failed: its rows (stuck since, the Uniswap v4 fallback, hook fees waiting for a sweep,
    /// rewards queued for holders) keep the last good read, and the stats section says so, with Retry.
    @State private var detailUnread = false
    @State private var account: LaunchAccountView?
    @State private var trades: [CurveTrade] = []
    /// The last 24 hours of the curve's trades were all read (`CurveTrades.complete`). False: the read stopped short, and
    /// `trades` are the latest of them; the 24h volume reads as a minimum and the stats section says so, with Retry.
    @State private var tradesComplete = true
    /// The latest read of the trades failed outright: the chart and the list keep the last good read, and the stats
    /// section says so, with Retry.
    @State private var tradesUnread = false
    /// A read of the trades has answered at least once: until then the chart is loading or unread, never "No trades yet",
    /// and the 24h volume reads "—", never 0.
    @State private var tradesRead = false
    @State private var priceSeries: [PricePoint] = []
    @State private var pairUSD: Double?
    /// The coin's holders (`LaunchpadService.holders`): a minimum when not every transfer since the launch was read.
    @State private var holders: HolderCount?
    /// The latest read of the holders failed: the last good count stays, and the stats section says so, with Retry.
    @State private var holdersUnread = false
    @State private var loadingTrades = true
    /// The page's reads asked for after the first — Retry, a trade or a claim done — which key its read (`.task(id:)`):
    /// the read runs as the page's own task, so a new one cancels the one under way rather than stacking another
    /// 80-request scan beside it, and closing the page cancels it. In build 22 and earlier each was a `Task` of its own,
    /// which went on reading after the page closed, one more for every tap; at the logs gate, a screen's scan goes ahead
    /// of the wallet's history (`LogsGate.Lane`).
    @State private var reloads = 0
    @State private var side: TradeSide = .buy
    @State private var amountText = ""
    @State private var buyQuote: BuyQuote?
    @State private var sellQuote: SellQuote?
    @State private var showConfirm = false
    @State private var showClaim = false
    @State private var showCreatorClaim = false
    @State private var showGraduate = false

    init(launch: Launch) {
        self.launch = launch
        // A retired launchpad's curve, and one in refund mode, takes sells only: the ticket never starts on (or offers) Buy.
        _side = State(initialValue: launch.curveBuysOpen ? .buy : .sell)
    }

    private var isCreator: Bool { session.address != nil && session.address == launch.deployer }
    /// Buying on the curve is open: while it trades, and never on a retired launchpad, whose holders can only sell.
    private var buysOpen: Bool { launch.curveBuysOpen }

    /// The coin's price and market cap in USD, from its decimal price (`Launch.pairPrice`), when it and the pair asset's
    /// dollar price are known.
    private var priceUSD: Double? { launch.usdPrice(pairUSD: pairUSD) }
    private var marketCapUSD: Double? { launch.marketCapInPair.flatMap { cap in pairUSD.map { cap * $0 } } }
    /// 24h trading volume in pair units, and in USD when priced.
    private var volume24: Double { trades.filter { Date().timeIntervalSince1970 - Double($0.time) <= 86_400 }.reduce(0) { $0 + Amount.units($1.quoteAmount, decimals: $1.quoteDecimals) } }
    private var volume24USD: Double? { pairUSD.map { volume24 * $0 } }
    /// The 24h volume as the stats show it: "—" until the trades have been read once (never 0 while unread), and a
    /// minimum ("+") while what was read is the latest of them only, or the last good read when the latest failed: either
    /// way every trade it sums is one of the last 24 hours, and only trades it doesn't hold are missing.
    private var volume24Text: String {
        guard tradesRead else { return "—" }
        let value = volume24USD.map { PriceFormat.usdValue($0) } ?? "\(NumberStyle.number(volume24)) \(launch.pair.symbol)"
        return tradesComplete && !tradesUnread ? value : value + "+"
    }
    /// The holder count as the stats show it: "—" until it has been read, a minimum ("+") when not every transfer since the
    /// launch was (`HolderCount.complete`), and "—" for a minimum of none, which says nothing ("0+" read as no holders). A
    /// count kept from the last good read when the latest failed is shown as it was, and the stats section says it
    /// couldn't be read again.
    private var holdersText: String {
        guard let holders else { return "—" }
        if holders.complete { return "\(holders.count)" }
        return holders.count > 0 ? "\(holders.count)+" : "—"
    }

    private enum TradeSide { case buy, sell }
    private var token: Token { Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18, logoURL: URL(string: launch.logo), isLaunchpad: true) }
    private var pairToken: Token { Token(address: launch.pair.address, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals) }
    private var rawAmount: BigUInt { Amount.parse(amountText, decimals: side == .buy ? launch.pair.decimals : 18) ?? 0 }

    var body: some View {
        List {
            headerSection
            statsSection
            chartSection
            // The ticket only while the curve takes a sell: a completed curve still waiting to graduate (a stuck launch's
            // record says NotGraduated) refuses them, and gets the graduation section with Retry Graduation instead.
            if launch.curveSellsOpen { ticketSection } else { graduatedSection }
            if let account, account.tokenBalance > 0 || account.pendingRewards > 0 { holdingsSection(account) }
            feesSection
            if !trades.isEmpty { tradesSection }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(launch.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloads) { await load() }
        .task(id: "\(side)-\(rawAmount)") { await quote() }
        .sheet(isPresented: $showConfirm) { confirmation }
        .sheet(isPresented: $showGraduate) {
            ConfirmationSheet(title: "Retry Graduation", confirmTitle: "Graduate", build: { await env.launchpad.graduatePlan(launch: launch) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .graduate, title: tr("\(launch.symbol) graduated"), subtitle: launch.graduationVenue.title, hash: hash, section: "launch"), owner: session.address) }) {
                DetailRow("Venue", launch.graduationVenue.title)
                DetailRow("Who pays", "You (gas only)")
            }
        }
        .sheet(isPresented: $showClaim) {
            ConfirmationSheet(title: "Claim Rewards", confirmTitle: "Claim", build: { await env.launchpad.claimRewardsPlan(launch: launch, view: account) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed \(launch.symbol) rewards"), subtitle: account.map { "\(NumberStyle.units($0.pendingRewards, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" } ?? tr("holder rewards"), hash: hash, section: "launch"), owner: session.address) }) {
                if let account { DetailRow("Pending rewards", verbatim: "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
        }
        .sheet(isPresented: $showCreatorClaim) {
            ConfirmationSheet(title: "Claim Creator Fees", confirmTitle: "Claim Fees", build: { await env.launchpad.claimEscrowPlan(launch: launch) }, onDone: { reloads += 1 },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected \(launch.symbol) creator fees"), subtitle: account.map { "\(NumberStyle.units($0.escrowBalance, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" } ?? tr("creator fees"), hash: hash, section: "launch"), owner: session.address) }) {
                if let account { DetailRow("Claimable", verbatim: "\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
                DetailRow("To", session.address?.short ?? "—")
            }
        }
    }

    /// Creator fees and holder-fee-sharing transparency, mirroring Pons: everyone sees the fee mode, the creator can
    /// claim their escrowed fees here. From v1 the escrow pays each fee straight to the fee recipient, and holds only one
    /// it couldn't send; before v1 it holds every fee until claimed. Fee-sharing coins route creator fees to holders
    /// instead.
    private var feesSection: some View {
        Section {
            LabeledContent("Fee mode", value: launch.holderFeeSharing ? tr("Shared with holders") : tr("To creator"))
            if launch.creatorTaxBps > 0 { LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps)) }
            AddressRow(title: "Fee recipient", address: launch.creatorFeeRecipient.isZero ? launch.deployer : launch.creatorFeeRecipient)
            if isCreator, !launch.holderFeeSharing {
                if let account, account.escrowBalance > 0 {
                    LabeledContent("Your claimable fees") {
                        Text(verbatim: "\(NumberStyle.units(account.escrowBalance, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)")
                            .monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.brand)
                    }
                    Button("Claim Creator Fees", systemImage: "banknote") { Haptics.tap(); showCreatorClaim = true }.disabled(!session.canSign)
                } else if launch.generation.pushesFees {
                    // The escrow sends each fee straight to the fee recipient: it keeps only a payment that couldn't be sent.
                    Paragraph("Nothing to claim — fees are paid straight to the fee recipient.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Paragraph("Nothing to claim yet — fees accrue as people trade your coin.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Creator Fees")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Paragraph(verbatim: WordWrap.sentences(launch.holderFeeSharing
                    ? tr("This coin routes its creator fees to holders — each holder claims their pro-rata share (see Your Holdings, or My Launchpad).")
                    : launch.generation.pushesFees
                    ? tr("The creator earns their share of trading fees plus the creator tax, paid straight to the fee recipient. A payment that can't be sent waits in the fee escrow to be claimed; one claim sweeps those across all your launches paired in this asset.")
                    : tr("The creator earns their share of trading fees plus the creator tax; they accrue in the fee escrow and can be claimed any time. One claim sweeps fees across all your launches paired in this asset."),
                    // A Monday Trade pool has no hook: its 1% fee is harvested to DyorHQ, with no creator tax or share in it.
                    launch.graduationVenue == .monday ? tr("These come from curve trades only: once it graduates on Monday Trade, the pool's 1% fee goes to DyorHQ.") : ""))
                LearnMoreLink(.launchpadFeesAndRewards)
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // By address: its art once the registry knows the coin, its launch's own logo (held to the same hosts)
                    // until then.
                    TokenLogo(token: Token(address: launch.token, symbol: launch.symbol, name: launch.name, decimals: 18,
                                           logoURL: URL(string: launch.logo), isLaunchpad: true), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(launch.name).font(.title3.weight(.semibold))
                        Text(verbatim: launch.isSellOnly ? "\(launch.statusTitle) · \(tr("Retired launchpad"))" : launch.statusTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: launch.pairPrice.map { "\(NumberStyle.number($0)) \(launch.pair.symbol)" } ?? "—")
                            .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                        if let priceUSD { Text(PriceFormat.usdPrice(priceUSD)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().accessibilityLabel(PriceFormat.spoken(priceUSD)) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—").monospacedDigit().fontWeight(.medium)
                        if let marketCapUSD { Text(PriceFormat.usdValue(marketCapUSD)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        else { Text("Market cap").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if launch.phase == .bonding {
                    Gauge(value: Double(launch.progressBps) / 10_000) {
                        Text("Graduation")
                    } currentValueLabel: {
                        Text(verbatim: "\(launch.progressBps / 100)%")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    Paragraph("Graduates at \(NumberStyle.units(launch.graduationThreshold, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol) raised. Liquidity then moves to a locked \(launch.graduationVenue.title) pool.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            // Graduation is explained by the gauge while the curve trades, and by the graduation section once it doesn't:
            // the link follows the explanation on screen, so there is one either way.
            if launch.phase == .bonding, launch.curveSellsOpen { LearnMoreLink(.launchpadGraduation) }
        }
    }

    private var chartSection: some View {
        Section {
            PriceChart(points: priceSeries, isLoading: loadingTrades, tint: chartTint)
                .frame(height: 180)
                .padding(.vertical, 4)
                .accessibilityLabel("Price from curve trades")
        } header: {
            Text("Price")
        } footer: {
            // Only while the curve trades: a graduated coin trades in its pool, which its Graduated section explains. And only
            // when the last 24 hours were read in full: a read that stopped short or failed isn't "no trades".
            if trades.isEmpty, !loadingTrades, tradesRead, tradesComplete, !tradesUnread, launch.phase == .bonding {
                Paragraph("No trades yet — the chart moves up as people buy on the curve and down as they sell.").font(.caption)
            }
        }
    }

    private var chartTint: Color {
        guard let first = priceSeries.first?.usd, let last = priceSeries.last?.usd, first != last else { return Color.brand }
        return last >= first ? Color.positive : Color.negative
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                stat("24h Volume", volume24Text)
                Divider().frame(height: 34)
                stat("Holders", holdersText)
                Divider().frame(height: 34)
                stat("Progress", "\(launch.progressBps / 100)%")
            }
            if detailUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "Some details of this launch couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            // A figure built from a read that stopped short, or kept from the last good read, says so: never a part passed
            // off as the whole. Nothing read yet says just that: there is no part.
            if !loadingTrades, tradesUnread || !tradesComplete {
                HStack(alignment: .firstTextBaseline) {
                    if tradesRead {
                        InlineError(message: "Part of this coin's trades couldn't be read just now, so the chart and 24h volume may be missing some.")
                    } else {
                        InlineError(message: "This coin's trades couldn't be read just now.")
                    }
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            }
            if holdersUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "This coin's holders couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                }
            } else if let holders, !holders.complete {
                // A coin older than one read reaches back (80 requests: about 17 days of its age on the widest endpoint,
                // hours on the narrow ones) always gets a minimum: no failure, and no Retry that could ever do better.
                Paragraph("Counted from this coin's most recent transfers only, so there may be more holders.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tradesSection: some View {
        Section("Recent Trades") {
            ForEach(trades.reversed().prefix(25)) { trade in
                LaunchTradeRow(trade: trade, symbol: launch.symbol, pair: launch.pair)
            }
        }
    }

    private var ticketSection: some View {
        Section {
            if buysOpen {
                Picker("Side", selection: $side) {
                    Text("Buy").tag(TradeSide.buy)
                    Text("Sell").tag(TradeSide.sell)
                }
                .pickerStyle(.segmented)
            } else {
                Label(launch.isRetiredLaunchpad ? RetiredLaunchpad.notice : tr("Refund mode: sell back into the curve at its price, with no fees."), systemImage: "arrow.up.right.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            AmountField(title: "0" as String, text: $amountText, token: side == .buy ? pairToken : token) {
                guard let account else { return }
                // A native-MON buy keeps the network fee back (as Swap, Send and Bridge Max do), or the buy cannot pay gas.
                let buyable = launch.pair.isNative ? NetworkFeeReserve.spendable(balance: account.pairBalance, reserve: NetworkFeeReserve.monadFallback) : account.pairBalance
                amountText = side == .buy ? Amount.exact(buyable, decimals: launch.pair.decimals) : Amount.exact(account.tokenBalance, decimals: 18)
            }
            if side == .buy, let q = buyQuote, rawAmount > 0 {
                DetailRow("You receive", verbatim: "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                DetailRow("Curve fee", verbatim: "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.snipe > 0 { DetailRow("Early-buy tax", verbatim: "\(NumberStyle.units(q.snipe, decimals: launch.pair.decimals)) \(launch.pair.symbol)", tint: Color.attention) }
                if q.refund > 0 { DetailRow("Refunded (curve full)", verbatim: "\(NumberStyle.units(q.refund, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            if side == .sell, let q = sellQuote, rawAmount > 0 {
                DetailRow("You receive", verbatim: "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                DetailRow("Curve fee", verbatim: "\(NumberStyle.units(q.fee, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                if q.tax > 0 { DetailRow("Creator tax", verbatim: "\(NumberStyle.units(q.tax, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
            }
            PrimaryButton(title: side == .buy ? "Buy \(launch.symbol)" : "Sell \(launch.symbol)",
                          isDisabled: rawAmount == 0 || !session.canSign || (side == .buy ? buyQuote == nil : sellQuote == nil) || shortfall != nil) { showConfirm = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text(buysOpen ? "Trade on the Curve" : "Sell on the Curve")
        } footer: {
            if !session.canSign { Text("Sign in to trade.") }
            else if let shortfall { Paragraph(shortfall).foregroundStyle(Color.attention) }
            else if let account { Paragraph("Balance: \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)) \(launch.symbol) · \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)) \(launch.pair.symbol)") }
        }
    }

    /// Why the trade can't go ahead on this balance (UI-4): the amount is more than the wallet holds. Nil while the
    /// balance is unknown; the network still refuses what the wallet can't pay.
    private var shortfall: String? {
        guard let account, rawAmount > 0 else { return nil }
        if side == .buy, rawAmount > account.pairBalance {
            return tr("Not enough \(launch.pair.symbol): you have \(NumberStyle.units(account.pairBalance, decimals: launch.pair.decimals)).")
        }
        if side == .sell, rawAmount > account.tokenBalance {
            return tr("Not enough \(launch.symbol): you have \(NumberStyle.units(account.tokenBalance, decimals: 18, compact: true)).")
        }
        return nil
    }

    private var graduatedSection: some View {
        Section {
            // Only a graduated coin has a pool to swap in (a retired launchpad's too, both ways). Stuck or migrating, nothing
            // trades yet: no Swap, and no "you can sell" either.
            if launch.phase == .graduated {
                Button("Swap \(launch.symbol) on \(launch.graduationVenue.title)", systemImage: "arrow.left.arrow.right") {
                    router.openSwap(tokenIn: pairToken.isNative ? Token.mon : pairToken, tokenOut: token)
                }
                // The v4 pool key carries fee 0 (the hook levies the launch's poolFeeBps); a Monday Trade pool uses
                // the graduation executor's fixed 1% tier (MondayGraduationExecutor.FEE).
                LabeledContent("Pool fee", value: NumberStyle.basisPoints(launch.graduationVenue == .monday ? 100 : launch.poolFeeBps))
                if launch.graduationVenue == .uniswapV4, let detail, detail.hookFeesAwaitingSweep > 0 {
                    LabeledContent("Waiting for a sweep") {
                        Text(verbatim: "\(NumberStyle.units(detail.hookFeesAwaitingSweep, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit()
                    }
                }
            }
            if isStuck, let detail {
                LabeledContent("Stuck since", value: Date(timeIntervalSince1970: TimeInterval(detail.stuckSince)).formatted(date: .abbreviated, time: .shortened))
                if launch.keepersTakeGraduateFallback, let opens = detail.v4FallbackOpensAt {
                    LabeledContent("Uniswap v4 fallback", value: detail.isV4FallbackOpen(at: Int(Date().timeIntervalSince1970))
                                   ? tr(LocalizedStringResource("Open", comment: "The Uniswap v4 fallback can be used now: an adjective [tight]"))
                                   : tr("Opens \(Date(timeIntervalSince1970: TimeInterval(opens)).formatted(date: .abbreviated, time: .shortened))"))
                }
                Button("Retry Graduation", systemImage: "arrow.clockwise") { showGraduate = true }.disabled(!session.canSign)
            }
        } header: {
            launch.phase == .graduated ? Text("Graduated") : launch.awaitsGraduation ? Text("Graduation Pending") : Text(verbatim: launch.phase.title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if launch.phase == .graduated {
                    // As MemeHook and MondayFeeVault pay them, and as the docs' FAQ describes (GP-6).
                    Paragraph(launch.graduationVenue == .monday
                         ? "The curve's liquidity is permanently locked in a Monday Trade pool — trades now route through the Swap screen. The pool's 1% swap fee is harvested to a DyorHQ fees wallet; it isn't paid to holders or the creator, and there is no creator tax on the pool."
                         : "The curve's liquidity is permanently locked in a Uniswap v4 pool — trades now route through the Swap screen. Each swap pays the pool fee plus the creator tax to the DyorHQ hook: part of the pool fee goes to DyorHQ, and the rest, with the creator tax, to the creator, or to holders when fee sharing is on. \(v4FeeTiming)")
                } else if isStuck {
                    Paragraph(stuckFooter)
                } else if launch.awaitsGraduation {
                    Paragraph("The curve is full. It graduates next, into a locked \(launch.graduationVenue.title) pool, and then trades on the Swap screen.")
                } else {
                    Paragraph("This launch is between phases. Trading resumes when migration completes.")
                }
                LearnMoreLink(.launchpadGraduation)
            }
        }
    }

    /// When the hook pays what a v4 swap earned: a v2 hook pays the holders' part in the swap itself (released to them a
    /// block later) and keeps only the creator's and DyorHQ's parts for a sweep; an older hook keeps everything.
    private var v4FeeTiming: String {
        launch.generation.hasV2Getters
            ? tr("Holders are paid as trades happen; only the creator's and DyorHQ's parts wait in the hook until they're swept.")
            : tr("Fees wait in the hook until they're swept.")
    }

    /// A completed curve whose migration reverted (the factory records `stuckSince`): the audit's rescue paths apply. Only
    /// while it still waits to graduate: a rescued launch keeps its `stuckSince`, but `graduate` reverts
    /// `WrongGraduationPhase` there.
    private var isStuck: Bool { launch.awaitsGraduation && (detail?.stuckSince ?? 0) > 0 }

    /// The app never offers the Uniswap v4 fallback (`graduateFallback`), on any stack: DyorHQ's keepers send it with the
    /// gas it needs (owner decision 2026-09-28). Only the plain Retry Graduation is offered here.
    private var stuckFooter: String {
        guard launch.keepersTakeGraduateFallback else { return tr("The last graduation attempt failed. Anyone can retry it; you only pay the gas.") }
        let waits = detail?.fallbackRule?.waits ?? false
        return waits
            ? tr("The last graduation attempt failed. Anyone can retry it on Monday Trade; you only pay the gas. DyorHQ's keepers will finish the graduation: they retry it with about 29.9M gas and, if Monday Trade still refuses it, move it to a locked Uniswap v4 pool once it has been stuck for a day (a \(launch.pair.symbol) coin stays on Monday Trade until then).")
            : tr("The last graduation attempt failed. Anyone can retry it on Monday Trade; you only pay the gas. DyorHQ's keepers will finish the graduation: they retry it with about 29.9M gas and, if Monday Trade still refuses it, move it to a locked Uniswap v4 pool.")
    }

    private func holdingsSection(_ account: LaunchAccountView) -> some View {
        Section("Your Holdings") {
            LabeledContent("Balance") { AmountText(amount: account.tokenBalance, token: token, compact: true) }
            if account.pendingRewards > 0 {
                LabeledContent("Pending rewards") { Text(verbatim: "\(NumberStyle.units(account.pendingRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
                Button("Claim Rewards", systemImage: "gift") { showClaim = true }.disabled(!session.canSign)
            }
            if let detail, detail.queuedRewards > 0 {
                // Rewards wait one block before they are shared out (audit fix against flash-loan reward sniping).
                LabeledContent("Queued for holders") { Text(verbatim: "\(NumberStyle.units(detail.queuedRewards, decimals: launch.pair.decimals)) \(launch.pair.symbol)").monospacedDigit() }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            if !launch.description.isEmpty { Paragraph(launch.description).font(.subheadline) }
            AddressRow(title: "Token", address: launch.token)
            AddressRow(title: "Creator", address: launch.deployer)
            LabeledContent("Creator tax", value: NumberStyle.basisPoints(launch.creatorTaxBps))
            LabeledContent("Holder fee sharing", value: launch.holderFeeSharing
                           ? tr(LocalizedStringResource("On", comment: "A setting that is switched on [tight]"))
                           : tr(LocalizedStringResource("Off", comment: "A setting that is switched off [tight]")))
            LabeledContent("Graduation venue", value: launch.graduationVenue.title)
            ForEach(socialLinks, id: \.0) { label, url in
                Link(destination: url) { Label(label, systemImage: "link") }
            }
        }
    }

    private var socialLinks: [(String, URL)] {
        // not localized: X, Telegram, Discord and Farcaster are the services' own names.
        [(tr("Website"), launch.socials.website), ("X", launch.socials.twitter), ("Telegram", launch.socials.telegram), ("Discord", launch.socials.discord), ("Farcaster", launch.socials.farcaster)]
            // Creator-set strings: only web links, never another app's URL scheme (a wallet's dapp link, say).
            .compactMap { label, value in URL(string: value).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil ? (label, $0) : nil } }
    }

    /// The slippage a curve trade allows: the review's Minimum and the minimum the trade signs are 1% under the quote,
    /// rounded down (`LaunchpadMath.minimumOut`).
    private static let curveSlippageBps = 100

    @ViewBuilder private var confirmation: some View {
        if let address = session.address {
            if side == .buy, buysOpen, let q = buyQuote {
                let minimum = q.minimumOut(slippageBps: Self.curveSlippageBps)
                ConfirmationSheet(title: "Buy \(launch.symbol)", confirmTitle: "Buy", build: { try await env.launchpad.buyPlan(launch: launch, quoteIn: rawAmount, minTokensOut: minimum, recipient: address) }, onDone: { amountText = ""; reloads += 1 }, onCompleted: { hash in
                    // Bought here, so chosen here: never shown as Unverified, as a swap into a token isn't.
                    KnownTokenStore.add(token, owner: session.address)
                    KnownTokenStore.markChosen(launch.token, owner: session.address)
                    Activity.record(ActivityRecord(kind: .buy, title: tr("Bought \(launch.symbol)"), subtitle: tr("\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(rawAmount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)"), hash: hash, usd: pairUSD.map { Amount.units(rawAmount, decimals: launch.pair.decimals) * $0 }), owner: session.address)
                    // The fill is in the wallet's history in seconds, not at the next top-up: My Launchpad's profit and loss
                    // and activity wait for it (`WalletHistorySnapshot.fillsCoverage`), and Total Volume counts it.
                    env.history.kick(env: env)
                }, intent: .launchpadBuy(token: launch.token, pay: .init(token: launch.pairToken, amount: rawAmount), usd: pairUSD.map { Amount.units(rawAmount, decimals: launch.pair.decimals) * $0 })) {
                    DetailRow("You pay", verbatim: "\(NumberStyle.units(rawAmount, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("You receive", verbatim: "\(NumberStyle.units(q.tokensOut, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(minimum, decimals: 18, compact: true)) \(launch.symbol) (1% slippage)")
                }
            } else if side == .sell, let q = sellQuote {
                let minimum = q.minimumOut(slippageBps: Self.curveSlippageBps)
                ConfirmationSheet(title: "Sell \(launch.symbol)", confirmTitle: "Sell", build: { await env.launchpad.sellPlan(launch: launch, tokensIn: rawAmount, minQuoteOut: minimum, recipient: address) }, onDone: { amountText = ""; reloads += 1 }, onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .sell, title: tr("Sold \(launch.symbol)"), subtitle: tr("\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol) for \(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)"), hash: hash, usd: pairUSD.map { Amount.units(q.quoteOut, decimals: launch.pair.decimals) * $0 }), owner: session.address)
                    env.history.kick(env: env)
                }, intent: .launchpadSell(token: launch.token, amount: rawAmount, usd: pairUSD.map { Amount.units(q.quoteOut, decimals: launch.pair.decimals) * $0 })) {
                    DetailRow("You sell", verbatim: "\(NumberStyle.units(rawAmount, decimals: 18, compact: true)) \(launch.symbol)")
                    DetailRow("You receive", verbatim: "\(NumberStyle.units(q.quoteOut, decimals: launch.pair.decimals)) \(launch.pair.symbol)")
                    DetailRow("Minimum", "\(NumberStyle.units(minimum, decimals: launch.pair.decimals)) \(launch.pair.symbol) (1% slippage)")
                }
            }
        }
    }

    private func load() async {
        async let d = env.launchpad.launch(token: launch.token, factory: launch.factory)
        async let t = env.launchpad.trades(curve: launch.curve, pair: launch.pair)
        async let h = env.launchpad.holders(token: launch.token, excluding: [launch.curve], launchedAt: launch.launchedAt)
        async let pu = pairUSDPrice()
        // A failed read hides the wallet's balances and claims rather than keep ones a trade or claim since may have
        // changed: Your Holdings, Max, the balance check and the claims act on them.
        if let address = session.address { account = try? await env.launchpad.accountView(launch, account: address) }
        // A launch that can't be read keeps the last good detail and says so (`LaunchpadService.launch`); one that isn't
        // recorded reads as nil, as before.
        do {
            detail = try await d
            detailUnread = false
        } catch {
            // A read cut short because the page went off screen (a pushed view) isn't a failure: it reloads on return.
            if !Task.isCancelled { detailUnread = true }
        }
        // A failed read keeps the pair's last good dollar price, and with it the dollar price, market cap and volume.
        if let usd = await pu { pairUSD = usd }
        let curveTrades = await t
        // Nor are its empty answers: the chart keeps the trades it has.
        guard !Task.isCancelled else { return }
        if let curveTrades {
            // Read newest first: a read that stopped short holds the latest trades, and says so (`tradesComplete`).
            trades = curveTrades.trades
            tradesComplete = curveTrades.complete
            tradesUnread = false
            tradesRead = true
        } else {
            // A read that failed outright keeps the last good trades, and says so.
            tradesUnread = true
        }
        // In dollars only: the chart's axis reads "$". A USD-stable pair (USDC, AUSD) is $1 by definition, read or not
        // (`PriceService.definedPrices`); any other pair asset once its dollar price was read, so prices in MON are never
        // drawn under it.
        if let unit = pairUSD ?? PriceService.definedPrices(for: [pairToken])[pairToken.address]?.usd { priceSeries = Self.priceSeries(trades: trades, launch: launch, unit: unit) }
        loadingTrades = false
        let count = await h
        guard !Task.isCancelled else { return }
        // A count that couldn't be read keeps the last good one, and says so: never 0 for a read that failed.
        if let count { holders = count }
        holdersUnread = count == nil
    }

    private func pairUSDPrice() async -> Double? {
        (try? await env.prices.prices(for: [pairToken]))?[pairToken.address]?.usd
    }

    /// A price line for the chart: one point per curve trade, ending on the live decimal price (`Launch.pairPrice`) when
    /// it was read, with a launch-time baseline prepended so a coin with no trades still draws a flat line rather than an
    /// empty box. Sequential ids keep points distinct even when trades share a block.
    private static func priceSeries(trades: [CurveTrade], launch: Launch, unit: Double) -> [PricePoint] {
        var points: [PricePoint] = []
        var idx: UInt64 = 0
        for trade in trades where trade.price > 0 {
            points.append(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(trade.time)), usd: trade.price * unit)); idx += 1
        }
        guard let current = launch.pairPrice.map({ $0 * unit }) else { return points }
        points.append(PricePoint(block: idx, time: Date(), usd: current)); idx += 1
        if points.count < 2 {
            points.insert(PricePoint(block: idx, time: Date(timeIntervalSince1970: TimeInterval(launch.launchedAt)), usd: current), at: 0)
        }
        return points
    }

    private func quote() async {
        // Drop the previous amount's quote first: until this amount's quote lands, Buy/Sell stays disabled, so the
        // minimum-out the sheet signs can never come from a quote for a different amount. `.task(id:)` cancels this
        // task when the amount changes, and a cancelled task's answer is discarded.
        buyQuote = nil
        sellQuote = nil
        guard rawAmount > 0, launch.curveSellsOpen else { return }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        if side == .buy {
            guard buysOpen else { return }
            let fresh = try? await env.launchpad.quoteBuy(curve: launch.curve, quoteIn: rawAmount, recipient: session.address ?? .zero)
            if !Task.isCancelled { buyQuote = fresh }
        } else {
            let fresh = try? await env.launchpad.quoteSell(curve: launch.curve, tokensIn: rawAmount)
            if !Task.isCancelled { sellQuote = fresh }
        }
    }
}

/// One curve fill in the token page's recent-trades list: buy/sell, the token amount, the pair amount, and when — a
/// tap opens the transaction on Monadscan.
private struct LaunchTradeRow: View {
    let trade: CurveTrade
    let symbol: String
    let pair: PairInfo

    var body: some View {
        Group {
            if let hash = trade.transactionHash {
                Link(destination: Monad.explorerTransaction(hash)) { rowContent }.foregroundStyle(.primary)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: trade.isBuy ? "arrow.down.left" : "arrow.up.right")
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .background((trade.isBuy ? Color.positive : Color.negative).opacity(0.14), in: Circle())
                .foregroundStyle(trade.isBuy ? Color.positive : Color.negative)
            VStack(alignment: .leading, spacing: 1) {
                Text(trade.isBuy ? "Buy \(NumberStyle.units(trade.tokenAmount, decimals: 18, compact: true)) \(symbol)" : "Sell \(NumberStyle.units(trade.tokenAmount, decimals: 18, compact: true)) \(symbol)")
                    .font(.subheadline.weight(.medium))
                Text(trade.trader.short).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(NumberStyle.units(trade.quoteAmount, decimals: pair.decimals, compact: true)) \(pair.symbol)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(trade.time)) ago").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
