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

/// Screens that live outside the tab bar: opened from the side menu (or the home header) as full-screen covers with
/// their own navigation stack and a Close control.
enum PresentedScreen: String, Identifiable {
    case portfolio, news, help, profile
    var id: String { rawValue }
}

/// Cross-tab navigation requests, e.g. "swap this token" from a market row.
@Observable
@MainActor
final class Router {
    var tab: AppTab = .home
    /// The side menu (the three-line button on Home) is open.
    var menuOpen = false
    /// A full-screen section opened from the menu or the home header.
    var presented: PresentedScreen?
    /// The reporting period every volume figure in the app uses (Home's Total Volume and the Portfolio).
    var period: VolumePeriod = .day
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
    /// A Moment to open on the Moments tab's detail page.
    var pendingMoment: MomentInfo?

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

    func openMoment(_ moment: MomentInfo) {
        pendingMoment = moment
        tab = .moments
    }

    /// Opens a section from the side menu: tabs switch (and the Trade tab picks its mode), the rest present.
    func open(_ item: MenuItem) {
        menuOpen = false
        switch item {
        case .home: tab = .home
        case .spot: tradeMode = .swap; tab = .trade
        case .perps: tradeMode = .perps; tab = .trade
        case .launch: tab = .launch
        case .moments: tab = .moments
        case .strategies: tab = .strategy
        case .portfolio: presented = .portfolio
        case .news: presented = .news
        case .help: presented = .help
        }
    }
}

/// Reporting periods for volume, fees and P&L: the last day, week, month, or everything.
enum VolumePeriod: String, CaseIterable, Identifiable {
    case day, week, month, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All"
        }
    }
    var shortLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7D"
        case .month: return "30D"
        case .all: return "All"
        }
    }
    /// Wall-clock length; nil for "All".
    var seconds: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 86_400 * 7
        case .month: return 86_400 * 30
        case .all: return nil
        }
    }
    /// The matching swap-history window (on-chain scans are bounded, so "All" is the scan's own cap).
    var swapWindow: SwapHistoryService.Window {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .all: return .all
        }
    }
    /// Blocks to scan for on-chain history (~0.4 s blocks); "All" covers the swap scan's 90-day cap.
    var blocks: UInt64 { swapWindow.blocks }
    /// The earliest timestamp inside the period (0 for "All").
    func since(now: Date = Date()) -> Date { seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast }
}

/// The sections listed in the side menu, in display order.
enum MenuItem: String, CaseIterable, Identifiable {
    case home, spot, perps, launch, moments, news, strategies, portfolio, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .spot: return "Spot"
        case .perps: return "Perps"
        case .launch: return "Launch"
        case .moments: return "Moments"
        case .news: return "News"
        case .strategies: return "Strategies"
        case .portfolio: return "Portfolio"
        case .help: return "Get Help"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .spot: return "arrow.left.arrow.right"
        case .perps: return "chart.line.uptrend.xyaxis"
        case .launch: return "flame"
        case .moments: return "camera.aperture"
        case .news: return "newspaper"
        case .strategies: return "wand.and.stars"
        case .portfolio: return "chart.pie"
        case .help: return "questionmark.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return "Balances and markets"
        case .spot: return "Swap across every Monad venue"
        case .perps: return "Perpetuals on Perpl"
        case .launch: return "Launch and trade new coins"
        case .moments: return "Collect moments, graduate coins"
        case .news: return "Crypto headlines"
        case .strategies: return "Copy trading and market making"
        case .portfolio: return "Volume, fees and P&L across DyorHQ"
        case .help: return "Support and community"
        }
    }
}
