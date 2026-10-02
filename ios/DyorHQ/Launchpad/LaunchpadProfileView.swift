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
        social.profile?.display_name ?? session.account?.label ?? session.address?.short ?? tr("My Launchpad")
    }
    private var initials: String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? session.account?.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
    private var subtitle: String {
        if let handle = social.profile?.handle { return "@\(handle)" }
        if let method = session.account?.method { return method == .watchOnly ? tr("Watching this address") : tr("Signed in with \(method.title)") }
        return tr("Launchpad profile")
    }
    @State private var tab: Tab = .positions
    @State private var claimTarget: ClaimTarget?

    private enum Tab: String, CaseIterable, Identifiable { case positions, launches, activity
        var id: String { rawValue }
        var label: String {
            switch self {
            case .positions: return tr(LocalizedStringResource("Holdings", comment: "My Launchpad tab: the launch coins held [tight]"))
            case .launches: return tr(LocalizedStringResource("Launches", comment: "My Launchpad tab: the coins this wallet launched [tight]"))
            case .activity: return tr(LocalizedStringResource("Activity", comment: "My Launchpad tab: this wallet's launchpad trades and launches [tight]"))
            }
        }
    }

    /// What a claim action withdraws: one creator-fee asset, one coin's holder rewards, or everything at once.
    private enum ClaimTarget: Identifiable {
        case creator(LaunchpadProfileModel.ClaimableAsset)
        case rewards(LaunchpadProfileModel.RewardClaim)
        case all
        var id: String {
            switch self {
            case .creator(let a): return "creator-\(a.id)"
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
            if let incomplete = model.incomplete { InlineError(message: incomplete) }
            HStack {
                stat("Portfolio", PriceFormat.usdValue(model.portfolioValueUSD))
                Divider().frame(height: 34)
                stat("Launched", "\(model.launched.count)")
                Divider().frame(height: 34)
                stat("Holdings", "\(model.positions.count)")
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var claimSection: some View {
        Section {
            // An escrow that couldn't be read says so, with Retry, and keeps its last balances read for this wallet: never
            // "Nothing to claim yet" on a failed read.
            if model.feesUnread {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: "Creator fees couldn't be read just now.")
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await model.load(env: env, address: session.address) } }.font(.footnote.weight(.semibold))
                }
            }
            if !model.hasClaimable {
                if !model.feesUnread { Text("Nothing to claim yet.").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                // Creator fees — one row per pair asset and launchpad escrow, each claimed on its own.
                ForEach(model.creatorClaimables) { asset in
                    claimRow(icon: "banknote", title: "Creator fees · \(asset.symbol)", amount: asset.amountText, usd: asset.usd, caption: asset.caption) {
                        claimTarget = .creator(asset)
                    }
                }
                // Holder rewards — one row per fee-sharing coin held.
                ForEach(model.rewardClaimables) { reward in
                    claimRow(icon: "gift", title: "\(reward.launch.symbol) rewards", amount: reward.amountText, usd: nil) {
                        claimTarget = .rewards(reward)
                    }
                }
                if session.canSign, model.claimAllCount > 1 {
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
            Text("Creator fees accrue per pair asset. Claim each one, or Claim All.")
        }
    }

    private func claimRow(icon: String, title: LocalizedStringKey, amount: String, usd: Double?, caption: String? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).frame(width: 30, height: 30)
                .background(Color.brand.opacity(0.14), in: Circle()).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(verbatim: amount + (usd.map { " · \(PriceFormat.usdValue($0))" } ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button("Claim", action: action).buttonStyle(.bordered).controlSize(.small).tint(.brand).disabled(!session.canSign)
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
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
            if model.launched.isEmpty {
                emptyRow("No coins launched", "Launch a coin and it shows here with its market cap and performance.")
            } else {
                ForEach(model.launched) { item in
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

    private func emptyRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
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
                build: { env.launchpad.claimEscrowPlan(native: asset.isNative, tokens: asset.isNative ? [] : [asset.token], escrow: asset.escrow) },
                onDone: { Task { await model.load(env: env, address: session.address) } },
                onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .fees, title: tr("Collected \(asset.symbol) creator fees"), subtitle: asset.current ? asset.amountText : "", hash: hash, section: "launch"), owner: session.address)
                    model.claimed([asset], for: session.address)
                }
            ) {
                // A balance kept from an earlier read says so: the claim withdraws whatever the escrow holds now.
                DetailRow(asset.current ? "Creator fees" : "Creator fees (as last read)", asset.amountText)
                DetailRow("To", session.address?.short ?? "—")
            }
        case .rewards(let reward):
            ConfirmationSheet(
                title: "Claim \(reward.launch.symbol) Rewards", confirmTitle: "Claim",
                build: { env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) },
                onDone: { Task { await model.load(env: env, address: session.address) } },
                onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed \(reward.launch.symbol) rewards"), subtitle: reward.amountText, hash: hash, section: "launch"), owner: session.address) }
            ) {
                DetailRow("Holder rewards", reward.amountText)
                DetailRow("To", session.address?.short ?? "—")
            }
        case .all:
            ConfirmationSheet(
                title: "Claim All Fees", confirmTitle: "Claim All",
                build: { await model.claimAllPlan(env: env) },
                onDone: { Task { await model.load(env: env, address: session.address) } },
                onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .fees, title: tr("Claimed all Launch earnings"), subtitle: tr("\(model.claimAllCount) claims · fees and rewards"), hash: hash, section: "launch"), owner: session.address)
                    model.claimed(model.claimAllCreatorClaimables, for: session.address)
                }
            ) {
                ForEach(model.claimAllCreatorClaimables) { asset in DetailRow(asset.retired ? "Creator · \(asset.symbol) (retired launchpad)" : "Creator · \(asset.symbol)", asset.amountText) }
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
            LaunchArtwork(symbol: position.launch.symbol, logo: position.launch.logo, pointSize: 36)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(position.launch.symbol).font(.subheadline.weight(.semibold))
                Text("\(NumberStyle.units(position.balance, decimals: 18, compact: true)) · MC \(position.mcapText)", comment: "Coins held, then the coin's market cap (MC) [tight]")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                if position.claimableRewards > 0 {
                    Text("Rewards: \(NumberStyle.units(position.claimableRewards, decimals: position.launch.pair.decimals, compact: true)) \(position.launch.pair.symbol)")
                        .font(.caption2).foregroundStyle(Color.brand)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.usdValue(position.valueUSD)).font(.subheadline.weight(.medium)).monospacedDigit()
                if let pnlUSD = position.pnlUSD {
                    Text(verbatim: "\(PriceFormat.usdValue(pnlUSD, signed: true))\(position.pnlPercent.map { " (\($0 >= 0 ? "+" : ""))\(NumberStyle.number($0, maximumFractionDigits: 1))%)" } ?? "")")
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
            LaunchArtwork(symbol: item.launch.symbol, logo: item.launch.logo, pointSize: 36)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.launch.symbol).font(.subheadline.weight(.semibold))
                    Text(item.launch.holderFeeSharing ? "Shares fees" : "Creator fees").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
                }
                (item.launch.phase == .bonding ? Text("\(item.launch.progressBps / 100)% to graduation") : Text(verbatim: item.launch.phase.title))
                    .font(.caption2).foregroundStyle(item.launch.phase == .graduated ? Color.positive : .secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: item.mcapUSD.map { PriceFormat.usdValue($0) } ?? item.launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(item.launch.pair.symbol)" } ?? "—")
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
        /// At the coin's decimal price (`Launch.pairPrice`); nil when it or the pair asset's dollar price isn't known.
        let valueUSD: Double?
        let pnlUSD: Double?
        let pnlPercent: Double?
        let claimableRewards: BigUInt
        var id: Address { launch.token }
        var mcapText: String { launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—" }
    }

    struct Created: Identifiable, Hashable {
        let launch: Launch
        let mcapUSD: Double?
        var id: Address { launch.token }
    }

    /// One launchpad stack's fee escrow and what the wallet can claim from it. Each stack (the live one and every
    /// retired one) keeps its own escrow, so creator fees are claimed per escrow.
    struct EscrowHolding: Hashable {
        let escrow: Address
        let retired: Bool
        let balances: EscrowBalances
        /// Read in the latest load. False: that read failed, and these are the balances last read for the same wallet
        /// (`LaunchpadEscrowRead.keeping`), shown until a read succeeds but never claimed by Claim All.
        let current: Bool
    }

    private(set) var positions: [Position] = []
    /// Every coin the wallet created, on every stack.
    private(set) var created: [Created] = []
    /// The coins it created that "Coins You Launched" shows: those the board lists (`Launch.listsOnBoard`). A retired
    /// launchpad's sell-only coin is left out (owner decision 2026-09-29), still under Holdings while held, and its
    /// creator fees are still read: every stack's escrow, in every pair asset (`LaunchpadService.escrowReads`).
    var launched: [Created] { created.filter(\.launch.listsOnBoard) }
    /// The live stack's escrow first, then the retired stacks'.
    private(set) var escrows: [EscrowHolding] = []
    private(set) var activity: [FeedItem] = []
    private(set) var loading = false
    /// Said when part of the launchpad couldn't be read: the holdings, launches and fees shown may be missing some.
    private(set) var incomplete: String?
    /// The last launches read, which a launchpad that can't be read now keeps (`LaunchListing.keeping`).
    private var lastLaunches: [Launch] = []
    /// Some escrow couldn't be read in the latest load: the claim section says so, with Retry, and never says there is
    /// nothing to claim.
    private(set) var feesUnread = false
    /// The escrows as last kept (`LaunchpadEscrowRead.keeping`), and the wallet they were read for: an escrow whose read
    /// fails keeps its balances only for that same wallet, never another's.
    private var lastEscrowReads: [LaunchpadEscrowRead] = []
    private var escrowsFor: Address?
    /// The wallet whose coins, fees and activity are on screen: another wallet starts from nothing.
    private var shownFor: Address?
    /// Counts loads: only the newest one publishes what it read, so a slower load (for a wallet no longer shown, or a
    /// Retry overtaken by a pull to refresh) never overwrites a newer one.
    private var loads = 0

    // Pair asset → USD price, and pair asset → (symbol, decimals) for escrow display.
    private var pairUSD: [Address: Double] = [:]
    private var pairMeta: [Address: (symbol: String, decimals: Int)] = [:]

    /// One claimable creator-fee balance, in a single pair asset (native MON is `token == .zero`) of one escrow.
    /// Claimed on its own so the user always knows which asset they're withdrawing.
    struct ClaimableAsset: Identifiable, Hashable {
        let escrow: Address
        let retired: Bool
        let token: Address
        let symbol: String
        let amount: BigUInt
        let decimals: Int
        let usd: Double
        /// Read in the latest load (`EscrowHolding.current`).
        let current: Bool
        var id: String { "\(escrow.hex)-\(token.hex)" }
        var isNative: Bool { token.isZero }
        var amountText: String { "\(NumberStyle.units(amount, decimals: decimals, compact: true)) \(symbol)" }
        /// Under the row: a retired launchpad's escrow, and balances kept from an earlier read.
        var caption: String? {
            let parts = [retired ? tr("Retired launchpad") : nil, current ? nil : tr("As last read")].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// One coin's claimable holder rewards (fee-sharing coins), in that coin's pair asset.
    struct RewardClaim: Identifiable, Hashable {
        let launch: Launch
        let amount: BigUInt
        var id: Address { launch.token }
        var amountText: String { "\(NumberStyle.units(amount, decimals: launch.pair.decimals, compact: true)) \(launch.pair.symbol)" }
    }

    var isEmpty: Bool { positions.isEmpty && launched.isEmpty && activity.isEmpty }
    var portfolioValueUSD: Double { positions.reduce(0) { $0 + ($1.valueUSD ?? 0) } }

    /// Creator fees claimable, one entry per escrow and pair asset (MON first, then each token), largest first.
    var creatorClaimables: [ClaimableAsset] {
        var out: [ClaimableAsset] = []
        for holding in escrows {
            let escrow = holding.balances
            if escrow.native > 0 {
                out.append(ClaimableAsset(escrow: holding.escrow, retired: holding.retired, token: .zero, symbol: "MON", amount: escrow.native, decimals: 18, usd: Amount.units(escrow.native, decimals: 18) * (pairUSD[Monad.native] ?? 0), current: holding.current))
            }
            for (token, amount) in escrow.tokens where amount > 0 {
                let meta = pairMeta[token] ?? ("", 18)
                out.append(ClaimableAsset(escrow: holding.escrow, retired: holding.retired, token: token, symbol: meta.symbol, amount: amount, decimals: meta.decimals, usd: Amount.units(amount, decimals: meta.decimals) * (pairUSD[token] ?? 0), current: holding.current))
            }
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
    /// The creator fees Claim All claims: those read in the latest load, never balances kept from an earlier one.
    var claimAllCreatorClaimables: [ClaimableAsset] { creatorClaimables.filter(\.current) }
    var claimAllCount: Int { claimAllCreatorClaimables.count + rewardClaimables.count }

    var claimableSummary: String {
        guard hasClaimable else { return feesUnread ? tr("Creator fees couldn't be read") : tr("Nothing to claim yet") }
        if totalClaimableUSD > 0 { return PriceFormat.usdValue(totalClaimableUSD) }
        return tr("\(claimableCount) to claim")
    }

    /// Claims everything at once: every escrow read in the latest load, across every asset, plus every coin's holder
    /// rewards (each on its launch's own stack).
    func claimAllPlan(env: AppEnvironment) async -> [TransactionStep] {
        var steps: [TransactionStep] = []
        for holding in escrows where holding.current && !holding.balances.isEmpty {
            steps += await env.launchpad.claimEscrowPlan(native: holding.balances.hasNative, tokens: holding.balances.claimableTokens, escrow: holding.escrow)
        }
        for reward in rewardClaimables { steps += await env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) }
        return steps
    }

    /// The escrows the claim section lists: every one read or kept, marked current when read in the latest load.
    private static func holdings(_ reads: [LaunchpadEscrowRead]) -> [EscrowHolding] {
        reads.compactMap { read in read.balances.map { EscrowHolding(escrow: read.escrow, retired: read.retired, balances: $0, current: !read.kept) } }
    }

    /// Forgets balances just claimed (`LaunchpadEscrowRead.claimed`): the reload after a claim whose escrow read fails
    /// keeps what is left, never the amount already withdrawn.
    func claimed(_ assets: [ClaimableAsset], for address: Address?) {
        guard let address, escrowsFor == address else { return }
        for asset in assets { lastEscrowReads = LaunchpadEscrowRead.claimed(asset.token, escrow: asset.escrow, in: lastEscrowReads) }
        escrows = Self.holdings(lastEscrowReads)
    }

    func load(env: AppEnvironment, address: Address?) async {
        // The retired stacks keep serving the wallet's coins and fees while the live (v2) stack is pending.
        loads += 1
        let load = loads
        // Whether this load may still publish: it is the newest, and not cancelled (the sheet closed mid-load; reads cut
        // short that way aren't failures to show).
        func current() -> Bool { load == loads && !Task.isCancelled }
        guard let address else {
            positions = []; created = []; escrows = []; activity = []; incomplete = nil; shownFor = nil
            lastEscrowReads = []; escrowsFor = nil; feesUnread = false; loading = false
            return
        }
        // Another wallet's coins, rewards, fees and activity never show while this one's load, or a failed read, is under
        // way.
        if shownFor != address {
            positions = []; created = []; activity = []; incomplete = nil
            escrows = []; lastEscrowReads = []; escrowsFor = nil; feesUnread = false
            shownFor = address
        }
        loading = true
        defer { if load == loads { loading = false } }

        let listing = await env.launchpad.launchListing(limit: 100)
        guard current() else { return }
        let launches = listing.keeping(lastLaunches)
        lastLaunches = launches
        var unread = !listing.complete

        // Escrow (claimable creator fees): every stack's escrow, for MON and every pair asset a launch can use, whether or
        // not the coins you created are among the launches read (`escrowReads`). A failed read says so, never zero, and
        // keeps the balances last read for this wallet (marked, and left out of Claim All).
        let createdPairs = launches.filter { $0.deployer == address }.map(\.pairToken)
        let escrowReads = await env.launchpad.escrowReads(account: address, extraPairTokens: createdPairs)
        guard current() else { return }
        let kept = LaunchpadEscrowRead.keeping(escrowReads, previous: escrowsFor == address ? lastEscrowReads : [])
        lastEscrowReads = kept
        escrowsFor = address
        escrows = Self.holdings(kept)
        feesUnread = escrowReads.contains(where: { $0.balances == nil })
        if escrowReads.contains(where: { $0.balances == nil }) { unread = true }

        // Pair-asset prices (MON priced live; USDC/AUSD pinned to 1 by the price service), for the launches' pairs and
        // every pair asset an escrow can hold.
        let pairTokens = Set(launches.map(\.pairToken)).union(Token.launchpadPairAssets).union([Monad.native])
        let priceTokens = pairTokens.map { addr -> Token in
            if let launch = launches.first(where: { $0.pairToken == addr }) {
                return Token(address: addr, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
            }
            return Token.core(addr) ?? Token(address: addr, symbol: "", name: "", decimals: 18)
        }
        let priceMap = (try? await env.prices.prices(for: priceTokens)) ?? [:]
        guard current() else { return }
        pairUSD = Dictionary(uniqueKeysWithValues: pairTokens.map { ($0, priceMap[$0]?.usd ?? ($0.isZero ? (priceMap[Monad.native]?.usd ?? 0) : 0)) })
        // Multiple launches share a pair asset (MON / USDC / AUSD), so keys repeat — dedupe instead of
        // Dictionary(uniqueKeysWithValues:), which traps on the first duplicate key and crashed this screen. A pair asset
        // no launch read uses takes its symbol and decimals from the curated list.
        pairMeta = Dictionary(launches.map { ($0.pairToken, ($0.pair.symbol, $0.pair.decimals)) }, uniquingKeysWith: { first, _ in first })
        for token in Token.launchpadPairAssets where pairMeta[token] == nil {
            if let core = Token.core(token) { pairMeta[token] = (core.symbol, core.decimals) }
        }
        incomplete = unread ? tr("Part of your launchpad couldn't be read just now, so some coins or fees may be missing. Pull to refresh.") : nil
        guard !launches.isEmpty else { positions = []; created = []; activity = []; return }

        // Balances across every launch token in one multicall.
        let tokens = launches.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        let balances = (try? await ERC20.balances(of: tokens, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:]
        guard current() else { return }

        // Coins you created.
        created = launches.filter { $0.deployer == address }.map { launch in
            let usd = launch.marketCapInPair.flatMap { cap in DyorPrice.valid(pairUSD[launch.pairToken]).map { cap * $0 } }
            return Created(launch: launch, mcapUSD: usd)
        }
        .sorted { ($0.mcapUSD ?? 0) > ($1.mcapUSD ?? 0) }

        // Held coins → position with on-curve PnL and holder rewards, computed concurrently.
        let held = launches.filter { (balances[$0.token] ?? 0) > 0 }
        let usdByPair = pairUSD
        let heldPositions = await withTaskGroup(of: Position?.self) { group in
            for launch in held {
                let balance = balances[launch.token] ?? 0
                let price = usdByPair[launch.pairToken] ?? 0
                group.addTask { await Self.position(env: env, address: address, launch: launch, balance: balance, pairUSD: price) }
            }
            var out: [Position] = []
            for await p in group { if let p { out.append(p) } }
            return out.sorted { ($0.valueUSD ?? 0) > ($1.valueUSD ?? 0) }
        }
        guard current() else { return }
        positions = heldPositions

        // Your launchpad activity.
        let lpActivity = ((try? await env.launchpad.activity(limit: 60, lookbackBlocks: LaunchpadService.recentActivityBlocks, launches: launches)) ?? []).filter { $0.actor == address }
        guard current() else { return }
        let byToken = Dictionary(launches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        activity = lpActivity.map { Self.feedItem(from: $0, launch: byToken[$0.token]) }
    }

    /// One held-coin position: current value, holder rewards, and PnL from the wallet's own curve trades
    /// (net MON invested vs current value, realized + unrealized), scanning only since the coin launched.
    private static func position(env: AppEnvironment, address: Address, launch: Launch, balance: BigUInt, pairUSD: Double) async -> Position? {
        // At its decimal price, never the integer `Launch.price`: unvalued (and no P&L) when that price wasn't read.
        let currentValuePair = launch.pairPrice.map { Amount.units(balance, decimals: 18) * $0 }
        let valueUSD = DyorPrice.launch(launch, spot: nil, pairUSD: pairUSD).map { Amount.units(balance, decimals: 18) * $0 }

        // Bound the trade scan to the coin's age (plus a buffer), capped at 30 days, so PnL uses the full history
        // without sweeping a month of blocks for a coin launched an hour ago.
        let lookback = await env.launchpad.tradeLookback(launchedAt: launch.launchedAt)
        var pnlUSD: Double?
        var pnlPercent: Double?
        if let currentValuePair, let trades = try? await env.launchpad.trades(curve: launch.curve, pair: launch.pair, lookbackBlocks: lookback) {
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
            return FeedItem(id: hash.hexString, icon: "flame.fill", title: tr("Launched $\(symbol)"), subtitle: launch?.name ?? "", time: time, hash: hash)
        case .trade(_, _, _, let isBuy, let quoteAmount, let tokenAmount):
            let pairDecimals = launch?.pair.decimals ?? 18
            let pairSymbol = launch?.pair.symbol ?? ""
            let subtitle = "\(NumberStyle.units(tokenAmount, decimals: 18, compact: true)) \(symbol) · \(NumberStyle.units(quoteAmount, decimals: pairDecimals, compact: true)) \(pairSymbol)"
            return FeedItem(id: hash.hexString, icon: isBuy ? "arrow.down" : "arrow.up", title: isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)"), subtitle: subtitle, time: time, hash: hash)
        case .graduated:
            return FeedItem(id: hash.hexString, icon: "checkmark.seal.fill", title: tr("\(symbol) graduated"), subtitle: "", time: time, hash: hash)
        }
    }
}
