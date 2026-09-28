import DyorKit
import Foundation
import Observation
import SwiftUI

/// A review sheet counts itself in `Router.linkHolds` while it is on screen, so a Moment link waits until it is gone.
private struct HoldsMomentLinks: ViewModifier {
    @Environment(Router.self) private var router
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear { if !counted { counted = true; router.linkHolds += 1 } }
            .onDisappear { if counted { counted = false; router.linkHolds = max(0, router.linkHolds - 1) } }
    }
}

extension View {
    /// Holds Moment links while this view is on screen (every review sheet that can lead to a signature).
    func holdsMomentLinks() -> some View { modifier(HoldsMomentLinks()) }
}

/// Which trading interface the Trade tab shows. Swap and Perps share one tab, switched by a top toggle.
enum TradeMode: String, CaseIterable, Identifiable {
    case swap, perps
    var id: String { rawValue }
    var label: String { self == .swap ? "Swap" : "Perps" }
}

/// Screens that live outside the tab bar: opened from the side menu (or the home header) as full-screen covers with
/// their own navigation stack and a Close control.
enum PresentedScreen: String, Identifiable {
    case portfolio, news, help, profile, notifications
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
    var period: VolumePeriod = .all
    /// Which side of the Trade tab is shown (Swap vs Perps).
    var tradeMode: TradeMode = .swap
    var pendingSwap: (tokenIn: Token?, tokenOut: Token?)?
    var pendingPerpMarket: Int?
    /// A launch to open on the Launch tab's detail page, set from another tab or the post-launch "View" action.
    var pendingLaunch: Launch?
    /// A Moment to open on the Moments tab's detail page.
    var pendingMoment: MomentInfo?
    /// A Moment link that arrived (a universal link or `dyorhq://`) and hasn't been opened yet. It waits here, on the
    /// App-level router that outlives sign-in, until RootView's gate (`MomentLinkGate`) says the app may navigate.
    var pendingLink: MomentLink?
    /// A Moment link to open on the Moments tab: MomentsView pushes `MomentLinkView`, which resolves and loads it.
    var pendingMomentLink: MomentLink?
    /// A short notice about the last link handed to the app (not a Moment), shown once by RootView.
    var linkNotice: String?
    /// What holds a Moment link back right now: every review sheet on screen (`holdsMomentLinks()` — ConfirmationSheet,
    /// the Perps order / close / margin / TP/SL reviews, Bridge) and every approved send or deletion no sheet covers
    /// (`holdingLinks`). RootView's gate waits until it is 0, so a link never tears one down.
    var linkHolds = 0

    /// Every URL handed to the app. This parses and stores; nothing navigates until the gate delivers. A URL on our
    /// hosts that isn't a Moment link gets a notice; anything else (Privy's OAuth callback on the `dyorhq` scheme, say)
    /// is not ours to comment on.
    func handle(_ url: URL) {
        if let link = MomentLink(url: url) {
            pendingLink = link
        } else if MomentLink.isOurs(url) {
            linkNotice = "That link isn't a Moment."
        }
    }

    /// Runs `work` — an approved send or a deletion that no review sheet covers — holding Moment links until it ends.
    /// The task takes the count, not the view that started it, because the task outlives that view.
    func holdingLinks<T>(_ work: () async throws -> T) async rethrows -> T {
        linkHolds += 1
        defer { linkHolds = max(0, linkHolds - 1) }
        return try await work()
    }

    /// Opens the pending link's Moment: the menu and whatever is presented close, and the Moments tab pushes it.
    func deliverPendingLink() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        menuOpen = false
        presented = nil
        pendingMomentLink = link
        tab = .moments
    }

    /// Opens Swap on a pair. A retired cohort's Moment coin on either side opens nothing: past cohorts are claim-only,
    /// so trading their coins is closed everywhere in the app (cohorts 1 and 2's pools also pay the retired platform
    /// wallet), and the engine refuses it too.
    func openSwap(tokenIn: Token? = nil, tokenOut: Token? = nil) {
        guard SwapEngine.isTradablePair(tokenIn, tokenOut) else { return }
        pendingSwap = (tokenIn, tokenOut)
        tradeMode = .swap
        tab = .trade
    }

    func openPerp(id: Int) {
        pendingPerpMarket = id
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

    /// Follows a tapped notification to its screen.
    func open(_ notification: AppNotification) {
        presented = nil
        switch notification.route {
        case .none: break
        case .home: tab = .home
        case .trade: tradeMode = .swap; tab = .trade
        case .perps: tradeMode = .perps; tab = .trade
        case .launch: tab = .launch
        case .moments: tab = .moments
        case .portfolio: presented = .portfolio
        }
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
    case home, spot, perps, launch, moments, news, portfolio, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .spot: return "Spot"
        case .perps: return "Perps"
        case .launch: return "Launch"
        case .moments: return "Moments"
        case .news: return "News"
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
        case .portfolio: return "Volume, fees and P&L across DyorHQ"
        case .help: return "Support and community"
        }
    }
}
