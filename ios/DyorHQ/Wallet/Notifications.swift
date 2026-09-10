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
        post(title: "Swap complete",
             body: "Swapped \(NumberStyle.units(amountIn, decimals: tokenIn.decimals, compact: true)) \(tokenIn.symbol) → \(NumberStyle.units(amountOut, decimals: tokenOut.decimals, compact: true)) \(tokenOut.symbol)")
    }

    static func perpOrder(side: String, market: String, filled: Bool) {
        post(title: filled ? "Order filled" : "Order placed", body: "\(side) \(market)")
    }

    static func transactionConfirmed(_ label: String) {
        post(title: "Confirmed", body: "\(label) confirmed on Monad.")
    }

    static func priceAlert(symbol: String, above: Bool, target: Double, price: Double) {
        post(title: "Price alert: \(symbol)",
             body: "\(symbol) is now \(NumberStyle.number(price)) — \(above ? "above" : "below") your \(NumberStyle.number(target)) target.")
    }

    /// A copied trader made a trade. The body prompts the user to open Strategy → Copy Trading to confirm or decline.
    static func copyTrade(trader: String, action: String) {
        post(title: "Copy signal: \(trader)", body: "\(action) — open Copy Trading to confirm or decline.")
    }

    /// Posts immediately (no trigger). Silently no-ops unless the user has granted permission.
    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
