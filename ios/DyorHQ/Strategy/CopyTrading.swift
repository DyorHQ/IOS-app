import BigInt
import DyorKit
import Foundation

extension Notification.Name {
    /// Posted on the main actor when the watcher adds copy signals, so any open Strategy view refreshes live
    /// (UserDefaults isn't observable, so views can't otherwise see a signal added while they're on screen).
    static let copySignalsChanged = Notification.Name("copySignalsChanged")
}

// MARK: - Models

/// Which market a copy relationship follows. Spot copies watch a wallet's on-chain buys; perps copies watch its
/// live positions on Perpl.
enum CopyVenue: String, Codable, CaseIterable, Identifiable, Sendable {
    case spot, perps
    var id: String { rawValue }
    var label: String { self == .spot ? "Spot" : "Perps" }
    var blurb: String {
        self == .spot
            ? "Paste memecoin traders' wallets. You're alerted on every buy to confirm or decline."
            : "Copy Perpl perps traders by address. You're alerted when they open a position."
    }
}

/// A trader the user has chosen to copy. Persisted per wallet. `lastBlock` is the spot watcher's checkpoint;
/// `perpsBaselined` + `seenPositions` are the perps watcher's dedup state.
struct CopiedTrader: Codable, Identifiable, Hashable, Sendable {
    let address: Address
    var venue: CopyVenue
    var nickname: String?
    /// Spot only: the token used to fund a copy-buy (USDC by default). Perps copies use AUSD collateral.
    var fundingToken: Address
    var enabled: Bool
    var addedAt: Int
    /// Spot watcher checkpoint: the highest block already scanned. 0 means "not yet baselined".
    var lastBlock: UInt64
    /// Perps watcher state.
    var perpsBaselined: Bool
    var seenPositions: [String]
    // Perps copy config (ported from Nadobro's conviction-weighted sizing): the margin budget committed per copied
    // position and the follower's leverage ceiling. A copied position's size scales with the leader's conviction
    // (its notional vs the leader's largest position) so a probe is copied small and a big bet is copied big.
    var marginPerTrade: Double
    var maxLeverage: Double

    var id: String { venue.rawValue + ":" + address.hex }
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return address.short
    }

    init(address: Address, venue: CopyVenue, nickname: String? = nil, fundingToken: Address = Monad.usdc,
         enabled: Bool = true, addedAt: Int = Int(Date().timeIntervalSince1970), lastBlock: UInt64 = 0,
         perpsBaselined: Bool = false, seenPositions: [String] = [], marginPerTrade: Double = 100, maxLeverage: Double = 10) {
        self.address = address
        self.venue = venue
        self.nickname = nickname
        self.fundingToken = fundingToken
        self.enabled = enabled
        self.addedAt = addedAt
        self.lastBlock = lastBlock
        self.perpsBaselined = perpsBaselined
        self.seenPositions = seenPositions
        self.marginPerTrade = marginPerTrade
        self.maxLeverage = maxLeverage
    }

    // Custom decode so adding fields later never drops a stored trader (missing keys fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(Address.self, forKey: .address)
        venue = try c.decode(CopyVenue.self, forKey: .venue)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        fundingToken = try c.decode(Address.self, forKey: .fundingToken)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        addedAt = try c.decode(Int.self, forKey: .addedAt)
        lastBlock = try c.decode(UInt64.self, forKey: .lastBlock)
        perpsBaselined = try c.decode(Bool.self, forKey: .perpsBaselined)
        seenPositions = try c.decode([String].self, forKey: .seenPositions)
        marginPerTrade = try c.decodeIfPresent(Double.self, forKey: .marginPerTrade) ?? 100
        maxLeverage = try c.decodeIfPresent(Double.self, forKey: .maxLeverage) ?? 10
    }
}

/// A detected copy signal awaiting the user's confirm/decline. Created by the watcher; consumed in Copy Trading.
struct CopySignal: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let traderAddress: Address
    let traderName: String
    let venue: CopyVenue
    let detectedAt: Int
    /// The token the trader bought (spot) or the market's index token (perps).
    let token: Address
    let symbol: String
    let decimals: Int
    let logo: URL?
    /// Human-readable description of what the trader did.
    let action: String
    let traderHash: Data?
    // Perps extras.
    var side: String?
    var marketId: Int?
    var leverage: Double?
    /// Perps: the conviction-weighted copy size (base units) computed from the follower's budget, preset into the ticket.
    var suggestedSize: Double?
}

// MARK: - Store (per-wallet UserDefaults, mirrors PriceAlertStore / ActivityLog)

enum CopyStore {
    private static let tradersPrefix = "copy.traders.v1."
    private static let signalsPrefix = "copy.signals.v1."
    private static let maxSignals = 40

    private static func key(_ prefix: String, _ owner: Address?) -> String {
        prefix + (owner?.hex.lowercased() ?? "none")
    }

    // Traders
    static func traders(owner: Address?) -> [CopiedTrader] {
        guard let data = UserDefaults.standard.data(forKey: key(tradersPrefix, owner)),
              let list = try? JSONDecoder().decode([CopiedTrader].self, from: data) else { return [] }
        return list
    }

    static func setTraders(_ traders: [CopiedTrader], owner: Address?) {
        guard let data = try? JSONEncoder().encode(traders) else { return }
        UserDefaults.standard.set(data, forKey: key(tradersPrefix, owner))
    }

    /// Adds or replaces a trader (same venue+address). Returns false if it already existed.
    @discardableResult
    static func upsert(_ trader: CopiedTrader, owner: Address?) -> Bool {
        var list = traders(owner: owner)
        let existed = list.contains { $0.id == trader.id }
        list.removeAll { $0.id == trader.id }
        list.insert(trader, at: 0)
        setTraders(list, owner: owner)
        return !existed
    }

    static func remove(id: String, owner: Address?) {
        var list = traders(owner: owner)
        list.removeAll { $0.id == id }
        setTraders(list, owner: owner)
        // Drop that trader's pending signals too.
        var pending = signals(owner: owner)
        pending.removeAll { ($0.venue.rawValue + ":" + $0.traderAddress.hex) == id }
        setSignals(pending, owner: owner)
    }

    // Signals
    static func signals(owner: Address?) -> [CopySignal] {
        guard let data = UserDefaults.standard.data(forKey: key(signalsPrefix, owner)),
              let list = try? JSONDecoder().decode([CopySignal].self, from: data) else { return [] }
        return list
    }

    static func setSignals(_ signals: [CopySignal], owner: Address?) {
        guard let data = try? JSONEncoder().encode(Array(signals.prefix(maxSignals))) else { return }
        UserDefaults.standard.set(data, forKey: key(signalsPrefix, owner))
    }

    /// Adds a signal unless one with the same id already exists. Returns true if it was newly added.
    @discardableResult
    static func addSignal(_ signal: CopySignal, owner: Address?) -> Bool {
        var list = signals(owner: owner)
        guard !list.contains(where: { $0.id == signal.id }) else { return false }
        list.insert(signal, at: 0)
        setSignals(list, owner: owner)
        return true
    }

    static func removeSignal(id: String, owner: Address?) {
        var list = signals(owner: owner)
        list.removeAll { $0.id == id }
        setSignals(list, owner: owner)
    }
}
