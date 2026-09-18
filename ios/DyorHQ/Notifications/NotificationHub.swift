import DyorKit
import Foundation
import Observation
import UserNotifications

/// One notification the app produced, kept in the in-app notification center. Every local (system) notification the
/// app delivers is also recorded here, so nothing is lost when the system banner is missed or permission is off.
struct AppNotification: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable, CaseIterable {
        case transaction, swap, perp, priceAlert, moments, system

        /// Tolerates values written by older builds (e.g. removed strategy kinds) so a legacy row never breaks decoding.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
        }

        var symbol: String {
            switch self {
            case .transaction: return "checkmark.circle"
            case .swap: return "arrow.left.arrow.right"
            case .perp: return "chart.line.uptrend.xyaxis"
            case .priceAlert: return "bell.badge"
            case .moments: return "camera.aperture"
            case .system: return "info.circle"
            }
        }

        var title: String {
            switch self {
            case .transaction: return "Transactions"
            case .swap: return "Swaps"
            case .perp: return "Perps"
            case .priceAlert: return "Price alerts"
            case .moments: return "Moments"
            case .system: return "DyorHQ"
            }
        }
    }

    /// Where a tap should take the user.
    enum Route: String, Codable, Hashable {
        case none, home, trade, perps, launch, moments, portfolio

        /// Tolerates routes written by older builds (e.g. the removed strategy routes) — they resolve to no-op.
        init(from decoder: Decoder) throws {
            self = Route(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
        }
    }

    var id = UUID()
    let kind: Kind
    let title: String
    let body: String
    let time: Date
    var read: Bool
    let route: Route
    /// An optional id the route can open directly (a Moment id, …).
    let reference: String?

    init(kind: Kind, title: String, body: String, time: Date = Date(), read: Bool = false, route: Route = .none, reference: String? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.time = time
        self.read = read
        self.route = route
        self.reference = reference
    }
}

/// Per-wallet persistence of the notification center (UserDefaults; public text only).
enum NotificationStore {
    private static func key(_ owner: Address?) -> String { "notifications.v1." + (owner?.hex.lowercased() ?? "none") }
    private static let cap = 300

    static func all(owner: Address?) -> [AppNotification] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([AppNotification].self, from: data)) ?? []
    }

    /// Mirrors the center to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([AppNotification], Address?) -> Void)?

    static func save(_ items: [AppNotification], owner: Address?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(items.prefix(cap))), forKey: key(owner))
        onChange?(items, owner)
    }
}

/// The platform-wide notification system: one place every feature posts to. A post is recorded in the in-app center
/// (badge on Home, list with routes) and, when the user allowed it, delivered as a system notification so it also
/// arrives while the app is in the background. There is no push server: everything is generated on-device while the
/// app runs, which is why the center keeps a durable record.
@Observable
@MainActor
final class NotificationHub {
    static let shared = NotificationHub()

    private(set) var items: [AppNotification] = []
    private(set) var owner: Address?
    /// The notification the user tapped in the list, for the router to open.
    var pendingRoute: AppNotification?

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    /// Follows the signed-in wallet; each wallet has its own center.
    func bind(owner: Address?) {
        self.owner = owner
        items = NotificationStore.all(owner: owner)
    }

    /// Records the notification and delivers it as a system notification when `deliver` is true and permission is granted.
    func post(_ notification: AppNotification, deliver: Bool = true) {
        items.insert(notification, at: 0)
        if items.count > 300 { items = Array(items.prefix(300)) }
        NotificationStore.save(items, owner: owner)
        if deliver { Self.deliverLocally(title: notification.title, body: notification.body, id: notification.id.uuidString) }
    }

    func post(kind: AppNotification.Kind, title: String, body: String, route: AppNotification.Route = .none, reference: String? = nil, deliver: Bool = true) {
        post(AppNotification(kind: kind, title: title, body: body, route: route, reference: reference), deliver: deliver)
    }

    func markRead(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].read else { return }
        items[i].read = true
        NotificationStore.save(items, owner: owner)
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
        NotificationStore.save(items, owner: owner)
    }

    func clear() {
        items = []
        NotificationStore.save(items, owner: owner)
    }

    /// Delivers a system notification now (no trigger). Silently no-ops unless the user granted permission.
    nonisolated static func deliverLocally(title: String, body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
