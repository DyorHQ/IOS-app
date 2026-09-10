import DyorKit
import Foundation
import Observation

/// Cross-tab navigation requests, e.g. "swap this token" from a market row.
@Observable
@MainActor
final class Router {
    var tab: AppTab = .home
    var pendingSwap: (tokenIn: Token?, tokenOut: Token?)?
    var pendingPerpMarket: Int?
    /// A launch to open on the Launch tab's detail page, set from another tab or the post-launch "View" action.
    var pendingLaunch: Launch?

    func openSwap(tokenIn: Token? = nil, tokenOut: Token? = nil) {
        pendingSwap = (tokenIn, tokenOut)
        tab = .swap
    }

    func openPerp(id: Int) {
        pendingPerpMarket = id
        tab = .perps
    }

    func openLaunch(_ launch: Launch) {
        pendingLaunch = launch
        tab = .launch
    }
}
