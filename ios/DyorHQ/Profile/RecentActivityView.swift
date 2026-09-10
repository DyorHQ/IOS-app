import BigInt
import DyorKit
import SwiftUI

/// A unified, in-app feed of everything the wallet does across DyorHQ — launches, curve buys/sells, swaps and perp
/// orders — newest first, each linking to its transaction on Monadscan. It merges the local action log (the only
/// source for perps, and the freshest rows) with on-chain scans that backfill launchpad and swap history.
struct RecentActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @State private var model = RecentActivityModel()

    var body: some View {
        List {
            if model.items.isEmpty {
                if model.loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading activity…").foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView("No Activity Yet", systemImage: "clock.arrow.circlepath", description: Text("Your launches, swaps, buys, sells and perp orders show up here."))
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

        let tokenMap = Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        async let launchesTask = env.launchpad.launches(limit: 60)
        async let swapsTask = env.swapHistory.swaps(wallet: address, window: .week, decimals: tokenMap.mapValues(\.decimals))
        let launches = (try? await launchesTask) ?? []
        async let lpActivityTask = env.launchpad.activity(limit: 100, lookbackBlocks: Monad.blocksPerDay * 7, launches: launches)

        let byToken = Dictionary(launches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        let lpActivity = ((try? await lpActivityTask) ?? []).filter { $0.actor == address }
        let swaps = await swapsTask

        var out: [FeedItem] = []
        var seen = Set<String>()

        // Local records first — typed, exact, and the only source for perps.
        for record in ActivityLog.all(owner: address) {
            let key = record.txHashHex ?? record.id.uuidString
            guard seen.insert(key).inserted else { continue }
            out.append(FeedItem(id: key, icon: record.kind.symbol, title: record.title, subtitle: record.subtitle, time: record.time, hash: record.txHash))
        }
        // Launchpad on-chain backfill (launches, buys, sells by this wallet).
        for activity in lpActivity where seen.insert(activity.transactionHash.hexString).inserted {
            out.append(Self.feedItem(from: activity, launch: byToken[activity.token]))
        }
        // Swap backfill for swaps made before recording or on another device.
        for swap in swaps where seen.insert(swap.hash.hexString).inserted {
            out.append(FeedItem(id: swap.hash.hexString, icon: "arrow.left.arrow.right", title: "Swapped", subtitle: SwapHistoryItem.describe(swap, tokens: tokenMap), time: swap.time, hash: swap.hash))
        }

        items = out.sorted { $0.time > $1.time }
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
