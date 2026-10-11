import Charts
import DyorKit
import SwiftUI

// The rows and tiles Home's cards are made of: the quick actions, the allocation ring, Top Tokens and My Holdings.

/// One of the four home actions: an SF Symbol over a label, filling its share of the row.
struct HomeAction: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    /// One height for every symbol, so the four tiles and their labels line up: Transfer's arrows stand taller.
    @ScaledMetric(relativeTo: .body) private var symbolHeight: CGFloat = 24

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.body.weight(.semibold)).frame(height: symbolHeight)
                Text(title).font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}

/// The allocation ring: a donut of the value split with a centered total and a legend of shares.
struct AllocationDonut: View {
    struct Segment: Identifiable {
        let label: String
        let value: Double
        let color: Color
        var id: String { label }
    }

    let segments: [Segment]
    let total: Double

    private var hasValue: Bool { total > 0 && segments.contains { $0.value > 0 } }

    var body: some View {
        HStack(spacing: 20) {
            Chart(hasValue ? segments : placeholder) { segment in
                SectorMark(angle: .value("Value", segment.value), innerRadius: .ratio(0.66), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(segment.color)
            }
            .chartLegend(.hidden)
            .frame(width: 128, height: 128)
            .overlay {
                VStack(spacing: 1) {
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                    Text(PriceFormat.usdValue(total)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 9, height: 9)
                        Text(segment.label).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(NumberStyle.percent(hasValue ? segment.value / total * 100 : 0, fractionDigits: 1, signed: false))
                            .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var placeholder: [Segment] {
        segments.map { Segment(label: $0.label, value: 1, color: $0.color.opacity(0.28)) }
    }
}

/// A ranked market row for the Top Tokens list.
struct TokenListRow: View {
    let rank: Int
    let row: MarketRow
    /// The rank column's width (`HomeView.rankWidth`).
    let rankWidth: CGFloat

    private static let spacing: CGFloat = 12
    private static let logoSize: CGFloat = 34

    /// Where the row's text starts, for the divider under it: rank, gap, logo, gap (74 pt at the default text size).
    static func textInset(rankWidth: CGFloat) -> CGFloat { rankWidth + spacing + logoSize + spacing }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(verbatim: "\(rank)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary).frame(width: rankWidth, alignment: .center)
            TokenLogo(token: row.token, size: Self.logoSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    // Top Tokens lists no token the wallet was sent unasked (`HomeModel.topTokens`).
                    TokenBadgeView(token: row.token, receivedUnasked: false)
                }
                Text(row.token.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            USDText(price: row.usd, font: .subheadline.weight(.medium))
                .layoutPriority(1) // the price keeps its width; the name truncates first
            ChangeBadge(value: row.change24h)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A wallet holding row: logo, symbol + amount, value + 24h.
struct HoldingRow: View {
    let row: MarketRow
    /// Found in the wallet's history, not chosen in the app (`KnownTokenStore.unverified`).
    var unverified = false

    var body: some View {
        HStack(spacing: 12) {
            TokenLogo(token: row.token, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.token.symbol).font(.subheadline.weight(.semibold))
                    TokenBadgeView(token: row.token, receivedUnasked: unverified)
                }
                AmountText(amount: row.balance, token: row.token, compact: true, font: .caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.notTradingYet {
                // A Moment still collecting: no pool yet, so no price, and no value to show.
                Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    USDText(value: row.value, font: .subheadline.weight(.medium))
                    // Always surface the per-unit price next to the 24h change, even for tokens with a small balance.
                    HStack(spacing: 5) {
                        USDText(price: row.usd, font: .caption2).foregroundStyle(.secondary)
                        ChangeText(value: row.change24h, style: .caption2)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A launch-coin holding row: artwork, the held amount, and its USD value — the user's position, not the market cap —
/// at the price Home counts it at (`HomeTotals`), "—" without one.
struct LaunchHoldingRow: View {
    let holding: HomeModel.LaunchHolding
    let value: Double?

    var body: some View {
        HStack(spacing: 12) {
            LaunchArtwork(symbol: holding.launch.symbol, logo: holding.launch.logo, pointSize: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.launch.symbol).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(NumberStyle.units(holding.balance, decimals: 18, compact: true)) \(holding.launch.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                USDText(value: value, font: .subheadline.weight(.medium))
                (holding.launch.phase == .bonding ? Text("\(holding.launch.progressBps / 100)% to graduation") : Text(verbatim: holding.launch.phase.title))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A perps position summarised for the holdings list.
struct PositionSummaryRow: View {
    let position: PerpPosition

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(position.symbol).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(sideLabel) \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((position.side == .long ? Color.positive : Color.negative).opacity(0.15), in: Capsule())
                        .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                }
                Text("\(NumberStyle.number(position.size)) at \(NumberStyle.number(position.entry))", comment: "A perp position's size, then the price it was opened at")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(PriceFormat.usdValue(position.unrealized, signed: true))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
                Text("Unrealized", comment: "Under a perp position's unrealized profit or loss [tight]").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The position's side, for the chip beside its leverage ("Long 5×").
    private var sideLabel: String {
        position.side == .long
            ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]"))
            : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))
    }
}

/// A Moments stake row for the holdings list: media, name, editions and coins, then the value at the price Home counts
/// it at (`HomeTotals`); a Moment still collecting says "Not trading yet" in its place.
struct MomentHoldingRow: View {
    let row: MomentPortfolioRow
    let value: Double?

    private var coins: Double { HomeModel.coins(row) }

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol, creator: row.moment.moment.creator)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(verbatim: "\(tr("\(row.nftBalance) editions")) · \(NumberStyle.number(coins, compact: true)) \(row.moment.symbol)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if row.moment.isNotTradingYet {
                    Text("Not trading yet").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    USDText(value: value, font: .subheadline.weight(.medium))
                }
                Text(row.moment.graduated ? "Graduated" : row.moment.state == .expired ? "Expired" : "\(row.moment.progressBps / 100)% to graduation")
                    .font(.caption2).foregroundStyle(row.moment.graduated ? Color.positive : .secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
