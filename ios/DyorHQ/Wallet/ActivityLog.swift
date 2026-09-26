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
            self.init(tolerating: try decoder.singleValueContainer().decode(String.self))
        }

        /// A stored or restored kind; one this build doesn't know (a future case) reads as `.moment`, as decoding does.
        init(tolerating raw: String) {
            self = Kind(rawValue: raw) ?? .moment
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
    /// A sent transaction whose outcome isn't settled here yet (`PendingActivity`): "pending" until it is re-checked,
    /// then "reverted" or "notFound"; nil for every settled row. Optional and backward compatible.
    var status: String?

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

    /// A record restored from the wallet's backend `activity` row (`BackendSync.restore`), under that row's id.
    init(restored row: BackendRestore.Activity) {
        self.init(kind: Kind(tolerating: row.kind), title: row.title, subtitle: row.subtitle, hash: row.txHash, time: row.time,
                  section: row.section, usd: row.usd, feeUsd: row.feeUsd)
        id = row.id
    }

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
    /// The most records kept per wallet (the newest).
    static let cap = 300

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

    /// Rewrites this wallet's log in place, for `PendingActivity`'s rows. Nothing is mirrored to the backend.
    static func update(owner: Address, _ change: (inout [ActivityRecord]) -> Void) {
        let before = all(owner: owner)
        var list = before
        change(&list)
        guard list != before else { return }
        if list.count > cap { list = Array(list.prefix(cap)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    /// Merges records restored from the backend (`BackendSync.restore`, MERA-PLAN §6) into this wallet's log: nothing
    /// already here is replaced or doubled (same id or same transaction hash), newest first, capped like `record`.
    /// Not mirrored back (`onRecord`): these rows came from the backend.
    static func merge(restored: [ActivityRecord], owner: Address) {
        let current = all(owner: owner)
        let merged = BackendRestore.mergeActivity(local: current, restored: restored, cap: cap, id: \.id, txHash: \.txHash, time: \.time)
        guard merged.map(\.id) != current.map(\.id) else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(merged), forKey: key(owner))
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

/// Transactions sent whose confirmation the app hasn't seen (security audit 2026-09-26, GL-2). Each step a plan sends is
/// written as a pending row under its hash the moment it is sent, so a plan that fails afterwards — the phone locked
/// mid-wait, the connection dropped, the app killed — still leaves the transaction in Recent Activity with its View
/// link. A step seen confirmed while the plan runs drops its row (the plan's own record, written when it settles,
/// takes the final step's hash); what is left is re-checked on the next launch or return to the foreground and becomes
/// confirmed, reverted or not found. Local only: these rows are never mirrored to the backend.
@MainActor
enum PendingActivity {
    /// `ActivityRecord.status` values.
    static let pendingStatus = "pending"
    static let revertedStatus = "reverted"
    static let notFoundStatus = "notFound"

    /// A step just sent: a pending row under its hash, unless the hash already has one.
    static func sent(_ hash: Data, label: String, owner: Address?) {
        guard let owner else { return }
        ActivityLog.update(owner: owner) { list in
            guard !list.contains(where: { $0.txHashHex == hash.hexString }) else { return }
            var row = ActivityRecord(kind: .send, title: label, subtitle: "Sent — confirmation not seen yet", hash: hash)
            row.status = pendingStatus
            list.insert(row, at: 0)
        }
    }

    /// A step seen confirmed while its plan runs: its pending row goes.
    static func confirmed(_ hash: Data, owner: Address?) {
        guard let owner else { return }
        ActivityLog.update(owner: owner) { $0.removeAll { $0.txHashHex == hash.hexString && $0.status == pendingStatus } }
    }

    /// A step seen reverted: its row says so.
    static func reverted(_ hash: Data, owner: Address?) {
        guard let owner else { return }
        resolve(owner: owner, as: revertedStatus) { $0.txHashHex == hash.hexString }
    }

    /// Re-checks every pending row of `owner`: a receipt settles it as confirmed or reverted; a transaction the network
    /// doesn't know half an hour after it was sent is not found (it never landed); anything else stays pending for the
    /// next check.
    static func recheck(owner: Address?, rpc: RPCClient) async {
        guard let owner else { return }
        for row in ActivityLog.all(owner: owner) where row.status == pendingStatus {
            guard let hash = row.txHash else { continue }
            let outcome: String?
            do {
                if let receipt = try await rpc.transactionReceipt(hash) {
                    outcome = receipt.success ? nil : revertedStatus
                } else if Date().timeIntervalSince(row.time) > 30 * 60, await rpc.knowsTransaction(hash) == false {
                    outcome = notFoundStatus
                } else {
                    continue
                }
            } catch {
                continue
            }
            resolve(owner: owner, as: outcome) { $0.id == row.id }
        }
    }

    /// Rewrites the pending rows `matching` with `outcome` (nil: confirmed), keeping each row's id, title and time.
    private static func resolve(owner: Address, as outcome: String?, matching: (ActivityRecord) -> Bool) {
        ActivityLog.update(owner: owner) { list in
            for i in list.indices where list[i].status == pendingStatus && matching(list[i]) {
                let subtitle = outcome == revertedStatus ? "Reverted — only the network fee was spent"
                    : outcome == notFoundStatus ? "Not found on the network — it never confirmed" : "Confirmed"
                var row = ActivityRecord(kind: list[i].kind, title: list[i].title, subtitle: subtitle, hash: list[i].txHash, time: list[i].time, section: list[i].section)
                row.id = list[i].id
                row.status = outcome
                list[i] = row
            }
        }
    }
}
