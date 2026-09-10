import DyorKit
import SwiftUI

/// The Strategy tab landing: "what do you want your capital to do?" Each card routes to a strategy. Copy Trading and
/// Market Making are live; Earn and Protect are planned. A banner surfaces pending copy signals waiting to confirm.
struct StrategyView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @State private var pendingCount = 0
    @State private var goCopyTrading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if pendingCount > 0 { pendingBanner }

                    StrategyCard(
                        eyebrow: "COPY OR AUTOMATE", title: "Copy Trading", symbol: "person.2.badge.gearshape",
                        tint: .brand, tags: ["Perps", "Spot", "You stay in control"],
                        detail: "Follow proven Perpl traders and top memecoin wallets. You're alerted on every trade to confirm or decline.",
                        cta: "Explore traders", status: .live
                    ) { CopyTradingView() }

                    StrategyCard(
                        eyebrow: "PROVIDE LIQUIDITY", title: "Market Making", symbol: "chart.bar.xaxis",
                        tint: .allocationSpot, tags: ["Mid", "Grid", "Earn spread"],
                        detail: "Quote both sides of a market and earn the spread as trades fill against your orders.",
                        cta: "Set up a strategy", status: .live
                    ) { MarketMakingView() }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Strategy")
            .navigationDestination(isPresented: $goCopyTrading) { CopyTradingView() }
            .task(id: session.address) { refreshPending() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refreshPending() }
            .onReceive(NotificationCenter.default.publisher(for: .copySignalsChanged)) { _ in refreshPending() }
        }
    }

    private func refreshPending() { pendingCount = CopyStore.signals(owner: session.address).count }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STRATEGIES")
                .font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text("What do you want your capital to do?")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Earn yield, follow proven traders, or provide liquidity. Choose the outcome that fits you.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var pendingBanner: some View {
        Button { goCopyTrading = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Color.brand, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(pendingCount) copy \(pendingCount == 1 ? "signal" : "signals") waiting")
                        .font(.subheadline.weight(.semibold))
                    Text("Confirm or decline copied trades").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.brand.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}

/// One strategy card: eyebrow tag, gradient icon tile, title, description, tags and a CTA. Live cards push their
/// destination; "soon" cards are inert with a Coming soon pill.
private struct StrategyCard<Destination: View>: View {
    enum Status { case live, soon }
    let eyebrow: String
    let title: String
    let symbol: String
    let tint: Color
    let tags: [String]
    let detail: String
    let cta: String
    let status: Status
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        if status == .live {
            NavigationLink { destination() } label: { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(eyebrow)
                    .font(.caption2.weight(.bold)).tracking(1).foregroundStyle(tint)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(tint.opacity(0.14), in: Capsule())
                Spacer()
                iconTile
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.bold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
            ctaRow
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .opacity(status == .soon ? 0.72 : 1)
    }

    private var iconTile: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: tint.opacity(0.35), radius: 8, y: 4)
    }

    @ViewBuilder private var ctaRow: some View {
        if status == .live {
            HStack {
                Text(cta).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            }
            .padding(.vertical, 11).padding(.horizontal, 14)
            .background(tint.opacity(0.12), in: Capsule())
        } else {
            Text(cta).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 11).frame(maxWidth: .infinity)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }
}
