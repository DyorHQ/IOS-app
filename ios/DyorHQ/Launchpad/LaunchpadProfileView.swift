import BigInt
import DyorKit
import SwiftUI

/// The launchpad profile: a creator/trader dashboard for the signed-in wallet. Shows the coins you hold (with live
/// value and on-curve PnL), the coins you launched, your claimable creator fees, and your launchpad activity — the
/// money view for the Launch section. Creator fees accrue in the fee escrow per pair asset across all your launches;
/// "Claim" sweeps them in one transaction.
struct LaunchpadProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var model = LaunchpadProfileModel()

    // Same identity as the user Profile screen, so the two feel like one profile.
    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    private var displayName: String {
        social.profile?.display_name ?? session.account?.label ?? session.address?.short ?? "My Launchpad"
    }
    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
    private var subtitle: String {
        if let handle = social.profile?.handle { return "@\(handle)" }
        if let method = session.account?.method { return method == .watchOnly ? "Watching this address" : "Signed in with \(method.title)" }
        return "Launchpad profile"
    }
    @State private var tab: Tab = .positions
    @State private var claimTarget: ClaimTarget?

    private enum Tab: String, CaseIterable, Identifiable { case positions, launches, activity
        var id: String { rawValue }
        var label: String { self == .positions ? "Holdings" : rawValue.capitalized }
    }

    /// What a claim action withdraws: one creator-fee asset, one coin's holder rewards, or everything at once.
    private enum ClaimTarget: Identifiable {
        case creator(LaunchpadProfileModel.ClaimableAsset)
        case rewards(LaunchpadProfileModel.RewardClaim)
        case all
        var id: String {
            switch self {
            case .creator(let a): return "creator-\(a.token.hex)"
            case .rewards(let r): return "rewards-\(r.launch.token.hex)"
            case .all: return "all"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                claimSection
                Section {
                    Picker("View", selection: $tab) { ForEach(Tab.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                switch tab {
                case .positions: positionsSection
                case .launches: launchesSection
                case .activity: activitySection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("My Launchpad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .overlay { if model.loading, model.isEmpty { ProgressView().controlSize(.large) } }
            .task(id: session.address) { await model.load(env: env, address: session.address) }
            .refreshable { await model.load(env: env, address: session.address) }
            .sheet(item: $claimTarget) { claimSheet(for: $0) }
        }
    }

    // MARK: Header + claim

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Avatar(url: avatarURL, initials: initials, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            if let address = session.address { AddressRow(title: "Address", address: address) }
            HStack {
                stat("Portfolio", model.portfolioValueUSD.formatted(.currency(code: "USD")))
                Divider().frame(height: 34)
                stat("Launched", "\(model.created.count)")
                Divider().frame(height: 34)
                stat("Holdings", "\(model.positions.count)")
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var claimSection: some View {
        Section {
            if !model.hasClaimable {
                Text("Nothing to claim yet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Creator fees — one row per pair asset, each claimed on its own.
                ForEach(model.creatorClaimables) { asset in
                    claimRow(icon: "banknote", title: "Creator fees · \(asset.symbol)", amount: asset.amountText, usd: asset.usd) {
                        claimTarget = .creator(asset)
                    }
                }
                // Holder rewards — one row per fee-sharing coin held.
                ForEach(model.rewardClaimables) { reward in
                    claimRow(icon: "gift", title: "\(reward.launch.symbol) rewards", amount: reward.amountText, usd: nil) {
                        claimTarget = .rewards(reward)
                    }
                }
                if session.canSign, model.claimableCount > 1 {
                    Button { Haptics.tap(); claimTarget = .all } label: {
                        Text("Claim All").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent).tint(.brand)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        } header: {
            Text("Claimable Fees")
        } footer: {
            Text("Creator fees are held per pair asset across all your launches — claim each asset on its own, or Claim All to sweep every asset and holder reward in one go. Coins launched with fee-sharing on pay their fees to holders.")
        }
    }

    private func claimRow(icon: String, title: String, amount: String, usd: Double?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).frame(width: 30, height: 30)
                .background(Color.brand.opacity(0.14), in: Circle()).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(amount + (usd.map { " · \($0.formatted(.currency(code: "USD")))" } ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Claim", action: action).buttonStyle(.bordered).controlSize(.small).tint(.brand).disabled(!session.canSign)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Positions

    @ViewBuilder private var positionsSection: some View {
        Section {
            if model.positions.isEmpty {
                emptyRow("No launch coins held", "Buy a coin on the curve and it appears here with its PnL.")
            } else {
                ForEach(model.positions) { position in
                    Button { open(position.launch) } label: { PositionRow(position: position) }.buttonStyle(.plain)
                }
            }
        } header: { Text("Holdings") }
    }

    // MARK: Launches

    @ViewBuilder private var launchesSection: some View {
        Section {
            if model.created.isEmpty {
                emptyRow("No coins launched", "Launch a coin and it shows here with its market cap and performance.")
            } else {
                ForEach(model.created) { item in
                    Button { open(item.launch) } label: { CreatedRow(item: item) }.buttonStyle(.plain)
                }
            }
        } header: { Text("Coins You Launched") }
    }

    // MARK: Activity

    @ViewBuilder private var activitySection: some View {
        Section {
            if model.activity.isEmpty {
                emptyRow("No launchpad activity", "Your buys, sells and launches show here.")
            } else {
                ForEach(model.activity) { item in LaunchpadActivityRow(item: item) }
            }
        } header: { Text("Your Launchpad Activity") }
    }

    private func emptyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func open(_ launch: Launch) {
        dismiss()
        router.openLaunch(launch)
    }

    @ViewBuilder private func claimSheet(for target: ClaimTarget) -> some View {
        switch target {
        case .creator(let asset):
            ConfirmationSheet(
                title: "Claim \(asset.symbol) Fees", confirmTitle: "Claim \(asset.symbol)",
                build: { env.launchpad.claimEscrowPlan(native: asset.isNative, tokens: asset.isNative ? [] : [asset.token]) },
                onDone: { Task { await model.load(env: env, address: session.address) } }
            ) {
                DetailRow("Creator fees", asset.amountText)
                DetailRow("To", session.address?.short ?? "—")
            }
        case .rewards(let reward):
            ConfirmationSheet(
                title: "Claim \(reward.launch.symbol) Rewards", confirmTitle: "Claim",
                build: { env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) },
                onDone: { Task { await model.load(env: env, address: session.address) } }
            ) {
                DetailRow("Holder rewards", reward.amountText)
                DetailRow("To", session.address?.short ?? "—")
            }
        case .all:
            ConfirmationSheet(
                title: "Claim All Fees", confirmTitle: "Claim All",
                build: { await model.claimAllPlan(env: env) },
                onDone: { Task { await model.load(env: env, address: session.address) } }
            ) {
                ForEach(model.creatorClaimables) { asset in DetailRow("Creator · \(asset.symbol)", asset.amountText) }
                ForEach(model.rewardClaimables) { reward in DetailRow("\(reward.launch.symbol) rewards", reward.amountText) }
            }
        }
    }
}

// MARK: - Rows

private struct PositionRow: View {
    let position: LaunchpadProfileModel.Position

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: position.launch.symbol, logo: position.launch.logo)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(position.launch.symbol).font(.subheadline.weight(.semibold))
                Text("\(NumberStyle.units(position.balance, decimals: 18, compact: true)) · MC \(position.mcapText)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                if position.claimableRewards > 0 {
                    Text("Rewards: \(NumberStyle.units(position.claimableRewards, decimals: position.launch.pair.decimals, compact: true)) \(position.launch.pair.symbol)")
                        .font(.caption2).foregroundStyle(Color.brand)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(position.valueUSD.formatted(.currency(code: "USD"))).font(.subheadline.weight(.medium)).monospacedDigit()
                if let pnlUSD = position.pnlUSD {
                    Text("\(pnlUSD >= 0 ? "+" : "")\(pnlUSD.formatted(.currency(code: "USD")))\(position.pnlPercent.map { " (\($0 >= 0 ? "+" : ""))\(NumberStyle.number($0, maximumFractionDigits: 1))%)" } ?? "")")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(pnlUSD >= 0 ? Color.positive : Color.negative)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct CreatedRow: View {
    let item: LaunchpadProfileModel.Created

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: item.launch.symbol, logo: item.launch.logo)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.launch.symbol).font(.subheadline.weight(.semibold))
                    Text(item.launch.holderFeeSharing ? "Shares fees" : "Creator fees").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
                }
                Text(item.launch.phase == .bonding ? "\(item.launch.progressBps / 100)% to graduation" : item.launch.phase.title)
                    .font(.caption2).foregroundStyle(item.launch.phase == .graduated ? Color.positive : .secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.mcapUSD.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) } ?? "\(NumberStyle.units(item.launch.marketCap, decimals: item.launch.pair.decimals, compact: true)) \(item.launch.pair.symbol)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Text("Market cap").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct LaunchpadActivityRow: View {
    let item: FeedItem

    var body: some View {
        Group {
            if let hash = item.hash {
                Link(destination: Monad.explorerTransaction(hash)) { content }.foregroundStyle(.primary)
            } else { content }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon).font(.footnote.weight(.bold))
                .frame(width: 30, height: 30).background(Color.brand.opacity(0.14), in: Circle()).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.medium))
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Model

@Observable
@MainActor
final class LaunchpadProfileModel {
    struct Position: Identifiable, Hashable {
        let launch: Launch
        let balance: BigUInt
        let valueUSD: Double
        let pnlUSD: Double?
        let pnlPercent: Double?
        let claimableRewards: BigUInt
        var id: Address { launch.token }
        var mcapText: String { "\(NumberStyle.units(launch.marketCap, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" }
    }

    struct Created: Identifiable, Hashable {
        let launch: Launch
        let mcapUSD: Double?
        var id: Address { launch.token }
    }

    private(set) var positions: [Position] = []
    private(set) var created: [Created] = []
    private(set) var escrow = EscrowBalances(native: 0, tokens: [:])
    private(set) var activity: [FeedItem] = []
    private(set) var loading = false

    // Pair asset → USD price, and pair asset → (symbol, decimals) for escrow display.
    private var pairUSD: [Address: Double] = [:]
    private var pairMeta: [Address: (symbol: String, decimals: Int)] = [:]

    /// One claimable creator-fee balance, in a single pair asset (native MON is `token == .zero`). Claimed on its own
    /// so the user always knows which asset they're withdrawing.
    struct ClaimableAsset: Identifiable, Hashable {
        let token: Address
        let symbol: String
        let amount: BigUInt
        let decimals: Int
        let usd: Double
        var id: Address { token }
        var isNative: Bool { token.isZero }
        var amountText: String { "\(NumberStyle.units(amount, decimals: decimals, compact: true)) \(symbol)" }
    }

    /// One coin's claimable holder rewards (fee-sharing coins), in that coin's pair asset.
    struct RewardClaim: Identifiable, Hashable {
        let launch: Launch
        let amount: BigUInt
        var id: Address { launch.token }
        var amountText: String { "\(NumberStyle.units(amount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" }
    }

    var isEmpty: Bool { positions.isEmpty && created.isEmpty && activity.isEmpty }
    var portfolioValueUSD: Double { positions.reduce(0) { $0 + $1.valueUSD } }

    /// Creator fees claimable, one entry per pair asset (MON first, then each token).
    var creatorClaimables: [ClaimableAsset] {
        var out: [ClaimableAsset] = []
        if escrow.native > 0 {
            out.append(ClaimableAsset(token: .zero, symbol: "MON", amount: escrow.native, decimals: 18, usd: Amount.units(escrow.native, decimals: 18) * (pairUSD[Monad.native] ?? 0)))
        }
        for (token, amount) in escrow.tokens where amount > 0 {
            let meta = pairMeta[token] ?? ("", 18)
            out.append(ClaimableAsset(token: token, symbol: meta.symbol, amount: amount, decimals: meta.decimals, usd: Amount.units(amount, decimals: meta.decimals) * (pairUSD[token] ?? 0)))
        }
        return out.sorted { $0.usd > $1.usd }
    }

    /// Holder rewards claimable, one entry per fee-sharing coin held.
    var rewardClaimables: [RewardClaim] {
        positions.filter { $0.claimableRewards > 0 }.map { RewardClaim(launch: $0.launch, amount: $0.claimableRewards) }
    }

    var claimableCount: Int { creatorClaimables.count + rewardClaimables.count }
    var hasClaimable: Bool { claimableCount > 0 }
    var totalClaimableUSD: Double { creatorClaimables.reduce(0) { $0 + $1.usd } }

    var claimableSummary: String {
        guard hasClaimable else { return "Nothing to claim yet" }
        if totalClaimableUSD > 0 { return totalClaimableUSD.formatted(.currency(code: "USD")) }
        return "\(claimableCount) to claim"
    }

    /// Claims everything at once: creator escrow across every asset, plus every coin's holder rewards.
    func claimAllPlan(env: AppEnvironment) async -> [TransactionStep] {
        var steps = await env.launchpad.claimEscrowPlan(native: escrow.hasNative, tokens: escrow.claimableTokens)
        for reward in rewardClaimables { steps += await env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) }
        return steps
    }

    func load(env: AppEnvironment, address: Address?) async {
        guard let address, env.config.launchpad.isDeployed else { positions = []; created = []; escrow = EscrowBalances(native: 0, tokens: [:]); activity = []; return }
        loading = true
        defer { loading = false }

        let launches = (try? await env.launchpad.launches(limit: 100)) ?? []
        guard !launches.isEmpty else { positions = []; created = []; return }

        // Pair-asset prices (MON priced live; USDC/AUSD pinned to 1 by the price service).
        let pairTokens = Set(launches.map(\.pairToken))
        let priceTokens = pairTokens.map { addr -> Token in
            if let launch = launches.first(where: { $0.pairToken == addr }) {
                return Token(address: addr, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
            }
            return Token(address: addr, symbol: "", name: "", decimals: 18)
        }
        let priceMap = (try? await env.prices.prices(for: priceTokens)) ?? [:]
        pairUSD = Dictionary(uniqueKeysWithValues: pairTokens.map { ($0, priceMap[$0]?.usd ?? ($0.isZero ? (priceMap[Monad.native]?.usd ?? 0) : 0)) })
        // Multiple launches share a pair asset (MON / USDC / AUSD), so keys repeat — dedupe instead of
        // Dictionary(uniqueKeysWithValues:), which traps on the first duplicate key and crashed this screen.
        pairMeta = Dictionary(launches.map { ($0.pairToken, ($0.pair.symbol, $0.pair.decimals)) }, uniquingKeysWith: { first, _ in first })

        // Balances across every launch token in one multicall.
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        let balances = (try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:]

        // Coins you created.
        created = launches.filter { $0.deployer == address }.map { launch in
            let usd = pairUSD[launch.pairToken].map { Amount.units(launch.marketCap, decimals: launch.pair.decimals) * $0 }
            return Created(launch: launch, mcapUSD: usd)
        }
        .sorted { ($0.mcapUSD ?? 0) > ($1.mcapUSD ?? 0) }

        // Escrow (claimable creator fees), keyed by the pair assets of the coins you created.
        escrow = (try? await env.launchpad.escrowBalances(account: address, pairTokens: created.map(\.launch.pairToken))) ?? EscrowBalances(native: 0, tokens: [:])

        // Held coins → position with on-curve PnL and holder rewards, computed concurrently.
        let held = launches.filter { (balances[$0.token] ?? 0) > 0 }
        let usdByPair = pairUSD
        positions = await withTaskGroup(of: Position?.self) { group in
            for launch in held {
                let balance = balances[launch.token] ?? 0
                let price = usdByPair[launch.pairToken] ?? 0
                group.addTask { await Self.position(env: env, address: address, launch: launch, balance: balance, pairUSD: price) }
            }
            var out: [Position] = []
            for await p in group { if let p { out.append(p) } }
            return out.sorted { $0.valueUSD > $1.valueUSD }
        }

        // Your launchpad activity.
        let lpActivity = ((try? await env.launchpad.activity(limit: 60, lookbackBlocks: Monad.blocksPerDay * 7, launches: launches)) ?? []).filter { $0.actor == address }
        let byToken = Dictionary(launches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        activity = lpActivity.map { Self.feedItem(from: $0, launch: byToken[$0.token]) }
    }

    /// One held-coin position: current value, holder rewards, and PnL from the wallet's own curve trades
    /// (net MON invested vs current value, realized + unrealized), scanning only since the coin launched.
    private static func position(env: AppEnvironment, address: Address, launch: Launch, balance: BigUInt, pairUSD: Double) async -> Position? {
        let priceUnits = LaunchpadService.priceNumber(launch)
        let currentValuePair = Amount.units(balance, decimals: 18) * priceUnits
        let valueUSD = currentValuePair * pairUSD

        // Bound the trade scan to the coin's age (plus a buffer), capped at 30 days, so PnL uses the full history
        // without sweeping a month of blocks for a coin launched an hour ago.
        let ageSeconds = max(0, Int(Date().timeIntervalSince1970) - launch.launchedAt)
        let lookback = UInt64(min(Double(Monad.blocksPerDay) * 30, Double(ageSeconds) / 0.4 + 20_000))
        var pnlUSD: Double?
        var pnlPercent: Double?
        if let trades = try? await env.launchpad.trades(curve: launch.curve, pair: launch.pair, lookbackBlocks: lookback) {
            let mine = trades.filter { $0.trader == address }
            if !mine.isEmpty {
                var buyCost = 0.0, sellProceeds = 0.0
                for trade in mine {
                    let quote = Amount.units(trade.quoteAmount, decimals: trade.quoteDecimals)
                    if trade.isBuy { buyCost += quote } else { sellProceeds += quote }
                }
                let netInvested = buyCost - sellProceeds // pair units actually put in
                let pnlPair = currentValuePair - netInvested
                pnlUSD = pnlPair * pairUSD
                if netInvested > 0 { pnlPercent = pnlPair / netInvested * 100 }
            }
        }

        // Holder rewards claimable (only non-zero for fee-sharing coins).
        let rewards = (try? await env.launchpad.accountView(launch, account: address))?.pendingRewards ?? 0

        return Position(launch: launch, balance: balance, valueUSD: valueUSD, pnlUSD: pnlUSD, pnlPercent: pnlPercent, claimableRewards: rewards)
    }

    private static func feedItem(from activity: ActivityItem, launch: Launch?) -> FeedItem {
        let symbol = launch?.symbol ?? activity.token.short
        let time = Date(timeIntervalSince1970: TimeInterval(activity.time))
        let hash = activity.transactionHash
        switch activity.kind {
        case .launch:
            return FeedItem(id: hash.hexString, icon: "flame.fill", title: "Launched $\(symbol)", subtitle: launch?.name ?? "", time: time, hash: hash)
        case .trade(_, _, _, let isBuy, let quoteAmount, let tokenAmount):
            let pairDecimals = launch?.pair.decimals ?? 18
            let pairSymbol = launch?.pair.symbol ?? ""
            let subtitle = "\(NumberStyle.units(tokenAmount, decimals: 18, compact: true)) \(symbol) · \(NumberStyle.units(quoteAmount, decimals: pairDecimals, compact: true)) \(pairSymbol)"
            return FeedItem(id: hash.hexString, icon: isBuy ? "arrow.down" : "arrow.up", title: isBuy ? "Bought \(symbol)" : "Sold \(symbol)", subtitle: subtitle, time: time, hash: hash)
        case .graduated:
            return FeedItem(id: hash.hexString, icon: "checkmark.seal.fill", title: "\(symbol) graduated", subtitle: "", time: time, hash: hash)
        }
    }
}
