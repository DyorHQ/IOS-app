import BigInt
import DyorKit
import Foundation

extension Notification.Name {
    /// Posted on the main actor whenever a delta-neutral strategy's runtime changes (a slice landed, the watcher
    /// refreshed funding or health, an exit finished), so open dashboards refresh.
    static let dnStrategyChanged = Notification.Name("dnStrategyChanged")
}

/// One delta-neutral position: long `spotToken` on a Monad venue, short the same size on Perpl market `marketId`,
/// collecting funding while longs pay shorts. Persisted per wallet with its parameters, the entry/exit progress
/// (so a run interrupted by the app leaving the foreground resumes where it stopped) and the accounting the
/// dashboard shows. Amounts in this record are what actually happened on chain, not what was planned.
struct DNStrategy: Codable, Identifiable, Hashable {
    enum Status: String, Codable, Hashable {
        /// TWAP entry in progress (or paused between slices).
        case entering
        /// Both legs on; the watcher monitors funding and health.
        case running
        /// Unwinding: closing the short, then selling the spot.
        case exiting
        /// Fully unwound.
        case closed
        /// A step failed and needs the user (the dashboard offers Retry / Exit).
        case failed

        var title: String {
            switch self {
            case .entering: return "Entering"
            case .running: return "Running"
            case .exiting: return "Exiting"
            case .closed: return "Closed"
            case .failed: return "Needs attention"
            }
        }
    }

    /// One thing the runner or watcher did or saw, for the dashboard's event log.
    struct Event: Codable, Hashable, Identifiable {
        var id = UUID()
        let time: Date
        let text: String
        let txHashHex: String?
        var txHash: Data? { txHashHex.flatMap { Data(hex: $0) } }
    }

    var id: String
    let marketId: Int
    let symbol: String
    let priceDecimals: Int
    let lotDecimals: Int
    let spotToken: Address
    let spotSymbol: String
    let spotDecimals: Int
    var parameters: DeltaNeutral.Parameters
    let createdAt: Date
    var status: Status
    var paused: Bool

    // Plan (fixed at start, from the live price then).
    let targetPerpSize: Double
    let targetNotional: Double
    let perpMargin: Double
    let referencePrice: Double
    let slices: Int
    let sliceAmountIn: String // raw USDC units per slice, as a decimal string (BigUInt is not Codable)

    // Entry progress / accounting.
    var slicesDone: Int
    var spotAcquiredUnits: Double
    var spotSpentUSD: Double
    /// Quoted execution cost of the spot slices (impact + venue fee vs the venue's marginal price), in USD.
    var spotImpactCostUSD: Double
    var perpShortSize: Double
    var perpEntryFeeUSD: Double
    var perpEntryNotional: Double
    var gasSpentMON: Double
    var collateralDepositedUSD: Double
    var nextSliceAt: Date?

    // Exit accounting.
    var spotSoldUnits: Double
    var spotProceedsUSD: Double
    var exitedAt: Date?
    var fundingRealizedAtExit: Double

    // Monitoring state.
    var lastFundingHourly: Double?
    var lastFundingSignPositive: Bool?
    var lastSettlementBlock: UInt64
    var intervalsBelowThreshold: Int
    var lastLiquidationAlertAt: Date?
    var lastDriftAlertAt: Date?
    var lastError: String?
    var events: [Event]

    var sliceAmount: BigUInt { BigUInt(sliceAmountIn) ?? 0 }
    /// Spot still held by the strategy: bought minus sold, with floating-point dust (below a satoshi) treated as zero.
    var spotHeldUnits: Double {
        let units = spotAcquiredUnits - spotSoldUnits
        return abs(units) < 1e-8 ? 0 : units
    }
    var isActive: Bool { status == .entering || status == .running || status == .exiting || status == .failed }
    var entryComplete: Bool { slicesDone >= slices }
    var startedAgo: String { RelativeTime.short(Int(createdAt.timeIntervalSince1970)) }

    init(marketId: Int, symbol: String, priceDecimals: Int, lotDecimals: Int, spot: DeltaNeutral.SpotOption, parameters: DeltaNeutral.Parameters,
         sizing: DeltaNeutral.Sizing, sliceAmountIn: BigUInt) {
        id = UUID().uuidString
        self.marketId = marketId
        self.symbol = symbol
        self.priceDecimals = priceDecimals
        self.lotDecimals = lotDecimals
        spotToken = spot.token.address
        spotSymbol = spot.token.symbol
        spotDecimals = spot.token.decimals
        self.parameters = parameters
        createdAt = Date()
        status = .entering
        paused = false
        targetPerpSize = sizing.perpSize
        targetNotional = sizing.notional
        perpMargin = sizing.perpMargin
        referencePrice = sizing.price
        slices = max(1, parameters.twapSlices)
        self.sliceAmountIn = String(sliceAmountIn)
        slicesDone = 0
        spotAcquiredUnits = 0
        spotSpentUSD = 0
        spotImpactCostUSD = 0
        perpShortSize = 0
        perpEntryFeeUSD = 0
        perpEntryNotional = 0
        gasSpentMON = 0
        collateralDepositedUSD = 0
        nextSliceAt = nil
        spotSoldUnits = 0
        spotProceedsUSD = 0
        exitedAt = nil
        fundingRealizedAtExit = 0
        lastFundingHourly = nil
        lastFundingSignPositive = nil
        lastSettlementBlock = 0
        intervalsBelowThreshold = 0
        lastLiquidationAlertAt = nil
        lastDriftAlertAt = nil
        lastError = nil
        events = []
    }

    var spotTokenModel: Token {
        Token.core.first { $0.address == spotToken } ?? Token(address: spotToken, symbol: spotSymbol, name: spotSymbol, decimals: spotDecimals)
    }

    mutating func log(_ text: String, hash: Data? = nil) {
        events.insert(Event(time: Date(), text: text, txHashHex: hash?.hexString), at: 0)
        if events.count > 100 { events = Array(events.prefix(100)) }
    }
}

/// Per-wallet persistence for delta-neutral strategies (mirrors MMStore / CopyStore).
enum DNStore {
    private static let prefix = "dn.strategies.v1."
    private static func key(_ owner: Address?) -> String { prefix + (owner?.hex.lowercased() ?? "none") }

    static func strategies(owner: Address?) -> [DNStrategy] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)),
              let list = try? JSONDecoder().decode([DNStrategy].self, from: data) else { return [] }
        return list
    }

    static func save(_ strategies: [DNStrategy], owner: Address?) {
        guard let data = try? JSONEncoder().encode(strategies) else { return }
        UserDefaults.standard.set(data, forKey: key(owner))
    }

    static func upsert(_ strategy: DNStrategy, owner: Address?) {
        var list = strategies(owner: owner)
        if let i = list.firstIndex(where: { $0.id == strategy.id }) { list[i] = strategy } else { list.insert(strategy, at: 0) }
        save(list, owner: owner)
        NotificationCenter.default.post(name: .dnStrategyChanged, object: nil)
    }

    static func remove(id: String, owner: Address?) {
        save(strategies(owner: owner).filter { $0.id != id }, owner: owner)
        NotificationCenter.default.post(name: .dnStrategyChanged, object: nil)
    }

    static func active(owner: Address?) -> [DNStrategy] { strategies(owner: owner).filter(\.isActive) }
    static func find(id: String, owner: Address?) -> DNStrategy? { strategies(owner: owner).first { $0.id == id } }
}
