import DyorKit
import SwiftUI

// The Perps screen's cards: a position, a resting order and a TP/SL, and the request behind a Cancel sheet.

// MARK: - Position & order cards

struct PositionCard: View {
    let position: PerpPosition
    let liveMark: Double
    /// The TP/SL closing this position's side, as the Orders list shows them.
    var triggers: [TriggerRow] = []
    let onClose: () -> Void
    let onAddMargin: () -> Void
    let onTriggers: () -> Void

    private var livePnl: Double {
        let dir = position.side == .long ? 1.0 : -1.0
        return dir * (liveMark - position.entry) * position.size + position.premium
    }
    private var pnlPct: Double? { position.margin > 0 ? livePnl / position.margin * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PerpTradeView.sideLeverage(position)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(PriceFormat.usdValue(livePnl, signed: true))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let pnlPct {
                        Text(pnlPct, format: .number.precision(.fractionLength(2)).sign(strategy: .always())) + Text(verbatim: "%")
                    }
                }
                .foregroundStyle(livePnl < 0 ? Color.negative : Color.positive)
                .font(.caption.monospacedDigit())
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                stat("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
                stat("Entry", NumberStyle.number(position.entry))
                stat("Mark", NumberStyle.number(liveMark > 0 ? liveMark : position.mark))
                stat("Margin", PriceFormat.usdValue(position.margin))
                // An open position's liquidation price is nil only when its maintenance margin couldn't be read.
                stat("Liq.", position.liquidation.map { NumberStyle.number($0) } ?? PositionText.unknown)
                stat("Notional", PriceFormat.usdValue(position.notional))
            }
            if !triggers.isEmpty {
                Paragraph(triggerSummary).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Add Margin", action: onAddMargin)
                    .buttonStyle(.bordered).controlSize(.small).tint(.brand)
                Button("TP/SL", action: onTriggers)
                    .buttonStyle(.bordered).controlSize(.small).tint(.brand)
                    .accessibilityLabel("Take profit and stop loss")
                Button(action: onClose) { Text(verbatim: tr(LocalizedStringResource("position.close", defaultValue: "Close", comment: "Closes the open position (a verb), a button on the position. [tight]"))) }
                    .buttonStyle(.bordered).controlSize(.small).tint(.negative)
            }
        }
        .padding(.vertical, 4)
    }

    /// "TP 72,000 · SL 61,500", in the app's language.
    private var triggerSummary: String {
        let parts = triggers.map { PositionText.trigger($0.kind == .takeProfit, at: $0.price) }
        let verified = triggers.allSatisfy { $0.source == .live }
        let unverified = tr(LocalizedStringResource("unverified", comment: "Ends a TP/SL summary when Perpl's live list couldn't confirm it: “TP 72,000 · unverified”."))
        return (parts + (verified ? [] : [unverified])).joined(separator: " · ")
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

/// A small labelled figure used across the order / trigger cards.
private struct MiniStat: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(tint)
        }
    }
}

/// A resting on-chain order (limit / reduce-only limit), with its side, price, size, leverage and distance from mark —
/// "Cancelling…" instead of its Cancel while a cancel sent over the trading connection is on its way, and how it left
/// once Perpl's live list showed it gone (`gone`), with no Cancel then.
struct OrderCard: View {
    let order: PerpOrder
    let mark: Double
    var cancelling = false
    var gone: PerplTrading.ChainOrderGone? = nil
    let onCancel: () -> Void

    private var typeLabel: String {
        order.reduceOnly ? tr("Limit · reduce-only")
            : tr(LocalizedStringResource("Limit", comment: "Order type: rests at the price you set until it fills. [tight]"))
    }
    private var distance: Double? { mark > 0 ? (order.price - mark) / mark * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(order.side == .buy ? "Buy" : "Sell")
                    .font(.caption.weight(.bold)).foregroundStyle(Color.onStatus)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(order.side == .buy ? Color.positive : Color.negative, in: Capsule())
                Text(typeLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let gone {
                    // A cancel from this device: what became of it ("Filled first"). Otherwise the order left on its own.
                    Text(verbatim: gone.byCancel ? PerpActionCopy.orderState(gone.result) : PerpActionCopy.orderLeft(gone.result))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                } else if cancelling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: PerpTriggerCopy.rowCancelling)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small).tint(.negative)
                }
            }
            HStack(alignment: .top) {
                MiniStat(label: "Price", value: NumberStyle.number(order.price))
                Spacer()
                MiniStat(label: "Size", value: "\(NumberStyle.number(order.size)) \(order.symbol)")
                Spacer()
                MiniStat(label: "Leverage", value: "\(NumberStyle.number(order.leverage, maximumFractionDigits: 1))×")
                Spacer()
                if let d = distance { MiniStat(label: "Distance", value: String(format: "%+.2f%%", d), tint: d >= 0 ? .positive : .negative) }
            }
        }
        .opacity(cancelling || gone != nil ? 0.6 : 1)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A TP/SL row to display: Perpl's open trigger from the trading stream (live, or the last list it sent before it
/// went offline), or the app's own record of one it placed (just placed, or unverifiable while offline).
struct TriggerRow: Identifiable {
    enum Source: Equatable {
        /// On Perpl's live list: authoritative, and cancellable from here.
        case live
        /// On the last list Perpl sent; the stream is offline, so it may have fired or been cancelled since.
        case lastKnown
        /// Just placed from this device; the stream hasn't shown it yet.
        case pending
        /// This device's record while the stream is offline: never confirmed against Perpl.
        case unverified
    }
    let id: String
    let symbol: String
    let kind: PlacedTrigger.Kind
    let price: Double
    let size: Double
    let positionLong: Bool
    let source: Source
    /// The trigger on Perpl, for a row from its list.
    let order: PerplOpenOrder?
    /// The size of the open position on the side this trigger closes, if there is one.
    let positionSize: Double?

    /// Where the row comes from, in the app's language.
    var label: String {
        switch source {
        case .live: return tr("Keeper trigger")
        case .lastKnown: return tr("Last seen on Perpl")
        case .pending: return tr("Pending…")
        case .unverified: return tr("Saved on this device · unverified")
        }
    }

    /// How much of the position it closes, when that isn't all of it (a trigger's size is fixed
    /// when it's placed and doesn't follow the position).
    var coverage: String? {
        guard let positionSize, positionSize > 0, size > 0 else { return nil }
        let tolerance = max(positionSize, size) * 1e-6
        let held = "\(NumberStyle.number(positionSize)) \(symbol)"
        if size < positionSize - tolerance { return tr("Closes \(NumberStyle.number(size)) of your \(held)") }
        if size > positionSize + tolerance { return tr("Larger than your \(held) position") }
        return nil
    }
}

/// A take-profit / stop-loss (keeper-managed trigger), labelled by where it comes from, with a Cancel for a live one —
/// dimmed and "Cancelling…" instead while a cancel sent for it is on its way (a second tap would send a second).
struct TriggerCard: View {
    let row: TriggerRow
    let mark: Double
    var cancelling = false
    var onCancel: () -> Void = {}

    private var tint: Color { row.kind == .takeProfit ? .positive : .negative }
    private var distance: Double? { mark > 0 ? (row.price - mark) / mark * 100 : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: row.kind == .takeProfit ? "target" : "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(tint)
                Text(row.kind.label).font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(row.positionLong ? "on Long" : "on Short").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if row.source == .live, row.order != nil, cancelling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: PerpTriggerCopy.rowCancelling)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } else if row.source == .live, row.order != nil {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small).tint(.negative)
                        .accessibilityLabel(row.kind == .takeProfit ? "Cancel take profit at \(NumberStyle.number(row.price))" : "Cancel stop loss at \(NumberStyle.number(row.price))")
                } else {
                    Text(row.label).font(.caption2).foregroundStyle(row.source == .live || row.source == .pending ? Color.secondary : Color.attention)
                }
            }
            HStack(alignment: .top) {
                MiniStat(label: "Trigger", value: NumberStyle.number(row.price), tint: tint)
                Spacer()
                MiniStat(label: "Size", value: "\(NumberStyle.number(row.size)) \(row.symbol)")
                Spacer()
                if let d = distance { MiniStat(label: "Distance", value: String(format: "%+.2f%%", d)) }
            }
            if let coverage = row.coverage {
                Text(coverage).font(.caption2).foregroundStyle(Color.attention)
            }
        }
        .opacity(cancelling ? 0.6 : 1)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(row.source == .live ? 0.22 : 0.12), lineWidth: 1))
    }
}

/// Which triggers a Cancel sheet is for, and the sheet's title and note, written where the request is made.
struct TriggerCancelRequest: Identifiable {
    let id = UUID()
    let orders: [PerplOpenOrder]
    let title: LocalizedStringResource
    let note: LocalizedStringResource?
}
