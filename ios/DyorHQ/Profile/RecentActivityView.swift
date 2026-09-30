import BigInt
import DyorKit
import SwiftUI

/// A unified, in-app feed of everything the wallet does across DyorHQ — launches, curve buys/sells, swaps and perp
/// orders — newest first, each linking to its transaction on Monadscan. It merges the local action log (the only
/// source for perps, and the freshest rows) with on-chain scans that backfill launchpad and swap history.
struct RecentActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = RecentActivityModel()

    var body: some View {
        List {
            if model.items.isEmpty {
                if model.loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading activity…").foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView {
                        Label("No Activity Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Your launches, swaps, buys, sells and perp orders show up here.")
                    } actions: {
                        Button("Start Trading") { Haptics.tap(); router.presented = nil; router.tradeMode = .swap; router.tab = .trade }
                    }
                }
            } else {
                Section {
                    ForEach(model.items) { RecentActivityRow(item: $0) }
                } footer: {
                    if let address = session.address {
                        Link(destination: Monad.explorerAddress(address)) { Label("Open full history on Monadscan", systemImage: "safari") }.font(.footnote)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Recent Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(env: env, address: session.address) }
        .task(id: session.address) { await model.load(env: env, address: session.address) }
    }
}

/// One row in the feed.
struct FeedItem: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let time: Date
    let hash: Data?
}

private struct RecentActivityRow: View {
    let item: FeedItem

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
            Image(systemName: item.icon)
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.medium))
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
                if item.hash != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .contentShape(Rectangle())
    }
}

@Observable
@MainActor
final class RecentActivityModel {
    private(set) var items: [FeedItem] = []
    private(set) var loading = false

    func load(env: AppEnvironment, address: Address?) async {
        guard let address else { items = []; return }
        loading = true
        defer { loading = false }
        // Pending rows are re-checked beside the history reads, not ahead of them (each can wait on the RPC); the feed is
        // built once the history answers, and again once they are settled.
        async let rechecked: Void = PendingActivity.recheck(owner: address, rpc: env.rpc)

        let tokenMap = Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        async let launchesTask = env.launchpad.launchListing(limit: 60)
        async let swapsTask = env.swapHistory.swaps(wallet: address, window: .week, decimals: tokenMap.mapValues(\.decimals))
        let launches = await launchesTask.launches
        async let lpActivityTask = env.launchpad.activity(limit: 100, lookbackBlocks: Monad.blocksPerDay * 7, launches: launches)

        let byToken = Dictionary(launches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        let lpActivity = ((try? await lpActivityTask) ?? []).filter { $0.actor == address }
        let swaps = await swapsTask

        items = Self.merge(ActivityLog.all(owner: address), lpActivity: lpActivity, byToken: byToken, swaps: swaps, tokens: tokenMap)
        await rechecked
        items = Self.merge(ActivityLog.all(owner: address), lpActivity: lpActivity, byToken: byToken, swaps: swaps, tokens: tokenMap)
    }

    /// The feed, newest first: the actions recorded here — typed, exact, and the only source for perps — then the
    /// on-chain backfill, then the rows `PendingActivity` wrote for sent transactions, each only where nothing else has
    /// its hash: a typed backfill row ("Swapped 10 USDC → 3 MON") says more than "Swap on Uniswap v4 · Confirmed".
    private static func merge(_ records: [ActivityRecord], lpActivity: [ActivityItem], byToken: [Address: Launch], swaps: [SwapRecord],
                              tokens: [Address: Token]) -> [FeedItem] {
        var out: [FeedItem] = []
        var seen = Set<String>()
        func add(_ record: ActivityRecord, icon: String) {
            let key = record.txHashHex ?? record.id.uuidString
            guard seen.insert(key).inserted else { return }
            out.append(FeedItem(id: key, icon: icon, title: record.title, subtitle: record.subtitle, time: record.time, hash: record.txHash))
        }
        for record in records where record.status == nil { add(record, icon: record.kind.symbol) }
        // Launchpad on-chain backfill (launches, buys, sells by this wallet).
        for activity in lpActivity where seen.insert(activity.transactionHash.hexString).inserted {
            out.append(feedItem(from: activity, launch: byToken[activity.token]))
        }
        // Swap backfill for swaps made before recording or on another device.
        for swap in swaps where seen.insert(swap.hash.hexString).inserted {
            out.append(FeedItem(id: swap.hash.hexString, icon: "arrow.left.arrow.right", title: "Swapped", subtitle: SwapHistoryItem.describe(swap, tokens: tokens), time: swap.time, hash: swap.hash))
        }
        for record in records { if let status = record.status { add(record, icon: PendingActivity.symbol(for: status)) } }
        return out.sorted { $0.time > $1.time }
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
