import DyorKit
import Foundation

/// A take-profit / stop-loss the app placed for the user. Perpl holds TP/SL as keeper-managed trigger orders and
/// exposes no read-back API for them (the on-chain Exchange has no trigger primitive), so the app remembers what it
/// placed and shows that — reconciled against the polled positions/orders so a fired or closed trigger doesn't linger.
/// These are the user's OWN set triggers, not an authoritative snapshot from Perpl.
struct PlacedTrigger: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case takeProfit, stopLoss
        var label: String { self == .takeProfit ? "Take Profit" : "Stop Loss" }
    }

    let id: UUID
    let perpId: Int
    let symbol: String
    let kind: Kind
    let price: Double
    let size: Double
    /// The side of the position the trigger protects (true = long), for context/labelling.
    let positionLong: Bool
    let placedAt: Date

    init(perpId: Int, symbol: String, kind: Kind, price: Double, size: Double, positionLong: Bool, placedAt: Date = Date()) {
        self.id = UUID()
        self.perpId = perpId
        self.symbol = symbol
        self.kind = kind
        self.price = price
        self.size = size
        self.positionLong = positionLong
        self.placedAt = placedAt
    }
}

/// Per-wallet persistence of app-placed TP/SL triggers (UserDefaults; public numbers only, no keys).
enum TriggerStore {
    private static func key(_ owner: Address?) -> String { "perp.triggers.v1." + (owner?.checksummed.lowercased() ?? "none") }
    /// A market entry needs a little time to settle into a position; don't prune a freshly-placed trigger before the
    /// position it protects has had a chance to appear in the poll.
    private static let settleGrace: TimeInterval = 120

    static func all(owner: Address?) -> [PlacedTrigger] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PlacedTrigger].self, from: data)) ?? []
    }

    private static func save(_ list: [PlacedTrigger], owner: Address?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    /// Record freshly-accepted triggers. A new trigger replaces a prior one of the SAME market AND kind (re-arming a
    /// take-profit supersedes the old take-profit) but leaves the untouched sibling in place — so placing only a new
    /// take-profit never wipes a stop-loss that is still live keeper-side.
    static func record(_ new: [PlacedTrigger], owner: Address?) {
        guard !new.isEmpty else { return }
        var list = all(owner: owner)
        for t in new { list.removeAll { $0.perpId == t.perpId && $0.kind == t.kind } }
        list.append(contentsOf: new)
        save(list, owner: owner)
    }

    /// Keep a trigger while its market still has an open position OR a resting entry order (or it is too fresh to have
    /// settled yet); drop it otherwise. Returns — and persists — the survivors.
    @discardableResult
    static func reconcile(owner: Address?, openPerpIds: Set<Int>) -> [PlacedTrigger] {
        let now = Date()
        let kept = all(owner: owner).filter { openPerpIds.contains($0.perpId) || now.timeIntervalSince($0.placedAt) < settleGrace }
        save(kept, owner: owner)
        return kept
    }
}
