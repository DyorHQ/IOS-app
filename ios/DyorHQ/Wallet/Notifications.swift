import BigInt
import DyorKit
import Foundation
import UserNotifications

/// On-device notifications for completed actions and triggered price alerts, via the system UserNotifications
/// framework. There is no push server (that would need APNs); these are local notifications, so they arrive whether
/// the app is foregrounded, backgrounded, or the action completed while the user was elsewhere in the app.
@MainActor
enum Notifications {
    /// Asks for permission (alert + sound). Called when the user turns notifications on in Settings.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func swapped(_ amountIn: BigUInt, _ tokenIn: Token, _ amountOut: BigUInt, _ tokenOut: Token) {
        post(kind: .swap, title: "Swap complete",
             body: "Swapped \(NumberStyle.units(amountIn, decimals: tokenIn.decimals, compact: true)) \(tokenIn.symbol) → \(NumberStyle.units(amountOut, decimals: tokenOut.decimals, compact: true)) \(tokenOut.symbol)", route: .trade)
    }

    static func perpOrder(side: String, market: String, filled: Bool) {
        post(kind: .perp, title: filled ? "Order filled" : "Order placed", body: "\(side) \(market)", route: .perps)
    }

    static func transactionConfirmed(_ label: String) {
        post(kind: .transaction, title: "Confirmed", body: "\(label) confirmed on Monad.")
    }

    static func priceAlert(symbol: String, above: Bool, target: Double, price: Double) {
        post(kind: .priceAlert, title: "Price alert: \(symbol)",
             body: "\(symbol) is now \(NumberStyle.number(price)) — \(above ? "above" : "below") your \(NumberStyle.number(target)) target.", route: .home)
    }

    /// A copied trader made a trade. The body prompts the user to open Strategy → Copy Trading to confirm or decline.
    static func copyTrade(trader: String, action: String) {
        post(kind: .copyTrade, title: "Copy signal: \(trader)", body: "\(action) — open Copy Trading to confirm or decline.", route: .strategy)
    }

    /// Delta-neutral strategy events: entries, exits, funding flips, risk alerts.
    static func strategy(kind: AppNotification.Kind = .strategy, title: String, body: String, strategyID: String) {
        post(kind: kind, title: title, body: body, route: .deltaNeutral, reference: strategyID)
    }

    /// Records the notification in the in-app center and delivers it as a system notification (when permitted).
    static func post(kind: AppNotification.Kind, title: String, body: String, route: AppNotification.Route = .none, reference: String? = nil) {
        NotificationHub.shared.post(kind: kind, title: title, body: body, route: route, reference: reference)
    }
}
