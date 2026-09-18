import DyorKit
import Foundation

/// Mirrors what the app records on the device into the wallet's own rows on Supabase — activity with its dollar
/// size, the notification center, price alerts and settings — and restores them on a fresh device
/// after one sign-in. Every write goes through the wallet's backend session (row-level security by wallet);
/// nothing here touches a key. Uploads are debounced and best-effort: the local stores stay the source of truth,
/// and anything that failed is retried the next time that store changes or the session connects.
@MainActor
final class BackendSync {
    private let social: SocialSession
    private var settings: AppSettings?
    private var address: () -> Address? = { nil }
    private var debounced: [String: Task<Void, Never>] = [:]
    private var restoring = false
    private(set) var lastError: String?

    init(social: SocialSession) { self.social = social }

    /// Hooks every local store. Called once by the app environment.
    func install(settings: AppSettings, address: @escaping () -> Address?) {
        self.settings = settings
        self.address = address
        ActivityLog.onRecord = { record, owner in Task { @MainActor [weak self] in self?.activity(record, owner: owner) } }
        NotificationStore.onChange = { items, owner in Task { @MainActor [weak self] in self?.notifications(items, owner: owner) } }
        PriceAlertStore.onChange = { alerts in Task { @MainActor [weak self] in self?.alerts(alerts) } }
        AppSettings.onChange = { Task { @MainActor [weak self] in self?.settingsChanged() } }
    }

    // MARK: Uploads

    private struct ActivityRow: Encodable {
        let id: String, wallet: String, kind: String, section: String, title: String, subtitle: String
        let tx_hash: String?, usd: Double?, occurred_at: String
    }

    private func activity(_ record: ActivityRecord, owner: Address) {
        let row = ActivityRow(id: Self.stableID(record).uuidString.lowercased(), wallet: owner.checksummed.lowercased(), kind: record.kind.rawValue,
                              section: record.section ?? "wallet", title: String(record.title.prefix(120)), subtitle: String(record.subtitle.prefix(300)),
                              tx_hash: record.txHashHex?.lowercased(), usd: record.usd, occurred_at: Self.iso(record.time))
        schedule("activity-\(row.id)", delay: 0) { [social] in try await social.client.upsertRows("activity", [row], onConflict: "id") }
    }

    /// The same settled transaction always maps to the same row, so re-recording it can never double a row.
    private static func stableID(_ record: ActivityRecord) -> UUID {
        guard let hash = record.txHash, hash.count >= 16 else { return record.id }
        let b = [UInt8](hash.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private struct NotificationRow: Encodable {
        let wallet: String, id: String, kind: String, title: String, body: String, read: Bool, data: AppNotification, created_at: String
    }

    private func notifications(_ items: [AppNotification], owner: Address?) {
        guard !restoring, let owner else { return }
        let wallet = owner.checksummed.lowercased()
        let rows = items.prefix(200).map { NotificationRow(wallet: wallet, id: $0.id.uuidString.lowercased(), kind: $0.kind.rawValue, title: $0.title, body: $0.body, read: $0.read, data: $0, created_at: Self.iso($0.time)) }
        schedule("notifications", delay: 2) { [social] in
            if rows.isEmpty {
                try await social.client.delete("notifications", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
            } else {
                try await social.client.upsertRows("notifications", rows, onConflict: "wallet,id")
            }
        }
    }

    private struct AlertRow: Encodable {
        let wallet: String, client_id: String, kind: String, market: String, op: String, threshold: Double, enabled: Bool, payload: PriceAlert
    }

    private func alerts(_ alerts: [PriceAlert]) {
        guard !restoring, let owner = address() else { return }
        let wallet = owner.checksummed.lowercased()
        let rows = alerts.map { AlertRow(wallet: wallet, client_id: $0.id.uuidString.lowercased(), kind: "price", market: $0.token.checksummed.lowercased(), op: $0.above ? "above" : "below", threshold: $0.target, enabled: true, payload: $0) }
        schedule("alerts", delay: 2) { [social] in
            try await social.client.delete("alerts", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)"), URLQueryItem(name: "kind", value: "eq.price")])
            try await social.client.upsertRows("alerts", rows, onConflict: "wallet,client_id")
        }
    }

    private struct SettingsRow: Encodable { let wallet: String, data: [String: JSONValue], updated_at: String }

    private func settingsChanged() {
        UserDefaults.standard.set(true, forKey: "settings.touched")
        guard !restoring, let owner = address(), let settings else { return }
        let wallet = owner.checksummed.lowercased()
        let data = settings.snapshot.compactMapValues(JSONValue.init(any:))
        schedule("settings", delay: 2) { [social] in
            try await social.client.upsertRows("user_settings", [SettingsRow(wallet: wallet, data: data, updated_at: Self.iso(Date()))], onConflict: "wallet")
        }
    }

    // MARK: Restore

    private struct NotificationDown: Decodable { let data: AppNotification }
    private struct AlertDown: Decodable { let payload: PriceAlert }
    private struct SettingsDown: Decodable { let data: [String: JSONValue] }

    /// A fresh device: pulls what the wallet has on the backend into every local store that is still empty.
    func restore(owner: Address) async {
        guard social.isSignedIn else { return }
        let wallet = owner.checksummed.lowercased()
        restoring = true
        defer { restoring = false }
        func rows<T: Decodable>(_ table: String, _ extra: [URLQueryItem]) async -> [T] {
            (try? await social.client.read(table, query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "wallet", value: "eq.\(wallet)")] + extra, authed: true)) ?? []
        }
        if NotificationStore.all(owner: owner).isEmpty {
            let list: [NotificationDown] = await rows("notifications", [URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "200")])
            if !list.isEmpty { NotificationStore.save(list.map(\.data), owner: owner); NotificationHub.shared.bind(owner: owner) }
        }
        if PriceAlertStore.all().isEmpty {
            let list: [AlertDown] = await rows("alerts", [URLQueryItem(name: "kind", value: "eq.price")])
            if !list.isEmpty { PriceAlertStore.save(list.map(\.payload)) }
        }
        if !UserDefaults.standard.bool(forKey: "settings.touched"), let settings {
            let list: [SettingsDown] = await rows("user_settings", [])
            if let data = list.first?.data { settings.apply(snapshot: data.mapValues(\.any)) }
        }
    }

    // MARK: Plumbing

    private func schedule(_ key: String, delay: Double, _ work: @escaping @Sendable () async throws -> Void) {
        debounced[key]?.cancel()
        debounced[key] = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            guard self.social.isSignedIn else { return } // retried on the next change once the session connects
            do { try await work(); self.lastError = nil } catch { self.lastError = error.localizedDescription }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}

/// A JSON scalar/collection for `jsonb` columns without a fixed schema (the settings snapshot).
enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init?(any value: Any) {
        switch value {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let a as [Any]: self = .array(a.compactMap(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.compactMapValues(JSONValue.init(any:)))
        default: return nil
        }
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
