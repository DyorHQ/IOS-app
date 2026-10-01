import BigInt
import DyorKit
import Foundation
import UserNotifications

/// On-device notifications for completed actions and triggered price alerts, via the system UserNotifications
/// framework. There is no push server (that would need APNs): these are local notifications, posted by the app while
/// it runs — in the foreground, or in the few seconds before iOS suspends it. While the app is suspended or closed
/// nothing is noticed, so nothing is posted.
@MainActor
enum Notifications {
    /// Installs the delegate that lets our notifications appear while the app is in the foreground. Without it, iOS
    /// suppresses the banner whenever the app is open, which is exactly when these on-device notifications fire, so
    /// nothing ever shows on screen. Called from the app delegate's `didFinishLaunching`, before iOS hands over the tap
    /// that launched the app (a banner tapped while it was closed): a delegate set any later misses that tap. Calling it
    /// again changes nothing.
    static func configure() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== NotificationForegroundDelegate.shared { center.delegate = NotificationForegroundDelegate.shared }
    }

    /// Asks for permission (alert + sound). Called when the user turns notifications on in Settings, and once on
    /// sign-in so a default-on user is actually prompted (the Settings toggle only asks when it is flipped).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Requests permission once if it has never been decided — used at sign-in so notifications work out of the box.
    static func requestAuthorizationIfUndetermined() async {
        if await authorizationStatus() == .notDetermined { _ = await requestAuthorization() }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func swapped(_ amountIn: BigUInt, _ tokenIn: Token, _ amountOut: BigUInt, _ tokenOut: Token) {
        post(kind: .swap, title: "Swap complete",
             body: "Swapped \(NumberStyle.units(amountIn, decimals: tokenIn.decimals, compact: true)) \(tokenIn.symbol) → \(NumberStyle.units(amountOut, decimals: tokenOut.decimals, compact: true)) \(tokenOut.symbol)", route: .trade)
    }

    /// A perp order the app sent or saw fill. `notice` says which: `PerpOrderNotice(acknowledged:)` for Perpl's
    /// acknowledgement of an order ("Order submitted" for a market order, "Order placed" for a limit order), `.filled`
    /// only for a position read that saw the fill.
    static func perpOrder(_ notice: PerpOrderNotice, side: String, market: String) {
        post(kind: .perp, title: notice.title, body: "\(side) \(market)", route: .perps)
    }

    static func transactionConfirmed(_ label: String) {
        post(kind: .transaction, title: "Confirmed", body: "\(label) confirmed on Monad.")
    }

    /// A completed cross-chain bridge — recorded in the notification center like a swap.
    static func bridge(amount: String, from: String, to: String) {
        post(kind: .swap, title: "Bridge complete", body: "\(amount) bridged from \(from) to \(to).", route: .home)
    }

    static func priceAlert(symbol: String, above: Bool, target: Double, price: Double) {
        post(kind: .priceAlert, title: "Price alert: \(symbol)",
             body: "\(symbol) is now \(NumberStyle.number(price)) — \(above ? "above" : "below") your \(NumberStyle.number(target)) target.", route: .home)
    }

    /// Records the notification in the in-app center and delivers it as a system notification (when permitted).
    static func post(kind: AppNotification.Kind, title: String, body: String, route: AppNotification.Route = .none, reference: String? = nil) {
        NotificationHub.shared.post(kind: kind, title: title, body: body, route: route, reference: reference)
    }
}

/// Presents DyorHQ's on-device notifications as banners while the app is open. The app has no push server, so every
/// notification is generated while the user is in the app; without this delegate iOS would only file them silently in
/// Notification Center and never surface a banner.
final class NotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationForegroundDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
