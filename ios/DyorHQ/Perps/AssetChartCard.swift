import DyorKit
import SwiftUI

/// Maps a spot token to the Perpl market that prices its underlying asset, so Swap can show the same live,
/// Perpl-sourced chart the Perps screen uses. Wrapped and staked variants fold into their base (WMON/gMON → MON,
/// WETH/rETH → ETH, WBTC/cbBTC → BTC). Stablecoins and RWAs have no market and get no chart.
enum PerpMarketRef {
    static let byAsset: [String: Int] = ["BTC": 1, "MON": 10, "ETH": 20, "SOL": 31, "HYPE": 40, "ZEC": 50]

    static func marketId(for token: Token) -> Int? {
        let s = token.symbol.uppercased()
        if let id = byAsset[s] { return id }
        if s.contains("BTC") { return 1 }
        if s.hasSuffix("ETH") { return 20 } // WETH, ezETH, rETH — not USDe/USDT0
        if s.contains("MON") { return 10 } // WMON, gMON, sMON, aprMON, shMON
        return nil
    }

    /// The market to chart for a pair — the base asset being traded, preferring the pay side.
    static func marketId(pay: Token, receive: Token) -> Int? {
        marketId(for: pay) ?? marketId(for: receive)
    }

    static func symbol(for id: Int) -> String { byAsset.first { $0.value == id }?.key ?? "" }
}

/// A self-contained live market chart for one Perpl market: a header with the mark price and its move over the
/// window, a real TradingView chart fed by Perpl candles, and a timeframe switch. Used on Swap; the Perps screen
/// has its own richer version.
struct AssetChartCard: View {
    let marketId: Int
    let symbol: String
    @Environment(AppEnvironment.self) private var env
    @State private var market: PerpMarket?
    @State private var candles: [PerpCandle] = []
    @State private var resolution = 3600
    @State private var loading = true

    static let resolutions: [(Int, String)] = [(300, "5m"), (900, "15m"), (3600, "1h"), (14400, "4h"), (86400, "1D")]

    private var last: Double? { candles.last?.close ?? market?.mark }
    private var windowChange: Double? {
        guard let first = candles.first?.open, first > 0, let last = candles.last?.close else { return nil }
        return (last - first) / first * 100
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TokenLogo(symbol: symbol, url: nil, size: 26)
                Text("\(symbol)-PERP").font(.subheadline.weight(.semibold))
                Spacer()
                if let last { Text(NumberStyle.number(last)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                ChangeText(value: windowChange, style: .caption)
            }
            TradingViewChart(candles: candles)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if candles.isEmpty {
                        if loading { ProgressView() }
                        else { Text("No chart data for this market yet.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            timeframePicker
        }
        .task(id: marketId) {
            await loadMarket()
            await loadCandles()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await loadCandles(showSpinner: false)
            }
        }
        .onChange(of: resolution) { _, _ in Task { await loadCandles() } }
    }

    private var timeframePicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.resolutions, id: \.0) { seconds, label in
                Button(label) { if resolution != seconds { Haptics.selection(); resolution = seconds } }
                    .font(.caption.weight(resolution == seconds ? .bold : .regular))
                    .foregroundStyle(resolution == seconds ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(resolution == seconds ? Color(.tertiarySystemFill) : .clear, in: Capsule())
            }
        }
    }

    private func loadMarket() async {
        if market == nil {
            market = (try? await env.perpl.markets())?.first { $0.id == marketId }
        }
    }

    private func loadCandles(showSpinner: Bool = true) async {
        guard let market else { loading = false; return }
        if showSpinner { loading = true }
        let to = Date()
        let from = to.addingTimeInterval(-Double(resolution) * 150)
        let fetched = (try? await env.perpl.candles(marketId: marketId, resolution: resolution, from: from, to: to, priceDecimals: market.priceDecimals)) ?? []
        if !fetched.isEmpty { candles = fetched }
        loading = false
    }
}
