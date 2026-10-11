import DyorKit
import SwiftUI

// Parts of the Perps trade screen: the order book beside the ticket, the size slider and the trades tape.

// MARK: - Side order book (compact ladder shown beside the ticket, wide version under the chart)

struct SideOrderBook: View {
    let book: OrderBook
    let mark: Double
    /// Perpl's own mid (falls back to book mid / mark). Rendered as the big centered price between the ladders — using
    /// bestBid there duplicated the top bid row directly below it.
    var mid: Double? = nil
    var changePct: Double? = nil
    let symbol: String
    let priceDecimals: Int
    var rows: Int = 8
    var wide: Bool = false

    /// Tick-size grouping (wide book only). 0 = raw; higher indices aggregate price levels so a deep book reads at a
    /// glance. @State resets to raw when the market changes, since the whole trade view is rebuilt with `.id(market.id)`.
    @State private var groupIndex = 0

    private var midTint: Color { (changePct ?? 0) < 0 ? .negative : .positive }
    private var centerPrice: Double {
        if let mid { return mid }
        if let b = book.bestBid, let a = book.bestAsk { return (a + b) / 2 }
        return book.bestBid ?? mark
    }
    private var tick: Double { pow(10, -Double(priceDecimals)) }
    private let groupMultipliers = [1, 10, 100]
    private var groupMultiplier: Int { groupMultipliers[min(groupIndex, groupMultipliers.count - 1)] }
    private var group: Double { tick * Double(groupMultiplier) }

    var body: some View {
        VStack(alignment: .leading, spacing: wide ? 3 : 2) {
            HStack(spacing: 6) {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                if wide {
                    Menu {
                        ForEach(groupMultipliers.indices, id: \.self) { i in
                            Button(NumberStyle.number(tick * Double(groupMultipliers[i]))) { Haptics.selection(); groupIndex = i }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(NumberStyle.number(group)).font(.caption2.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.brand)
                    }
                    .accessibilityLabel("Price grouping \(NumberStyle.number(group))")
                }
                Spacer()
                Text("Total (\(symbol))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if book.isEmpty {
                Text("Waiting for the book…").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                let asks = cumulative(Array(aggregated(book.asks, up: true).prefix(rows)))   // ascending, cumulative from mid
                let bids = cumulative(Array(aggregated(book.bids, up: false).prefix(rows)))
                let maxTotal = max(asks.map(\.total).max() ?? 1, bids.map(\.total).max() ?? 1)

                ForEach(asks.reversed(), id: \.price) { level in
                    bookRow(level, side: "Ask", tint: .negative, maxTotal: maxTotal)
                }

                HStack(spacing: 6) {
                    Text(NumberStyle.number(centerPrice))
                        .font((wide ? Font.headline : Font.subheadline).weight(.bold)).monospacedDigit()
                        .foregroundStyle(midTint)
                    if wide, let spread = book.spread {
                        Spacer()
                        Text("Spread \(NumberStyle.number(spread))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, wide ? 6 : 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(book.spread.map { Text("Mid price \(NumberStyle.number(centerPrice)), spread \(NumberStyle.number($0))") }
                                    ?? Text("Mid price \(NumberStyle.number(centerPrice))"))

                ForEach(bids, id: \.price) { level in
                    bookRow(level, side: "Bid", tint: .positive, maxTotal: maxTotal)
                }

                ratioBar
            }
        }
        // Asks and bids are told apart by colour and position on screen; each row also says which it is (AI-10).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bookSummary)
    }

    /// The book in words, in the app's language.
    private var bookSummary: String {
        guard let bid = book.bestBid, let ask = book.bestAsk else { return tr("Order book") }
        return tr("Order book. Best bid \(NumberStyle.number(bid)), best ask \(NumberStyle.number(ask)).")
    }

    private struct Level { let price: Double; let total: Double }

    /// Aggregates raw book levels into the current tick group (passthrough when grouping is 1×). Asks round up, bids
    /// round down, so every bucket stays on the correct side of the spread.
    private func aggregated(_ levels: [BookLevel], up: Bool) -> [(price: Double, size: Double)] {
        guard groupMultiplier > 1 else { return levels.map { (price: $0.price, size: $0.size) } }
        var buckets: [Double: Double] = [:]
        for l in levels {
            let key = (up ? (l.price / group).rounded(.up) : (l.price / group).rounded(.down)) * group
            buckets[key, default: 0] += l.size
        }
        return buckets.map { (price: $0.key, size: $0.value) }.sorted { up ? $0.price < $1.price : $0.price > $1.price }
    }

    private func cumulative(_ levels: [(price: Double, size: Double)]) -> [Level] {
        var running = 0.0
        return levels.map { running += $0.size; return Level(price: $0.price, total: running) }
    }

    private func bookRow(_ level: Level, side: LocalizedStringKey, tint: Color, maxTotal: Double) -> some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().fill(tint.opacity(0.16))
                    .frame(width: geo.size.width * min(1, level.total / maxTotal))
            }
            HStack {
                Text(NumberStyle.number(level.price)).font(.caption.monospacedDigit()).foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(NumberStyle.number(level.total, compact: true)).font(.caption.monospacedDigit()).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: wide ? 22 : 19)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(side)) \(NumberStyle.number(level.price)), total \(NumberStyle.number(level.total, compact: true)) \(symbol)"))
    }

    private var ratioBar: some View {
        let buy = book.bidShare
        return VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(Color.positive).frame(width: max(2, geo.size.width * buy - 1.5))
                    Capsule().fill(Color.negative)
                }
            }
            .frame(height: 4)
            HStack {
                Text(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false)).foregroundStyle(.positive)
                Spacer()
                Text(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false)).foregroundStyle(.negative)
            }
            .font(.caption2.weight(.medium)).monospacedDigit()
        }
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bids \(NumberStyle.percent(buy * 100, fractionDigits: 0, signed: false)) of visible depth, asks \(NumberStyle.percent((1 - buy) * 100, fractionDigits: 0, signed: false))")
    }
}

// MARK: - Percent-of-margin size slider

/// A track with five stops (0/25/50/75/100 %) and a draggable brand thumb, the size control from the reference perp
/// screens. Dragging fires a selection haptic when it crosses a stop and reports the live percentage so the ticket's
/// amount recalculates from available margin × leverage.
struct PercentSizeSlider: View {
    @Binding var percent: Double
    var onChange: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let stops = [0.0, 25, 50, 75, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(Int(percent.rounded()))%")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(percent > 0 ? Color.brand : Color.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * CGFloat(percent / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill)).frame(height: 3)
                    Capsule().fill(Color.brand).frame(width: max(0, x), height: 3)
                    ForEach(stops, id: \.self) { stop in
                        Circle()
                            .fill(percent >= stop - 0.01 ? Color.brand : Color(.systemBackground))
                            .overlay(Circle().stroke(percent >= stop - 0.01 ? Color.brand : Color(.systemFill), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(x: w * CGFloat(stop / 100), y: geo.size.height / 2)
                    }
                    Circle().fill(Color.brand)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .position(x: min(max(9, x), w - 9), y: geo.size.height / 2)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = Double(min(max(0, value.location.x / w), 1)) * 100
                            let previousStop = nearestStop(percent)
                            percent = pct
                            if nearestStop(pct) != previousStop { Haptics.selection() }
                            onChange(pct)
                        }
                        .onEnded { _ in
                            // Snap to the nearest stop for a clean resting value.
                            let snapped = nearestStop(percent)
                            withAnimation(.easeOut(duration: 0.15)) { percent = snapped }
                            onChange(snapped)
                        }
                )
            }
            .frame(height: 22)
        }
        // One adjustable control for VoiceOver and Switch Control, in the 25% steps the track snaps to, instead of a
        // drag-only shape and a loose percentage text (security audit AI-4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Size, share of available margin")
        .accessibilityValue("\(Int(percent.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = 25.0
            let next: Double
            switch direction {
            case .increment: next = min(100, (percent / step).rounded(.down) * step + step)
            case .decrement: next = max(0, (percent / step).rounded(.up) * step - step)
            @unknown default: return
            }
            guard next != percent else { return }
            Haptics.selection()
            percent = next
            onChange(next)
        }
    }

    private func nearestStop(_ pct: Double) -> Double {
        stops.min(by: { abs($0 - pct) < abs($1 - pct) }) ?? 0
    }
}

// MARK: - Trades tape

struct TradesTape: View {
    let trades: [PerpTrade]
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size (\(symbol))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Time").font(.caption2).foregroundStyle(.secondary)
            }
            if trades.isEmpty {
                Text("Waiting for trades…").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ForEach(trades.prefix(18)) { trade in
                    HStack {
                        Text(NumberStyle.number(trade.price)).font(.caption.monospacedDigit()).foregroundStyle(trade.side == .buy ? Color.positive : Color.negative)
                        Spacer()
                        Text(NumberStyle.number(trade.size, maximumFractionDigits: 4)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(trade.time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: 18)
                    // Buy or sell is shown by colour only; say it (AI-10).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tapeLabel(trade))
                }
            }
        }
    }
}

extension TradesTape {
    /// A trade in words, in the app's language: its side, size, price and time.
    fileprivate func tapeLabel(_ trade: PerpTrade) -> Text {
        let size = "\(NumberStyle.number(trade.size, maximumFractionDigits: 4)) \(symbol)"
        let price = NumberStyle.number(trade.price)
        let time = trade.time.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale))
        return trade.side == .buy ? Text("Buy \(size) at \(price), \(time)") : Text("Sell \(size) at \(price), \(time)")
    }
}
