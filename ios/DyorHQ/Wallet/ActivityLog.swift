import DyorKit
import Foundation

/// One action the user took, recorded locally when its transaction settles so the Recent Activity feed can show
/// launches, buys, sells, swaps and perp orders — perps especially, which have no on-chain feed to scan — each with
/// an explorer link. Persisted per wallet in UserDefaults; only public details are stored, never keys.
struct ActivityRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case swap, launch, buy, sell, perp, send, moment

        var symbol: String {
            switch self {
            case .swap: return "arrow.left.arrow.right"
            case .launch: return "flame.fill"
            case .buy: return "arrow.down"
            case .sell: return "arrow.up"
            case .perp: return "chart.line.uptrend.xyaxis"
            case .send: return "paperplane.fill"
            case .moment: return "camera.aperture"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let txHashHex: String?
    let time: Date

    init(kind: Kind, title: String, subtitle: String, hash: Data?, time: Date = Date()) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.txHashHex = hash?.hexString
        self.time = time
    }

    var txHash: Data? { txHashHex.flatMap { Data(hex: $0) } }
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

    /// Records an action. De-duplicates by tx hash so re-recording the same settled transaction never doubles a row.
    static func record(_ record: ActivityRecord, owner: Address?) {
        guard let owner else { return }
        var list = all(owner: owner)
        if let hash = record.txHashHex { list.removeAll { $0.txHashHex == hash } }
        list.insert(record, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }
}
