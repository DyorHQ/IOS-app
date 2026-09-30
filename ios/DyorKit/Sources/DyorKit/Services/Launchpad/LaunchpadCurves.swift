import Foundation

/* A coin still on a launchpad's bonding curve (the live launchpad's once v2 is wired, or a retired one's) trades on
   that curve, from its Launch page, and nowhere else: no Swap venue routes a bonding curve, so Swap can only answer "No
   venue can route this pair". Every screen that offers a held coin a trade asks where it trades first (`CurveRoute`):

     - the Portfolio's holdings (`LaunchpadService.curveHoldings`) and Home's token page (`curveRoute(for:)`) open such
       a coin's Launch page instead of Swap: Buy and Sell on the live launchpad's curve, Sell only on a retired one's
       (`RetiredLaunchpad`). Home's launch holdings open every launch's own page already;
     - Swap's "no venue" state (`curveRoute(among:)`) points to the Launch page of a side still on a curve;
     - a coin that graduated into a pool is an ordinary pool token: it opens Swap.

   One Multicall3 read asks every known factory (`LaunchpadService.stacks`: the live one once deployed, then each retired
   one) for each coin's `getLaunchedToken` record, in that factory's own layout. While v2 is pending (address 0) the live
   stack is left out, so nothing is ever asked of address 0. A check that fails is `.unchecked`: the screen says so and
   offers a way on (check again, or the Launch tab), never a dead end. */

/// Where a held coin trades: Swap, or its Launch page while it is still on a launchpad's bonding curve.
public enum CurveRoute: Sendable, Hashable {
    /// Swap: no known launchpad has the coin on its curve (it graduated into a pool, or none launched it).
    case swap
    /// Its Launch page, where its curve trades: Buy and Sell on the live launchpad, Sell only on a retired one.
    case launchPage(Launch)
    /// On a launchpad's curve (a retired one's when `retired`: sell-only), in `phase` (its factory's record), but its
    /// launch couldn't be read: the Launch tab lists it, in that phase's section (`LaunchPhase.boardSection`: in refund
    /// mode or migrating too).
    case launchTab(retired: Bool, phase: LaunchPhase)
    /// Whether it is on a curve couldn't be checked. Swap stays offered, with a way to check again.
    case unchecked

    /// The launch whose page the coin opens.
    public var launch: Launch? {
        if case .launchPage(let launch) = self { return launch }
        return nil
    }

    /// Still on a launchpad's curve: never Swap.
    public var isOnCurve: Bool {
        switch self {
        case .launchPage, .launchTab: return true
        case .swap, .unchecked: return false
        }
    }

    /// What a coin page (Home's token page, Swap's "no venue" state) says about where the coin trades; nil for Swap.
    public var notice: String? {
        switch self {
        case .swap: return nil
        case .launchPage(let launch):
            if launch.isRetiredLaunchpad { return RetiredLaunchpad.tokenPageNotice(launch) }
            if launch.curveBuysOpen { return LaunchpadCurve.tradeOnLaunchPage }
            if launch.curveSellsOpen { return LaunchpadCurve.refundOnLaunchPage }
            return LaunchpadCurve.graduationPending
        case .launchTab(let retired, let phase):
            switch phase {
            case .refund: return LaunchpadCurve.refundLaunchUnread
            case .migrating: return LaunchpadCurve.migratingLaunchUnread
            case .bonding, .graduated: return retired ? LaunchpadCurve.retiredLaunchUnread : LaunchpadCurve.launchUnread
            }
        case .unchecked: return LaunchpadCurve.unchecked
        }
    }

    /// A holdings row's note in place of the coin's name (the Portfolio); nil where the row opens Swap.
    public var rowNote: String? {
        switch self {
        case .swap, .unchecked: return nil
        case .launchPage(let launch):
            if launch.curveBuysOpen { return "Buy or sell on its Launch page" }
            return launch.curveSellsOpen ? "Sell on its Launch page" : "Graduation pending · Launch page"
        case .launchTab(let retired, let phase):
            switch phase {
            case .refund: return "Sell it back from its page on the Launch tab"
            case .migrating: return "Migrating · Launch tab"
            case .bonding, .graduated: return retired ? "Sell it from its page on the Launch tab" : "Trade it from its page on the Launch tab"
            }
        }
    }

    /// The coin page's button to where `symbol` trades; nil where Swap stays offered.
    public func actionTitle(_ symbol: String) -> String? {
        switch self {
        case .swap, .unchecked: return nil
        case .launchPage(let launch):
            if launch.curveBuysOpen { return "Trade \(symbol) on its Launch page" }
            return launch.curveSellsOpen ? "Sell \(symbol) on its Launch page" : "Open \(symbol)'s Launch page"
        case .launchTab: return "Find \(symbol) on the Launch tab"
        }
    }
}

/// A side of a pair Swap can't route because it is still on a launchpad's curve (`LaunchpadService.curveRoute(among:)`),
/// with where it trades instead.
public struct CurveCoinRoute: Sendable, Hashable {
    public let token: Token
    public let route: CurveRoute

    public init(token: Token, route: CurveRoute) {
        self.token = token
        self.route = route
    }
}

/// A wallet's coins still on a launchpad's bonding curve (`LaunchpadService.curveHoldings`), with their launches.
public struct CurveHoldings: Sendable, Hashable {
    /// Each such coin, with the factory that recorded it: the live one or a retired one.
    public let factories: [Address: Address]
    /// Each such coin's phase in that factory's record: which section of the Launch tab lists a coin whose launch
    /// couldn't be read (`LaunchPhase.boardSection`).
    public let phases: [Address: LaunchPhase]
    /// Their launches, by coin, for a screen to open their Launch page. A coin whose launch couldn't be read has none.
    public let launches: [Address: Launch]

    public static let none = CurveHoldings(factories: [:], phases: [:], launches: [:])

    public init(factories: [Address: Address], phases: [Address: LaunchPhase], launches: [Address: Launch]) {
        self.factories = factories
        self.phases = phases
        self.launches = launches
    }

    /// The coins: Swap can't trade them, so a screen never offers it for one.
    public var coins: Set<Address> { Set(factories.keys) }

    /// Where `token` trades: while it is on a curve, its Launch page (the Launch tab, which lists it in its phase's
    /// section, when its launch couldn't be read); otherwise Swap.
    public func route(_ token: Address) -> CurveRoute {
        guard let factory = factories[token] else { return .swap }
        if let launch = launches[token] { return .launchPage(launch) }
        return .launchTab(retired: LaunchpadAddresses.isRetired(factory), phase: phases[token] ?? .bonding)
    }
}

/// What the app says and checks about coins still on a launchpad's bonding curve, live or retired.
public enum LaunchpadCurve {
    /// A coin on the live launchpad's curve, trading.
    public static let tradeOnLaunchPage = "This coin is still on its launchpad's bonding curve, which Swap can't route: buy and sell it on its Launch page. Once it graduates, it trades on Swap."
    /// A coin on the live launchpad whose launch is in refund mode.
    public static let refundOnLaunchPage = "This coin's launch is in refund mode: sell it back into its curve on its Launch page, at the curve's price with no fees."
    /// A coin on the live launchpad whose full curve waits to graduate, or is migrating.
    public static let graduationPending = "This coin's curve is full and its graduation is pending: it can't be traded until it graduates, and then it trades on Swap."
    /// A coin on the live launchpad's curve whose launch couldn't be read.
    public static let launchUnread = "This coin is still on its launchpad's bonding curve, which Swap can't route, and its launch couldn't be read just now: find it on the Launch tab."
    /// A coin on a retired launchpad's curve whose launch couldn't be read.
    public static let retiredLaunchUnread = "This coin's launchpad is retired: you can sell it from its page on the Launch tab, but not buy. Its launch couldn't be read just now."
    /// A coin in refund mode, on the live launchpad or a retired one, whose launch couldn't be read: the Launch tab lists
    /// it under Refund & Migrating.
    public static let refundLaunchUnread = "This coin's launch is in refund mode: sell it back into its curve from its page on the Launch tab, where it's listed under Refund & Migrating. Its launch couldn't be read just now."
    /// A migrating coin, on the live launchpad or a retired one, whose launch couldn't be read.
    public static let migratingLaunchUnread = "This coin is migrating from its bonding curve to its pool: it can't be traded until it graduates, and then it trades on Swap. Its page is on the Launch tab, under Refund & Migrating; its launch couldn't be read just now."
    /// The check itself failed.
    public static let unchecked = "DyorHQ couldn't check whether this coin is still on a launchpad's bonding curve just now. If it is, it trades on its Launch page, not on Swap: check again in a moment, or find it on the Launch tab."

    /// A coin's record from the first stack that recorded it, while the coin is still on that stack's curve.
    struct CurveRecord: Sendable {
        let stack: LaunchpadAddresses
        let record: LaunchpadABI.LaunchRecord
    }

    /// The coins among `tokens` still on the bonding curve of one of `stacks` (recorded, not graduated: climbing, full and
    /// waiting to graduate, migrating, or in refund mode), each with the first stack in `stacks` that recorded it. One
    /// Multicall3 read asks every stack's factory for every coin's `getLaunchedToken` record, each in its stack's own
    /// layout; a stack not deployed (a pending live one, address 0) is never asked. A factory answers a coin it never
    /// launched with an empty record, so a failed read, or any answer missing, throws: then no coin can be ruled in or out.
    static func curveRecords(_ tokens: [Address], stacks: [LaunchpadAddresses], multicall: Multicall) async throws -> [Address: CurveRecord] {
        let stacks = stacks.filter(\.isDeployed)
        let queries = tokens.filter { !$0.isZero }.flatMap { token in stacks.map { (token: token, stack: $0) } }
        guard !queries.isEmpty else { return [:] }
        let results = try await multicall.read(queries.map {
            LaunchpadABI.call($0.stack.factory, LaunchpadABI.Factory.getLaunchedToken, [.address($0.token)],
                              returns: LaunchpadABI.launchedTokenReturns(legacy: $0.stack.generation.legacyRecord))
        })
        return try curveRecords(queries: queries, results: results)
    }

    /// Pure half of `curveRecords`: `results` holds each query's answer, in order.
    static func curveRecords(queries: [(token: Address, stack: LaunchpadAddresses)], results: [Result<[ABIValue], Error>]) throws -> [Address: CurveRecord] {
        guard results.count == queries.count else { throw LaunchpadError.unexpectedResponse("launchpad records") }
        var out: [Address: CurveRecord] = [:]
        for (query, result) in zip(queries, results) {
            let record = try record(result, legacy: query.stack.generation.legacyRecord)
            if record.isOnCurve, out[query.token] == nil { out[query.token] = CurveRecord(stack: query.stack, record: record) }
        }
        return out
    }

    /// One factory's `getLaunchedToken` answer, decoded in its layout; a missing answer throws.
    static func record(_ result: Result<[ABIValue], Error>, legacy: Bool) throws -> LaunchpadABI.LaunchRecord {
        guard case .success(let values) = result, let tuple = values.first else { throw LaunchpadError.unexpectedResponse("a launchpad record") }
        return LaunchpadABI.LaunchRecord(tuple, legacy: legacy)
    }
}

extension LaunchpadABI.LaunchRecord {
    /// Recorded and not graduated: the coin is on the curve's side of graduation, which no Swap venue routes.
    var isOnCurve: Bool { exists && phase != .graduated }
}

public extension LaunchpadService {
    /// The coins among a wallet's `holdings` still on a launchpad's bonding curve, the live launchpad's (once deployed) or
    /// a retired one's, each with its launch, so a list of holdings (the Portfolio) opens a coin's Launch page, where its
    /// curve trades, instead of Swap, which routes no curve. One aggregate asks every known factory (`stacks`) for each
    /// coin's record (MON and the app's own tokens are never asked); then each stack's coins are read as launches
    /// (`hydrate`, in chunks), from those records. A stack whose launch read fails leaves every one of its coins without a launch
    /// (they open the Launch tab): that includes a stack one of whose coins has a protocol value that can't be read, since
    /// `hydrate` then throws for the whole read. Throws when the aggregate fails: then no coin could be ruled in or out.
    func curveHoldings(_ holdings: [Token]) async throws -> CurveHoldings {
        var seen = Set<Address>()
        let candidates = holdings.filter { SwapEngine.mayBeLaunchCoin($0) && seen.insert($0.address).inserted }.map(\.address)
        guard !candidates.isEmpty else { return .none }
        let found = try await LaunchpadCurve.curveRecords(candidates, stacks: stacks, multicall: multicall)
        guard !found.isEmpty else { return .none }
        var byFactory: [Address: [LaunchpadABI.LaunchRecord]] = [:]
        for token in candidates { if let hit = found[token] { byFactory[hit.stack.factory, default: []].append(hit.record) } }
        var launches: [Address: Launch] = [:]
        await withTaskGroup(of: [Launch].self) { group in
            for (factory, records) in byFactory {
                group.addTask { (try? await self.hydrate(records, factory: factory)) ?? [] }
            }
            for await list in group { for launch in list { launches[launch.token] = launch } }
        }
        return CurveHoldings(factories: found.mapValues(\.stack.factory), phases: found.mapValues(\.record.phase), launches: launches)
    }

    /// Where one coin trades, for a screen that knows only the coin (Home's token page): its Launch page while it is on a
    /// launchpad's curve, else Swap; `.unchecked` when the check fails. MON and the app's own tokens are Swap unread.
    func curveRoute(for token: Token) async -> CurveRoute {
        guard SwapEngine.mayBeLaunchCoin(token) else { return .swap }
        do { return try await curveHoldings([token]).route(token.address) } catch { return .unchecked }
    }

    /// For Swap's "no venue" state: the first of `tokens` (the pair's sides) still on a launchpad's curve, with its route,
    /// all sides in one check. When the check fails, the first side that may be a launch coin, `.unchecked`. Nil when no
    /// side is on a curve (or none could be a launch coin): then no venue simply has a route.
    func curveRoute(among tokens: [Token]) async -> CurveCoinRoute? {
        let candidates = tokens.filter(SwapEngine.mayBeLaunchCoin)
        guard let first = candidates.first else { return nil }
        let holdings: CurveHoldings
        do { holdings = try await curveHoldings(candidates) } catch { return CurveCoinRoute(token: first, route: .unchecked) }
        for token in candidates where holdings.route(token.address) != .swap {
            return CurveCoinRoute(token: token, route: holdings.route(token.address))
        }
        return nil
    }
}
