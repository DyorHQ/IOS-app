import DyorKit
import SwiftUI

/// The launchpad profile: a creator/trader dashboard for the signed-in wallet. Shows the coins you hold (with live
/// value and on-curve PnL), the coins you launched, your claimable creator fees, and your launchpad activity — the
/// money view for the Launch section. Creator fees accrue in the fee escrow per pair asset across all your launches;
/// "Claim" sweeps them in one transaction. Nothing is shown as 0 or "none" before it is read: a figure still being read
/// is a placeholder, one that couldn't be read says so with Retry, and the last good one read for the wallet stays.
struct LaunchpadProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    /// Kept by the environment for the wallet signed in (`AppEnvironment.launchpadProfile`): the sheet opened again shows
    /// the last good state read for it at once, then reads it again.
    private var model: LaunchpadProfileModel { env.launchpadProfile }

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
            case .positions: return tr(LocalizedStringResource("Holdings", comment: "What a wallet holds: a tab of My Launchpad, a stat and a section header [tight]"))
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
                    Picker(tr(LocalizedStringResource("myLaunchpad.view", defaultValue: "View", comment: "The name VoiceOver reads for My Launchpad's switch between its tabs (Holdings, Launches, Activity): a noun")), selection: $tab) { ForEach(Tab.allCases) { Text($0.label).tag($0) } }
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
            .navigationTitle(tr("My Launchpad"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            // What was saved for the wallet when it was last read in full is in the sheet's first frame, never
            // placeholders under figures the phone has (`LaunchpadProfileModel.showSaved`): a small file on the device,
            // read here, before that frame, rather than in the load's task, which starts after it. Never animated.
            .onAppear {
                if let address = session.address {
                    withTransaction(\.disablesAnimations, true) { model.showSaved(env: env, address: address) }
                }
            }
            .task(id: session.address) { await model.load(env: env, address: session.address) }
            // The history fills in behind the screen (`HistoryModel`): the fee tiles, the holdings' profit and loss and the
            // Activity tab follow it.
            .task(id: env.history.version) { model.applyHistory(env.history.snapshot, wallet: env.history.wallet) }
            // A pull awaits the screen's own reads only: the history reads on behind it (`HistoryModel.kick`), and what
            // comes from it follows `env.history.version`. Kicked after them, so the round reads a head at or after the
            // block the balances were read at, which each holding's profit and loss waits for. The reads the screens share
            // are read again first (`invalidateChainReads`).
            .refreshable {
                env.invalidateChainReads()
                await model.load(env: env, address: session.address)
                env.history.kick(env: env)
            }
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
            // What was saved for the wallet when last read, shown while it is read again: said to be, never taken for it.
            if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
            if let incomplete = model.incomplete {
                HStack(alignment: .firstTextBaseline) {
                    InlineError(message: incomplete)
                    Spacer(minLength: 8)
                    retryButton()
                }
            }
            // Each figure a placeholder while its first read for the wallet runs, "—" when it couldn't be read: never 0.
            HStack {
                stat("Portfolio", model.portfolioReading ? PriceFormat.usdValue(0) : PriceFormat.usdValue(model.portfolioValueUSD), reading: model.portfolioReading)
                Divider().frame(height: 34)
                stat("Launched", model.launchesRead ? "\(model.launched.count)" : model.launchesUnread ? "—" : "0", reading: !model.launchesRead && !model.launchesUnread)
                Divider().frame(height: 34)
                stat("Holdings", model.holdingsCount.map { "\($0)" } ?? (model.holdingsReading ? "0" : "—"), reading: model.holdingsReading)
            }
            .padding(.vertical, 2)
        }
    }

    /// Fees: everything the wallet earned on the launchpad (Total), what reached it (Received: creator fees the escrow paid
    /// straight to it or it claimed, and holder rewards claimed) and what waits to be claimed (Claimable), each per asset
    /// with its dollar value at today's prices; then a row to claim each claimable balance, and Claim All.
    @ViewBuilder private var claimSection: some View {
        Section {
            VStack(spacing: 10) {
                feeTile(Text("Total fees", comment: "My Launchpad's full-width tile: every fee the wallet earned on the launchpad, received and claimable"), model.totalFees,
                        loading: model.feesLoading || model.claimableLoading)
                HStack(alignment: .top, spacing: 10) {
                    feeTile(Text("Received", comment: "[tight] Fees or proceeds that reached the wallet: paid straight to it, or claimed. A tile on My Launchpad and Portfolio"), model.receivedFees,
                            loading: model.feesLoading)
                    feeTile(Text("Claimable", comment: "Ready to claim, a row label before an amount (an adjective)"), model.claimableShown,
                            loading: model.claimableLoading, tint: model.hasClaimable ? .brand : .primary)
                }
                // Side by side, the two tiles share the taller one's height.
                .fixedSize(horizontal: false, vertical: true)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            // A history or an escrow that couldn't be read says so, with Retry: Total and Received are never shown in part,
            // and an escrow's balances are kept from its last read for this wallet, never "0" on a failed read. A history
            // still filling in says how far it has got.
            if model.incomeFilling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading your history… \(NumberStyle.percent(model.incomeProgress * 100, fractionDigits: 0, signed: false))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if model.incomeUnread {
                retryRow("Fees received couldn't be read just now.", history: true)
            }
            if model.feesUnread {
                retryRow("Creator fees couldn't be read just now.")
            }
            if model.rewardsUnread {
                retryRow("Holder rewards couldn't be read just now.")
            }
            // Creator fees — one row per pair asset and launchpad escrow, each claimed on its own.
            ForEach(model.creatorClaimables) { asset in
                claimRow(icon: "banknote", title: "Creator fees · \(asset.symbol)", amount: asset.amountText, usd: asset.usd, caption: asset.caption) {
                    claimTarget = .creator(asset)
                }
            }
            // Holder rewards — one row per fee-sharing coin with rewards waiting, held or not; one kept from an earlier
            // read says so.
            ForEach(model.rewardClaimables) { reward in
                claimRow(icon: "gift", title: "\(reward.launch.symbol) rewards", amount: reward.amountText, usd: nil, caption: reward.current ? nil : tr("As last read")) {
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
        } header: {
            Text("Fees")
        } footer: {
            // True on every stack: from v1 the escrow pays fees straight to the wallet; before v1 it holds them to claim. A
            // graduated pool's creator fees wait in the hook until a sweep credits them to the escrow.
            Paragraph("Received: creator fees paid straight to your wallet, and the fees and rewards you claimed. Claimable: creator fees held in the fee escrow, and holder rewards. Creator fees from a graduated pool show here once they're swept. Dollar values are at today's prices.")
        }
    }

    /// `history`: the retry reads the wallet's history on as well (`HistoryModel.kick`), after the screen's own reads.
    private func retryRow(_ message: LocalizedStringResource, history: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineError(message: message)
            Spacer(minLength: 8)
            retryButton(history: history)
        }
    }

    private func retryButton(history: Bool = false) -> some View {
        Button("Retry") {
            Task {
                await model.load(env: env, address: session.address)
                if history { env.history.kick(env: env) }
            }
        }
        .font(.footnote.weight(.semibold))
    }

    /// How far the launchpad scan of the wallet's history has got, while what a section shows waits for it.
    private func historyProgressRow(_ progress: Double) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Reading your history… \(NumberStyle.percent(progress * 100, fractionDigits: 0, signed: false))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// A section's first read for the wallet, under way.
    private func loadingRow(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// One fee tile: its title, the amount in each asset (MON first), and their dollar value. `amounts` nil: a spinner
    /// while the first read runs (`loading`), "—" when it couldn't be read; empty: none ("0 MON").
    private func feeTile(_ title: Text, _ amounts: [LaunchpadProfileModel.FeeAmount]?, loading: Bool, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            if loading {
                ProgressView().controlSize(.small).padding(.vertical, 2)
            } else if let amounts {
                if amounts.isEmpty {
                    Text(verbatim: "0 MON").font(.headline).monospacedDigit()
                } else {
                    ForEach(amounts) { fee in
                        Text(verbatim: fee.text).font(.headline).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                if let usd = model.feeUSD(amounts), !amounts.isEmpty {
                    Text(verbatim: PriceFormat.usdValue(usd)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else {
                Text(verbatim: "—").font(.headline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func claimRow(icon: String, title: LocalizedStringKey, amount: String, usd: Double?, caption: String? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.subheadline.weight(.semibold)).frame(width: 30, height: 30)
                .background(Color.brand.opacity(0.14), in: Circle()).foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(verbatim: amount + (usd.map { " · \(PriceFormat.usdValue($0))" } ?? "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let caption { Paragraph(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button("Claim", action: action).buttonStyle(.bordered).controlSize(.small).tint(.brand).disabled(!session.canSign)
        }
    }

    /// `reading`: its first read for the wallet is under way, so `value` is only the shape of one (a placeholder, which
    /// VoiceOver reads as loading: `unreadFigure`).
    private func stat(_ label: LocalizedStringKey, _ value: String, reading: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .unreadFigure(reading)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Positions

    /// The coins held, at once after the one balance read; "No launch coins held" only once every launchpad's launches and
    /// every balance were read. While the first read runs, a loading row; when it couldn't be read, an error with Retry,
    /// under the last good holdings when there are any. A profit and loss still being read from the history is a
    /// placeholder, with how far it has got.
    @ViewBuilder private var positionsSection: some View {
        Section {
            if let positions = model.positions {
                if positions.isEmpty {
                    if !model.holdingsMissing && model.launchesRead { emptyRow("No launch coins held", "Buy a coin on the curve and it appears here with its PnL.") }
                } else {
                    ForEach(positions) { position in
                        Button { open(position.launch) } label: { PositionRow(position: position, valuing: model.valuing) }.buttonStyle(.plain)
                    }
                }
                if model.holdingsUnread {
                    if model.holdingsMissing && positions.isEmpty {
                        retryRow("Your balances couldn't be read. Check your connection and try again.")
                    } else {
                        retryRow("Your balances couldn't be read just now — showing the last ones read.")
                    }
                } else if model.launchesUnread && positions.isEmpty {
                    // A launchpad whose launches were never read may hold the wallet's coins: never "none held".
                    retryRow("Your launch coins couldn't be read just now.")
                }
                if model.pnlReading {
                    historyProgressRow(model.pnlProgress)
                } else if model.pnlUnread {
                    retryRow("Part of your history couldn't be read just now, so some figures may be missing. Pull to refresh.", history: true)
                }
            } else if model.holdingsUnread {
                retryRow("Your balances couldn't be read. Check your connection and try again.")
            } else {
                loadingRow("Reading your balances…")
            }
        } header: { Text("Holdings") }
    }

    // MARK: Launches

    @ViewBuilder private var launchesSection: some View {
        Section {
            if !model.launched.isEmpty {
                ForEach(model.launched) { item in
                    Button { open(item.launch) } label: { CreatedRow(item: item) }.buttonStyle(.plain)
                }
            } else if model.launchesRead {
                emptyRow("No coins launched", "Launch a coin and it shows here with its market cap and performance.")
            } else if model.launchesUnread {
                retryRow("The coins you launched couldn't be read just now.")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        } header: { Text("Coins You Launched") }
    }

    // MARK: Activity

    /// The wallet's own buys and sells, from its history, and the coins it launched, newest first; while the history is
    /// still reading them, what it has read so far with how far it has got, never "No launchpad activity".
    @ViewBuilder private var activitySection: some View {
        Section {
            ForEach(model.activity) { entry in
                if let hash = entry.item.hash {
                    Link(destination: Monad.explorerTransaction(hash)) { LaunchpadActivityRow(item: entry.item) }.foregroundStyle(.primary)
                } else if let launch = entry.launch {
                    Button { open(launch) } label: { LaunchpadActivityRow(item: entry.item) }.buttonStyle(.plain)
                } else {
                    LaunchpadActivityRow(item: entry.item)
                }
            }
            switch model.activityCoverage {
            case .complete:
                if model.activity.isEmpty { emptyRow("No launchpad activity", "Your buys, sells and launches show here.") }
            case .reading:
                historyProgressRow(model.activityProgress)
            case .unread:
                retryRow("Part of your history couldn't be read just now, so some activity may be missing. Pull to refresh.", history: true)
            }
        } header: { Text("Your Launchpad Activity") }
    }

    private func emptyRow(_ title: LocalizedStringKey, _ detail: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Paragraph(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// A coin's page. While the launches on screen are those saved when the wallet was last read
    /// (`LaunchpadProfileModel.launchesSaved`), by reference, so the page reads it now: a launch page shows the launch it
    /// is given as current — its price, its phase, which trades are open.
    private func open(_ launch: Launch) {
        dismiss()
        if model.launchesSaved {
            router.openLaunch(LaunchReference(token: launch.token, factory: launch.factory))
        } else {
            router.openLaunch(launch)
        }
    }

    @ViewBuilder private func claimSheet(for target: ClaimTarget) -> some View {
        switch target {
        case .creator(let asset):
            ConfirmationSheet(
                title: "Claim \(asset.symbol) Fees", confirmTitle: "Claim \(asset.symbol)",
                build: { await env.launchpad.claimEscrowPlan(native: asset.isNative, tokens: asset.isNative ? [] : [asset.token], escrow: asset.escrow) },
                onDone: { Task { await model.load(env: env, address: session.address) } },
                onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .fees, title: tr("Collected \(asset.symbol) creator fees"), subtitle: asset.current ? asset.amountText : "", hash: hash, section: "launch"), owner: session.address)
                    model.claimed([asset], for: session.address)
                    // The claim is in the history in seconds, not at the next top-up: Received counts it.
                    env.history.kick(env: env)
                }
            ) {
                // A balance kept from an earlier read says so: the claim withdraws whatever the escrow holds now.
                DetailRow(asset.current ? "Creator fees" : "Creator fees (as last read)", asset.amountText)
                DetailRow("To", session.address?.short ?? "—")
            }
        case .rewards(let reward):
            ConfirmationSheet(
                title: "Claim \(reward.launch.symbol) Rewards", confirmTitle: "Claim",
                build: { await env.launchpad.claimRewardsPlan(launch: reward.launch, view: nil) },
                onDone: { Task { await model.load(env: env, address: session.address) } },
                onCompleted: { hash in
                    Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed \(reward.launch.symbol) rewards"), subtitle: reward.amountText, hash: hash, section: "launch"), owner: session.address)
                    model.claimedRewards([reward.launch.token], for: session.address)
                    env.history.kick(env: env)
                }
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
                    model.claimedRewards(model.claimAllRewardClaimables.map(\.launch.token), for: session.address)
                    env.history.kick(env: env)
                }
            ) {
                ForEach(model.claimAllCreatorClaimables) { asset in DetailRow(asset.retired ? "Creator · \(asset.symbol) (retired launchpad)" : "Creator · \(asset.symbol)", asset.amountText) }
                ForEach(model.claimAllRewardClaimables) { reward in DetailRow("\(reward.launch.symbol) rewards", reward.amountText) }
            }
        }
    }
}

// MARK: - Rows

private struct PositionRow: View {
    let position: LaunchpadProfileModel.Position
    /// The first price read for the wallet is under way: a value not known yet is a placeholder, not "—".
    let valuing: Bool

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: position.launch.symbol, logo: position.launch.logo, pointSize: 36)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(position.launch.symbol).font(.subheadline.weight(.semibold))
                Text("\(NumberStyle.units(position.balance, decimals: 18, compact: true)) · MC \(position.mcapText)", comment: "Coins held, then the coin's market cap (MC) [tight]")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                if let rewards = position.claimableRewards, rewards > 0 {
                    Text("Rewards: \(NumberStyle.units(rewards, decimals: position.launch.pair.decimals, compact: true)) \(position.launch.pair.symbol)")
                        .font(.caption2).foregroundStyle(Color.brand)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                let pricing = position.valueUSD == nil && valuing
                Text(PriceFormat.usdValue(pricing ? 0 : position.valueUSD)).font(.subheadline.weight(.medium)).monospacedDigit()
                    .unreadFigure(pricing)
                switch position.pnl {
                case .value(let pnl):
                    Text(verbatim: "\(PriceFormat.usdValue(pnl.usd, signed: true))\(pnl.percent.map { " (\($0 >= 0 ? "+" : "")\(NumberStyle.number($0, maximumFractionDigits: 1))%)" } ?? "")")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(pnl.usd >= 0 ? Color.positive : Color.negative)
                case .reading, .pricing:
                    // Still being read from the history, or valued: the shape of a figure, never a partial one, and read by
                    // VoiceOver as loading, never as "+$0.00".
                    Text(verbatim: PriceFormat.usdValue(0, signed: true)).font(.caption2).monospacedDigit().unreadFigure(true)
                case .unread, .unavailable:
                    EmptyView()
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

/// One Activity row; the section wraps it in what it opens (a fill's transaction, a launched coin's page).
private struct LaunchpadActivityRow: View {
    let item: FeedItem

    var body: some View {
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
