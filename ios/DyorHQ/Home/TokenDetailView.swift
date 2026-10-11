import DyorKit
import SwiftUI

/// Price, 24h chart from on-chain history, and the actions that make sense for a token.
struct TokenDetailView: View {
    let row: MarketRow
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(Session.self) private var session
    @State private var history: [PricePoint] = []
    @State private var loadingHistory = true
    /// Where the coin trades (`LaunchpadService.curveRoute(for:)`): Swap, or, while it is still on a launchpad's bonding
    /// curve (the live launchpad's or a retired one's), its Launch page, since no Swap venue routes a curve. Nil until
    /// read; `.unchecked` when the check failed, which keeps Swap and offers to check again.
    @State private var curveRoute: CurveRoute?
    @State private var checkingCurve = false
    /// The price read by the page itself, for a token Home's list didn't price (one opened from search, or a Moment Home
    /// last saw collecting).
    @State private var loaded: PriceInfo?
    /// Whether the page's own read found its Moment still collecting; nil until it has read, and Home's mark stands.
    @State private var loadedNotTrading: Bool?

    /// The price as shown: Home's read, else the page's own (`loaded`).
    private var info: PriceInfo? { row.info ?? loaded }
    private var price: Double? { row.usd ?? loaded.flatMap { DyorPrice.valid($0.usd) } }
    private var change: Double? { row.usd != nil ? row.change24h : loaded?.change24h }
    /// A Moment still collecting: no price and no chart, "Not trading yet" in their place. The page's own read decides
    /// once it has one, so a Moment that graduated since Home's read shows its price.
    private var notTradingYet: Bool { loadedNotTrading ?? row.notTradingYet }

    /// Sent to the wallet rather than chosen in the app (`KnownTokenStore.unverified`).
    private var received: Bool { KnownTokenStore.isUnverified(row.token.address, owner: session.address) }
    /// Its label (`TokenBadge`): a DyorHQ coin's, a look-alike's warning, Unverified, or none.
    private var badge: TokenBadge { env.dyorCoins.badge(row.token, receivedUnasked: received) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        TokenLogo(token: row.token, size: 44)
                        if notTradingYet {
                            Text("Not trading yet").font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                USDText(price: price, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                                if info?.isNew == true { NewBadge() } else { ChangeBadge(value: change) }
                            }
                        }
                    }
                    // A DyorHQ coin: its move against its pair asset, then where its price comes from.
                    if !notTradingYet, let pairChange = info?.pairChangeText {
                        Text(pairChange).font(.footnote.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !notTradingYet, let source = info?.sourceLine {
                        Text(source).font(.footnote).foregroundStyle(.secondary)
                    }
                    if notTradingYet {
                        Paragraph("Its Moment hasn't graduated yet, so the coin has no market. It trades once the Moment graduates.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Past 24 hours").font(.footnote).foregroundStyle(.secondary)
                        PriceChart(points: history, isLoading: loadingHistory, tint: (change ?? 0) < 0 ? Color.negative : Color.positive)
                            .frame(height: 180)
                    }
                }
                .padding(.vertical, 6)
            }
            if badge.isImitation, let title = badge.title {
                // A look-alike keeps its warning, whatever made it (a DyorHQ launch called USDC included).
                Section {
                    Label(title, systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Paragraph("This token carries the name of another token but is a different contract. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if badge.isDyorHQ, let coin = env.dyorCoins.coin(row.token.address) {
                launchedOnDyorHQ(coin)
            } else if received || badge == .unverified {
                Section {
                    Label("Unverified token", systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Text(received
                         ? "This token arrived in your wallet without you choosing it in DyorHQ. Anyone can send any token to any wallet, with any name — including a real token's. Check the contract below before you trade it, and never follow a link or site its name points to."
                         : "This token's name or symbol has characters that can make it read as another. Check the contract below before you trade it, and never follow a link or site its name points to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if row.balance > 0 {
                Section("Your Balance") {
                    LabeledContent("Amount") { AmountText(amount: row.balance, token: row.token) }
                    LabeledContent("Value") {
                        if notTradingYet { Text("Not trading yet").foregroundStyle(.secondary) } else { USDText(value: price.map { Amount.units(row.balance, decimals: row.token.decimals) * $0 }) }
                    }
                }
            }
            Section("About") {
                LabeledContent("Name", value: row.token.displayName)
                if !row.token.isNative { AddressRow(title: "Contract", address: row.token.address) }
                LabeledContent("Decimals", value: String(row.token.decimals))
            }
            Section {
                if !SwapEngine.isTradable(row.token) {
                    // A retired cohort's Moment coin: past cohorts are claim-only, so no swap is offered.
                    Label("Past cohort · trading closed", systemImage: "lock").foregroundStyle(.secondary)
                } else if let route = curveRoute, route.isOnCurve, let title = route.actionTitle(row.token.symbol) {
                    // Never Swap: no venue routes a coin still on a launchpad's curve, live or retired. Its curve trades
                    // on its Launch page (Buy and Sell on the live launchpad, Sell only on a retired one), opened by
                    // reference when its launch couldn't be read.
                    Button(title, systemImage: "arrow.up.right.circle") { router.openLaunchPage(for: route) }
                } else {
                    Button("Swap \(row.token.symbol)", systemImage: "arrow.left.arrow.right") {
                        router.openSwap(tokenIn: row.token.symbol == "USDC" ? Token.mon : Token.usdc, tokenOut: row.token)
                    }
                    if curveRoute == .unchecked {
                        // The check failed: Swap stays, and so does the way to find out where the coin trades.
                        Button("Check Again", systemImage: "arrow.clockwise") { Task { await checkCurve() } }
                            .disabled(checkingCurve)
                    }
                }
                if let url = row.token.isNative ? nil : Monad.explorerToken(row.token.address) {
                    Link(destination: url) { Label("View on Monadscan", systemImage: "safari") }
                }
            } footer: {
                if SwapEngine.isTradable(row.token), let notice = curveRoute?.notice { Paragraph(notice) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.token.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A token Home's list didn't price (opened from search, or a Moment Home last saw collecting) is priced here,
            // once: a Moment that graduated since shows its price and chart.
            if row.usd == nil {
                loaded = (try? await env.prices.prices(for: [row.token]))?[row.token.address]
                loadedNotTrading = await env.prices.notTradingYet([row.token]).contains(row.token.address)
            }
            if !notTradingYet { history = (try? await env.prices.history(for: row.token, points: 48)) ?? [] }
            loadingHistory = false
        }
        .task(id: row.token.address) { await checkCurve() }
    }

    /// Where a DyorHQ coin was made, from its factory's record (`DyorCoinsModel`): a launchpad or a Moments cohort, live
    /// or retired, the launch's phase once known (`curveRoute`), its creator, and a way to its Launch page or its Moment.
    /// It stands in for the Unverified card: a DyorHQ coin sent to the wallet is labelled for what it is, and anyone can
    /// launch one, which the footer says.
    private func launchedOnDyorHQ(_ coin: DyorCoin) -> some View {
        Section {
            LabeledContent("Made on", value: coin.isMoment ? (coin.retired ? tr("A past Moments cohort") : tr("DyorHQ Moments")) : (coin.retired ? tr("A retired DyorHQ launchpad") : tr("The DyorHQ launchpad")))
            if let phase = launchPhase { LabeledContent("Phase", value: phase.title) }
            AddressRow(title: "Creator", address: coin.creator)
            if let key = coin.momentKey {
                if let link = MomentLink(key: key) {
                    Button("Open the Moment", systemImage: "photo.on.rectangle") {
                        router.pendingMomentLink = link
                        router.tab = .moments
                    }
                }
            } else {
                Button("Open the Launch Page", systemImage: "arrow.up.right.circle") {
                    if let launch = curveRoute?.launch { router.openLaunch(launch) } else { router.openLaunch(LaunchReference(token: coin.address, factory: coin.factory)) }
                }
            }
        } header: {
            Text("Launched on DyorHQ")
        } footer: {
            Paragraph("Anyone can launch a coin or publish a Moment on DyorHQ: this says where the coin was made, not that DyorHQ vouches for it.")
        }
    }

    /// A launch coin's phase, when the curve check read it: its launch's, or its factory's record's.
    private var launchPhase: LaunchPhase? {
        switch curveRoute {
        case .launchPage(let launch): return launch.phase
        case .launchUnread(_, _, let phase): return phase
        default: return nil
        }
    }

    /// Asks whether the coin is still on a launchpad's curve, and where it trades (one read of every known factory's
    /// record, then its launch). A graduated coin, or one no known launchpad launched, trades on Swap.
    private func checkCurve() async {
        checkingCurve = true
        defer { checkingCurve = false }
        let route = await env.launchpad.curveRoute(for: row.token)
        if Task.isCancelled { return }
        curveRoute = route
    }
}

/// "New" in place of a 24h change: a DyorHQ coin its factory hadn't recorded 24 hours ago (`PriceInfo.isNew`).
private struct NewBadge: View {
    var body: some View {
        Text("New", comment: "A badge on a new coin: just launched, or too new to have a 24h change [tight]")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brand.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.brand)
    }
}
