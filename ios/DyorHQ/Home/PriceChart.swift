import Charts
import DyorKit
import SwiftUI

// A token's price line: on Home's token page, and on a launch's page.

struct PriceChart: View {
    let points: [PricePoint]
    let isLoading: Bool
    let tint: Color
    /// The app's language: a chart draws its axis labels once, so they are formatted in it explicitly, and a change of
    /// language draws them again (a page open during the change kept French dates in Chinese).
    @Environment(\.locale) private var locale

    /// The plotted range with a little headroom. An area mark anchors at zero by default, which flattens a
    /// 24-hour price line into a ruler, so the fill starts at this floor instead.
    private var domain: ClosedRange<Double> {
        let values = points.map(\.usd)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.08, abs(high) * 0.0005, 1e-12)
        return (low - padding)...(high + padding)
    }

    /// The time axis's labels: hours for a day's line (Home's token page), days for a longer one (a launch page charts a
    /// coin since its launch). A mark every 6 hours over weeks drew a hundred grid lines and labels piled into one strip.
    private var timeFormat: Date.FormatStyle {
        guard let first = points.first?.time, let last = points.last?.time, last.timeIntervalSince(first) > 36 * 3600 else {
            return Date.FormatStyle.dateTime.hour().locale(locale)
        }
        return Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
    }

    var body: some View {
        if points.count >= 2 {
            // Worked out once per redraw: each area mark and axis label reads it, and each reading maps every point.
            let domain = self.domain
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                AreaMark(x: .value("Time", point.time), yStart: .value("Floor", domain.lowerBound), yEnd: .value("Price", point.usd))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: domain)
            // Centred on their marks: a date label starts at its mark by default, so the last one ran past the plot ("Oc…").
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeFormat, centered: true) } }
            .chartYAxis {
                // Labels as fine as the plotted range needs (`PriceFormat.axis`), so a dust coin's ticks don't all read "0".
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let price = value.as(Double.self) { Text(PriceFormat.axis(price, span: domain.upperBound - domain.lowerBound)) } }
                }
            }
            .accessibilityLabel("Price over the past 24 hours")
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Price History", systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Paragraph("This token has no pool with enough liquidity to chart.")
            }
        }
    }
}
