import DyorKit
import SwiftUI

// The Perps ticket's picker sheets: leverage and its ruler, order type, size unit, reference price and market.

// MARK: - Adjust Leverage sheet

/// A focused leverage picker: a ruler you drag, integer quick-picks, and a Confirm that applies the choice. The ruler
/// ticks a selection haptic at every whole leverage as you drag, and the value pill tracks your finger — the tactile
/// "changing leverage" feel of a native trading app.
struct LeverageSheet: View {
    let leverage: Double
    let maxLeverage: Double
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double

    init(leverage: Double, maxLeverage: Double, onConfirm: @escaping (Double) -> Void) {
        self.leverage = leverage
        self.maxLeverage = maxLeverage
        self.onConfirm = onConfirm
        _value = State(initialValue: leverage)
    }

    private var rounded: Double { value.rounded() }
    private var changed: Bool { Int(rounded) != Int(leverage.rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Adjust Leverage").font(.title2.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
            }
            .padding(.top, 22).padding(.horizontal, 22)

            LeverageRuler(value: $value, range: 1...max(2, maxLeverage))
                .frame(height: 104)
                .padding(.top, 28).padding(.horizontal, 20)
                .clipped()

            HStack(spacing: 12) {
                ForEach(quickPicks, id: \.self) { pick in
                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.2)) { value = Double(pick) }
                    } label: {
                        (pick == Int(maxLeverage) ? Text("Max", comment: "The most allowed: a button or chip that fills in the whole balance, or the highest leverage or amount [tight]") : Text(verbatim: "\(pick)x"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Int(rounded) == pick ? Color.brand.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(Int(rounded) == pick ? Color.brand : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pick == Int(maxLeverage) ? "Maximum leverage, \(pick) times" : "\(pick) times leverage")
                    .accessibilityAddTraits(Int(rounded) == pick ? .isSelected : [])
                }
            }
            .padding(.top, 30).padding(.horizontal, 20)

            Button {
                Haptics.commit(); onConfirm(rounded); dismiss()
            } label: {
                Text("Confirm")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24).padding(.horizontal, 20)

            Spacer(minLength: 12)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }

    private var quickPicks: [Int] {
        [2, 5, 10, Int(maxLeverage)].filter { $0 <= Int(maxLeverage) }.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// A scrolling leverage ruler, the way the reference perp apps do it: a fixed brand indicator at the centre with the
/// current value pinned above and below it, while the whole tick strip + integer labels SLIDE horizontally under your
/// finger. You read the leverage where the ruler meets the centre line — the number stays put, the *ruler* moves.
struct LeverageRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Points per 1× — sets tick density and how many integers are visible at once (~7 across a phone width).
    private let pointsPerUnit: CGFloat = 50
    private let minorEvery = 0.2

    // Vertical layout. Each integer label morphs between the row baseline and the raised position as it nears the
    // centre: the nearest number rises to `topY` and enlarges to `bigSize` to BECOME the leverage value; the rest sit
    // small at `rowY`. There is no separate big readout — that was the duplicated number.
    private let topY: CGFloat = 15
    private let rowY: CGFloat = 47
    private let tickTop: CGFloat = 70
    private let majorTick: CGFloat = 24
    private let minorTick: CGFloat = 11
    private let rowSize: CGFloat = 15
    private let bigSize: CGFloat = 27

    private var lo: Double { range.lowerBound }
    private var hi: Double { range.upperBound }

    /// The leverage the current drag began at, so a finger translation maps to an absolute value.
    @State private var dragAnchor: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let center = w / 2
            let visibleUnits = Double(center / pointsPerUnit) + 1
            let firstInt = max(Int(lo.rounded(.up)), Int((value - visibleUnits).rounded(.down)))
            let lastInt = min(Int(hi.rounded(.down)), Int((value + visibleUnits).rounded(.up)))

            ZStack {
                // Tick strip — every tick is placed by its offset from the centred value, so the whole strip slides as
                // `value` changes. Whole numbers get a tall tick; sub-integer steps a short one.
                Canvas { ctx, size in
                    let ctr = size.width / 2
                    let half = Double(ctr / pointsPerUnit) + 1
                    var v = ((value - half) / minorEvery).rounded(.down) * minorEvery
                    let end = min(hi, value + half) + 0.0001
                    while v <= end {
                        if v >= lo - 0.0001 {
                            let x = ctr + CGFloat(v - value) * pointsPerUnit
                            let isWhole = abs(v.rounded() - v) < 0.001
                            let h = isWhole ? majorTick : minorTick
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: tickTop))
                            path.addLine(to: CGPoint(x: x, y: tickTop + h))
                            ctx.stroke(path, with: .color(Color(.tertiaryLabel).opacity(isWhole ? 0.85 : 0.4)), lineWidth: isWhole ? 1.4 : 1)
                        }
                        v += minorEvery
                    }
                }

                // Integer labels. Each stays at its own value-position (so the strip scrolls) while its size and height
                // interpolate by nearness to the centre: the closest number rises and grows to become the leverage
                // value, its neighbours shrink back into the row. One copy of each number — the raised one IS the value.
                if firstInt <= lastInt {
                    ForEach(firstInt...lastInt, id: \.self) { i in
                        let dist = abs(Double(i) - value)          // distance from the centred value, in leverage units
                        let p = max(0, 1 - dist)
                        let prox = p * p * (3 - 2 * p)              // smoothstep, so the nearest number pops cleanly
                        Text(verbatim: "\(i)X")
                            .font(.system(size: rowSize + (bigSize - rowSize) * prox, weight: prox > 0.55 ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.4 + 0.6 * prox))
                            .fixedSize()
                            .position(x: center + CGFloat(Double(i) - value) * pointsPerUnit,
                                      y: rowY - (rowY - topY) * prox)
                    }
                }

                // Fixed centre — brand indicator line and the value pill (the precise, possibly-fractional value).
                Rectangle().fill(Color.brand).frame(width: 2.5, height: 70)
                    .position(x: center, y: 58)
                Text(verbatim: "\(NumberStyle.number(value, maximumFractionDigits: 1))x")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.brand, in: Capsule())
                    .fixedSize()
                    .position(x: center, y: tickTop)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragAnchor == nil { dragAnchor = value }
                        let anchor = dragAnchor ?? value
                        let previous = Int(value.rounded())
                        // Scroll convention: dragging right pulls lower values to the centre (the strip follows the finger).
                        value = min(max(lo, anchor - Double(g.translation.width) / Double(pointsPerUnit)), hi)
                        if Int(value.rounded()) != previous { Haptics.selection() }
                    }
                    .onEnded { _ in
                        dragAnchor = nil
                        withAnimation(.easeOut(duration: 0.16)) { value = min(max(lo, value.rounded()), hi) }
                    }
            )
        }
        // The tick labels and value pill are one adjustable control: swipe up or down for 1× steps, so any leverage
        // can be chosen without dragging, not only the quick picks.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leverage")
        .accessibilityValue("\(Int(value.rounded())) times")
        .accessibilityAdjustableAction { direction in
            let current = value.rounded()
            let next: Double
            switch direction {
            case .increment: next = min(hi, current + 1)
            case .decrement: next = max(lo, current - 1)
            @unknown default: return
            }
            guard next != value else { return }
            Haptics.selection()
            value = next
        }
    }
}

// MARK: - Order Type sheet

struct OrderTypeSheet: View {
    let kind: OrderKind
    let onSelect: (OrderKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Order Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.market, icon: "bolt.fill", title: "Market", subtitle: "Execute immediately at current price")
                optionRow(.limit, icon: "chart.line.uptrend.xyaxis", title: "Limit", subtitle: "Set a specific price for your order")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: OrderKind, icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        let selected = kind == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.brand : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(selected ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Unit Preference sheet

struct UnitPreferenceSheet: View {
    let unit: OrderTicket.AmountUnit
    let asset: String
    let onSelect: (OrderTicket.AmountUnit) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Unit Preference") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.asset, symbol: asset, title: asset, subtitle: "Order size is denominated in \(asset), the base asset.")
                optionRow(.usd, symbol: "AUSD", title: "AUSD", subtitle: "Order size is calculated from an AUSD amount at the current price.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    /// `title` is the unit's symbol (the market's asset, or AUSD), shown as it is.
    private func optionRow(_ value: OrderTicket.AmountUnit, symbol: String, title: String, subtitle: LocalizedStringKey) -> some View {
        let selected = unit == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                MarketLogo(symbol: symbol, url: nil, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? Color.brand : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Price Type sheet

struct PriceTypeSheet: View {
    let selected: PerpTradeView.PriceType
    let onSelect: (PerpTradeView.PriceType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Price Type") { dismiss() }
            VStack(spacing: 12) {
                optionRow(.last, title: "Last Traded Price", subtitle: "Fill the limit price with the last trade.")
                optionRow(.mid, title: "Mid Price", subtitle: "Fill the limit price with the mid of the book.")
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer(minLength: 16)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func optionRow(_ value: PerpTradeView.PriceType, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        let isSel = selected == value
        return Button {
            Haptics.selection(); onSelect(value); dismiss()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSel { Image(systemName: "checkmark").font(.headline.weight(.semibold)).foregroundStyle(Color.brand) }
            }
            .padding(14)
            .background(isSel ? Color.brand.opacity(0.1) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Select Perpetual sheet

struct SelectPerpetualSheet: View {
    let markets: [PerpMarket]
    let currentId: Int
    let change: (PerpMarket) -> Double?
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PerpMarket] {
        guard !query.isEmpty else { return markets }
        let q = query.lowercased()
        return markets.filter { $0.asset.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Select Perpetual") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search…", text: $query).autocorrectionDisabled().textInputAutocapitalization(.characters)
            }
            .font(.body)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .padding(.horizontal, 20).padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { market in
                        Button {
                            Haptics.selection(); onSelect(market.id); dismiss()
                        } label: { marketRow(market) }
                        .buttonStyle(.plain)
                        if market.id != filtered.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private func marketRow(_ market: PerpMarket) -> some View {
        let selected = market.id == currentId
        return HStack(spacing: 12) {
            MarketLogo(symbol: market.asset, url: nil, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(market.asset).font(.body.weight(.bold))
                Text(market.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PriceFormat.usdPrice(market.mark))
                    .font(.body.weight(.semibold)).monospacedDigit()
                ChangeText(value: change(market), style: .caption)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(selected ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Shared sheet header: a bold title on the left and a round close button on the right.
private func sheetHeader(_ title: LocalizedStringKey, onClose: @escaping () -> Void) -> some View {
    HStack {
        Text(title).font(.title2.weight(.bold))
        Spacer()
        Button(action: onClose) {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
    }
    .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 8)
}
