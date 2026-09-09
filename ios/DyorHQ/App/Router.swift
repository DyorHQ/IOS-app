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

    func openSwap(tokenIn: Token? = nil, tokenOut: Token? = nil) {
        pendingSwap = (tokenIn, tokenOut)
        tab = .swap
    }

    func openPerp(id: Int) {
        pendingPerpMarket = id
        tab = .perps
    }
}
