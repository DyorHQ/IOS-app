import DyorKit
import Foundation

/// One action the user took, recorded locally when its transaction settles so the Recent Activity feed can show
/// launches, buys, sells, swaps and perp orders — perps especially, which have no on-chain feed to scan — each with
/// an explorer link. Persisted per wallet in UserDefaults; only public details are stored, never keys.
struct ActivityRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case swap, launch, buy, sell, perp, send, moment, bridge, deposit, withdraw
        /// Claiming vested coins or holder rewards (Moments claim, Launchpad rewards).
        case claim
        /// Collecting fees or proceeds (a creator's collect proceeds and pool fees, a platform/treasury share,
        /// Launchpad creator fees) — money the action pulls into the wallet.
        case fees
        /// A coin's lifecycle event the user triggered on-chain: graduation (or its retry), a buyback, an expiry.
        case graduate

        /// Tolerates rows written by future builds (a new case) so a forward row never breaks decoding on an old app.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .moment
        }

        var symbol: String {
            switch self {
            case .swap: return "arrow.left.arrow.right"
            case .launch: return "flame.fill"
            case .buy: return "arrow.down"
            case .sell: return "arrow.up"
            case .perp: return "chart.line.uptrend.xyaxis"
            case .send: return "paperplane.fill"
            case .moment: return "camera.aperture"
            case .bridge: return "point.3.connected.trianglepath.dotted"
            case .deposit: return "tray.and.arrow.down.fill"
            case .withdraw: return "tray.and.arrow.up.fill"
            case .claim: return "arrow.down.circle.fill"
            case .fees: return "dollarsign.circle.fill"
            case .graduate: return "checkmark.seal.fill"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let txHashHex: String?
    let time: Date
    /// Which part of the app the action belongs to (spot, perps, launch, moments, wallet) and its dollar size,
    /// when known — what the backend's activity feed and the platform volume are built from.
    var section: String?
    var usd: Double?
    /// Fee paid for the action in USD, when known (e.g. the bridge spread) — feeds the backend journey's fee totals.
    var feeUsd: Double?
    /// An id the matching notification can deep-link to (a Moment id, a coin address). Optional and backward
    /// compatible: rows written before this field decode with `nil`.
    var reference: String?

    init(kind: Kind, title: String, subtitle: String, hash: Data?, time: Date = Date(), section: String? = nil, usd: Double? = nil, feeUsd: Double? = nil, reference: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.txHashHex = hash?.hexString
        self.time = time
        self.section = section ?? Self.defaultSection(kind)
        self.usd = usd
        self.feeUsd = feeUsd
        self.reference = reference
    }

    private static func defaultSection(_ kind: Kind) -> String {
        switch kind {
        case .swap: return "spot"
        case .launch, .buy, .sell: return "launch"
        case .perp: return "perps"
        case .moment, .graduate: return "moments"
        case .bridge: return "bridge"
        case .send, .deposit, .withdraw, .claim, .fees: return "wallet"
        }
    }

    var txHash: Data? { txHashHex.flatMap { Data(hex: $0) } }

    /// The notification category to file this action under, derived from its `section` so a claim/fee/graduate in
    /// Moments reads as a Moments notification and the same action in Launch reads as a plain transaction.
    var notificationKind: AppNotification.Kind {
        switch section {
        case "moments": return .moments
        case "perps": return .perp
        case "spot", "bridge": return .swap
        default: return .transaction
        }
    }

    /// Where tapping the action's notification should take the user.
    var notificationRoute: AppNotification.Route {
        switch section {
        case "moments": return .moments
        case "perps": return .perps
        case "launch": return .launch
        case "spot": return .trade
        default: return .home
        }
    }
}

/// Local per-wallet record of the user's actions. Recent Activity merges this (the source of truth for perps and the
/// freshest rows) with on-chain scans that backfill older launchpad and swap history.
enum ActivityLog {
    private static func key(_ owner: Address) -> String { "activityLog.v1.\(owner.hex)" }
    private static let cap = 300

    static func all(owner: Address?) -> [ActivityRecord] {
        guard let owner, let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([ActivityRecord].self, from: data)) ?? []
    }

    /// Mirrors every new record to the backend (installed by the app environment).
    nonisolated(unsafe) static var onRecord: ((ActivityRecord, Address) -> Void)?

    /// Records an action. De-duplicates by tx hash so re-recording the same settled transaction never doubles a row.
    static func record(_ record: ActivityRecord, owner: Address?) {
        guard let owner else { return }
        var list = all(owner: owner)
        if let hash = record.txHashHex { list.removeAll { $0.txHashHex == hash } }
        list.insert(record, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
        onRecord?(record, owner)
    }
}

/// The single entry point for a completed user action: it records the action in the Recent Activity feed AND
/// surfaces it in the notification center (and as a system banner when allowed), so nothing is ever recorded
/// without being surfaced, or surfaced without being recorded. Every settled write's `onCompleted` should call
/// this. `notify: false` records only — for the few flows (swap, bridge, perp) that post their own bespoke
/// notification with tailored copy and so must not double-post.
@MainActor
enum Activity {
    static func record(_ record: ActivityRecord, owner: Address?, notify: Bool = true) {
        ActivityLog.record(record, owner: owner)
        guard notify, owner != nil else { return }
        NotificationHub.shared.post(kind: record.notificationKind, title: record.title, body: record.subtitle,
                                    route: record.notificationRoute, reference: record.reference)
    }
}
