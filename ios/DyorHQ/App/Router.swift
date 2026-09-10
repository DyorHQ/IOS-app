import DyorKit
import Foundation
import Observation

/// Which trading interface the Trade tab shows. Swap and Perps share one tab, switched by a top toggle; this later
/// gains a Strategy mode (copy-trading, market-making) in place of raw Perps.
enum TradeMode: String, CaseIterable, Identifiable {
    case swap, perps
    var id: String { rawValue }
    var label: String { self == .swap ? "Swap" : "Perps" }
}

/// Cross-tab navigation requests, e.g. "swap this token" from a market row.
@Observable
@MainActor
final class Router {
    var tab: AppTab = .home
    /// Which side of the Trade tab is shown (Swap vs Perps).
    var tradeMode: TradeMode = .swap
    var pendingSwap: (tokenIn: Token?, tokenOut: Token?)?
    var pendingPerpMarket: Int?
    /// Preset the perps ticket direction/leverage/size when opening a market (e.g. copying a trader's LONG 5x).
    var pendingPerpSide: PositionSide?
    var pendingPerpLeverage: Double?
    var pendingPerpSize: Double?
    /// A launch to open on the Launch tab's detail page, set from another tab or the post-launch "View" action.
    var pendingLaunch: Launch?

    func openSwap(tokenIn: Token? = nil, tokenOut: Token? = nil) {
        pendingSwap = (tokenIn, tokenOut)
        tradeMode = .swap
        tab = .trade
    }

    func openPerp(id: Int, side: PositionSide? = nil, leverage: Double? = nil, size: Double? = nil) {
        pendingPerpMarket = id
        pendingPerpSide = side
        pendingPerpLeverage = leverage
        pendingPerpSize = size
        tradeMode = .perps
        tab = .trade
    }

    func openLaunch(_ launch: Launch) {
        pendingLaunch = launch
        tab = .launch
    }
}
