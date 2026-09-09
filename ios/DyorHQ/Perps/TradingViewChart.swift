import DyorKit
import SwiftUI
import WebKit

/// A real TradingView chart — TradingView's own Lightweight Charts™ engine (bundled, no network) rendered in a
/// `WKWebView` — fed entirely by Perpl's candle data. Candlesticks, a volume histogram, a crosshair with an OHLC
/// legend, pan and zoom. The palette is resolved from the app's own Positive/Negative/label colors and re-sent when
/// the theme flips, so the chart matches the surrounding screen exactly in light and dark.
struct TradingViewChart: View {
    let candles: [PerpCandle]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ChartWebView(candles: candles, colorScheme: colorScheme)
            .background(Color(.secondarySystemGroupedBackground))
    }
}

private struct ChartWebView: UIViewRepresentable {
    let candles: [PerpCandle]
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "chart", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.apply(candles: candles, colorScheme: colorScheme)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ready")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var ready = false
        private var lastSignature = ""
        private var lastScheme: ColorScheme?
        private var pendingCandles: [PerpCandle] = []
        private var pendingScheme: ColorScheme = .light

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor in
                self.ready = true
                self.flush()
            }
        }

        func apply(candles: [PerpCandle], colorScheme: ColorScheme) {
            pendingCandles = candles
            pendingScheme = colorScheme
            if ready { flush() }
        }

        private func flush() {
            guard let web = webView else { return }
            if pendingScheme != lastScheme {
                lastScheme = pendingScheme
                web.evaluateJavaScript("window.__configure(\(Self.paletteJSON(for: pendingScheme)))")
            }
            let signature = "\(pendingCandles.count)|\(pendingCandles.first?.id ?? 0)|\(pendingCandles.last?.id ?? 0)|\(pendingCandles.last?.close ?? 0)|\(pendingCandles.last?.high ?? 0)|\(pendingCandles.last?.low ?? 0)"
            guard signature != lastSignature, !pendingCandles.isEmpty else { return }
            lastSignature = signature
            web.evaluateJavaScript("window.__setData(\(Self.candlesJSON(pendingCandles)))")
        }

        private static func candlesJSON(_ candles: [PerpCandle]) -> String {
            let rows = candles.map { c in
                "{\"time\":\(Int(c.time.timeIntervalSince1970)),\"open\":\(c.open),\"high\":\(c.high),\"low\":\(c.low),\"close\":\(c.close),\"volume\":\(c.volume)}"
            }
            return "[\(rows.joined(separator: ","))]"
        }

        private static func paletteJSON(for scheme: ColorScheme) -> String {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let up = UIColor(named: "Positive")?.resolvedColor(with: traits) ?? .systemGreen
            let down = UIColor(named: "Negative")?.resolvedColor(with: traits) ?? .systemRed
            let text = UIColor.secondaryLabel.resolvedColor(with: traits)
            let grid = UIColor.separator.resolvedColor(with: traits)
            return """
            {"up":"\(up.hex)","down":"\(down.hex)","text":"\(text.hex)","grid":"\(grid.rgba(0.6))","border":"\(grid.rgba(0.9))","crosshair":"\(text.hex)","up2":"\(up.rgba(0.45))","down2":"\(down.rgba(0.45))"}
            """
        }
    }
}

private extension UIColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func rgba(_ alpha: CGFloat) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%d,%d,%d,%.2f)", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), alpha)
    }
}
