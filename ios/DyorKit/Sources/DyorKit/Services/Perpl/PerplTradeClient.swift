import Foundation
import Observation

/* The authenticated Perpl trading WebSocket (wss://app.perpl.xyz/ws/v1/trading): sign in with the Ed25519 key,
   then place market / limit / stop / take-profit orders as mt:22 frames. Stop and take-profit are keeper-managed
   trigger orders — the only way to get real TP/SL, since the on-chain Exchange has no trigger primitive. Order
   placement/cancel/modify all flow through here; positions and open orders are still read from the contract. */

/// One order to send as an `mt:22` frame. Prices/sizes are scaled to the market's decimals here.
public struct PerplOrderFrame: Sendable {
    public enum TriggerCondition: Int, Sendable { case gteLast = 1, lteLast = 2, gteMark = 3, lteMark = 4 }

    public var type: PerpOrderType        // 0-indexed enum; mapped to the WS 1-indexed `t`
    public var marketId: Int
    public var accountId: Int
    public var pricePNS: Int              // scaled; 0 = market
    public var lotLNS: Int                // scaled size
    public var leverageHdths: Int         // leverage × 100 (0 for cancels / triggers)
    public var slippageBps: Int?          // `ms`, market orders
    public var ioc: Bool                  // fl: 4 IOC vs 0 GTC
    public var lastExecutionBlock: Int    // `lb`; 0 for triggers
    public var triggerPricePNS: Int?      // `tp`
    public var triggerCondition: TriggerCondition?
    public var linkedPositionId: Int?     // `lp`
    public var linkedRequestId: Int?      // `tr` — activate when this request trades (attach a trigger to an entry)
    public var orderId: Int?              // `oid`, for cancel/change
    /// A pre-assigned request id, so a trigger can reference the entry it links to via `tr`.
    public var requestId: Int?

    public init(type: PerpOrderType, marketId: Int, accountId: Int, pricePNS: Int, lotLNS: Int, leverageHdths: Int,
                slippageBps: Int? = nil, ioc: Bool, lastExecutionBlock: Int, triggerPricePNS: Int? = nil,
                triggerCondition: TriggerCondition? = nil, linkedPositionId: Int? = nil, linkedRequestId: Int? = nil,
                orderId: Int? = nil, requestId: Int? = nil) {
        self.type = type; self.marketId = marketId; self.accountId = accountId; self.pricePNS = pricePNS
        self.lotLNS = lotLNS; self.leverageHdths = leverageHdths; self.slippageBps = slippageBps; self.ioc = ioc
        self.lastExecutionBlock = lastExecutionBlock; self.triggerPricePNS = triggerPricePNS
        self.triggerCondition = triggerCondition; self.linkedPositionId = linkedPositionId
        self.linkedRequestId = linkedRequestId; self.orderId = orderId; self.requestId = requestId
    }

    /// The wire type `t` (1-indexed on the WS API; the enum is 0-indexed).
    public var wireType: Int { type.rawValue + 1 }

    /// The `mt:22` JSON object, given the request id `rq` and correlation `sn`.
    public func json(rq: Int, sn: Int) -> [String: Any] {
        var frame: [String: Any] = [
            "mt": 22, "sn": sn, "rq": rq, "mkt": marketId, "acc": accountId,
            "t": wireType, "p": pricePNS, "s": lotLNS, "fl": ioc ? 4 : 0, "lv": leverageHdths, "lb": lastExecutionBlock,
        ]
        if let slippageBps { frame["ms"] = slippageBps }
        if let triggerPricePNS { frame["tp"] = triggerPricePNS }
        if let triggerCondition { frame["tpc"] = triggerCondition.rawValue }
        if let linkedPositionId { frame["lp"] = linkedPositionId }
        if let linkedRequestId { frame["tr"] = linkedRequestId }
        if let orderId { frame["oid"] = orderId }
        return frame
    }
}

/// Builds the order frames for a ticket: the entry order, plus optional take-profit and stop-loss triggers.
public enum PerplOrders {
    // `Int(exactly:)`, not `Int(_:)`: a non-finite or out-of-range value (a pasted "1e300") becomes 0 — an order Perpl
    // refuses — instead of trapping.
    private static func scalePrice(_ price: Double, _ market: PerpMarket) -> Int { Int(exactly: (price * pow(10, Double(market.priceDecimals))).rounded()) ?? 0 }
    private static func scaleSize(_ size: Double, _ market: PerpMarket) -> Int { Int(exactly: (size * pow(10, Double(market.lotDecimals))).rounded()) ?? 0 }

    /// The entry order. A market order is a marketable-limit IOC at the slippage bound (`p:0`, `ms`, `fl:4`).
    ///
    /// `lb` (last-execution block) is sent as `0`: Perpl then substitutes the market's OWN maximum window
    /// (`order_ttl_blocks`). Computing `head + ttlBlocks` ourselves — from the RPC block, which runs ahead of Perpl's
    /// heartbeat head — overshot that ceiling and every entry was rejected with `last exec block too high` (which is
    /// why authenticated market/limit orders and TP/SL brackets all failed once one-click was on). The
    /// `head`/`ttlBlocks` parameters are kept for source compatibility but no longer bound the entry.
    public static func entry(_ input: OrderInput, accountId: Int, head: Int, ttlBlocks: Int = 100) -> PerplOrderFrame {
        let type: PerpOrderType = input.reduceOnly
            ? (input.side == .long ? .closeShort : .closeLong)     // reduce-only market close
            : (input.side == .long ? .openLong : .openShort)
        let market = input.kind == .market
        return PerplOrderFrame(
            type: type, marketId: input.market.id, accountId: accountId,
            pricePNS: market ? 0 : scalePrice(input.price ?? input.market.mark, input.market),
            lotLNS: scaleSize(input.size, input.market),
            leverageHdths: Int((input.leverage * 100).rounded()),
            slippageBps: market ? input.slippageBps : nil,
            ioc: market,
            lastExecutionBlock: 0
        )
    }

    /// A take-profit trigger that closes `size` of a `side` position at `price`. Long TP fires when price rises
    /// (GTE Last); short TP fires when price falls (LTE Last). Market on trigger (`p:0`, IOC, `lb:0`).
    public static func takeProfit(side: PositionSide, price: Double, size: Double, market: PerpMarket, accountId: Int, linkedPositionId: Int?) -> PerplOrderFrame {
        PerplOrderFrame(
            type: side == .long ? .closeLong : .closeShort, marketId: market.id, accountId: accountId,
            pricePNS: 0, lotLNS: scaleSize(size, market), leverageHdths: 0, ioc: true, lastExecutionBlock: 0,
            triggerPricePNS: scalePrice(price, market),
            triggerCondition: side == .long ? .gteLast : .lteLast, linkedPositionId: linkedPositionId
        )
    }

    /// A stop-loss trigger. Long SL fires when the mark falls (LTE Mark); short SL when the mark rises (GTE Mark).
    public static func stopLoss(side: PositionSide, price: Double, size: Double, market: PerpMarket, accountId: Int, linkedPositionId: Int?) -> PerplOrderFrame {
        PerplOrderFrame(
            type: side == .long ? .closeLong : .closeShort, marketId: market.id, accountId: accountId,
            pricePNS: 0, lotLNS: scaleSize(size, market), leverageHdths: 0, ioc: true, lastExecutionBlock: 0,
            triggerPricePNS: scalePrice(price, market),
            triggerCondition: side == .long ? .lteMark : .gteMark, linkedPositionId: linkedPositionId
        )
    }

    public static func cancel(perpId: Int, orderId: Int, accountId: Int, head: Int) -> PerplOrderFrame {
        // `lb: 0` for the same reason as `entry` — a computed `head + 100` can exceed the market's ceiling and be
        // rejected with `last exec block too high`.
        PerplOrderFrame(type: .cancel, marketId: perpId, accountId: accountId, pricePNS: 0, lotLNS: 0, leverageHdths: 0, ioc: false, lastExecutionBlock: 0, orderId: orderId)
    }

    /// Why `frame` must not be sent, or nil. The scaling above turns a price below one tick into 0, and on Perpl a
    /// 0 means something else: a trigger with `tp: 0` is a plain reduce-only market close that executes the moment it
    /// is admitted (a take-profit or stop-loss typed as "0" would close the position at once), and a resting order
    /// with `p: 0` is a market order. Checked for every frame before any is sent, so a bracket is refused whole.
    public static func problem(_ frame: PerplOrderFrame) -> String? {
        switch frame.type {
        case .cancel, .change, .increasePositionCollateral:
            return nil
        case .openLong, .openShort, .closeLong, .closeShort:
            if frame.lotLNS <= 0 { return "The order size rounds to zero on this market." }
            if frame.triggerCondition != nil || frame.triggerPricePNS != nil {
                guard frame.type == .closeLong || frame.type == .closeShort else { return "A take-profit or stop-loss can only close a position." }
                guard (frame.triggerPricePNS ?? 0) > 0, frame.triggerCondition != nil else { return "The take-profit or stop-loss price rounds to zero on this market." }
                return nil
            }
            if !frame.ioc, frame.pricePNS <= 0 { return "The limit price rounds to zero on this market." }
            return nil
        }
    }
}

/// The result of an order request: the gateway ack (`mt:3`). `code == 0` means accepted for forwarding.
public struct PerplOrderAck: Sendable {
    public let code: Int
    public let error: String?
    /// The frame went out but no status came back (the ack timed out, or the socket closed while waiting): Perpl may
    /// have placed it, so it is neither accepted nor rejected — the caller says so and never resends it blindly.
    public let outcomeUnknown: Bool
    public var accepted: Bool { code == 0 && !outcomeUnknown }

    public init(code: Int, error: String?, outcomeUnknown: Bool = false) {
        self.code = code
        self.error = error
        self.outcomeUnknown = outcomeUnknown
    }
}

public enum PerplTradeError: LocalizedError {
    case notSignedIn, noAccount, forwardingDisabled, timeout, closed(String)
    /// The trading socket is not connected, so nothing was sent (the message says why).
    case unavailable(String)
    /// Refused on the device before anything was sent: the frame would not do what the ticket says (a zero trigger
    /// price is a market close that fires at once, a zero-price limit is a market order).
    case invalidOrder(String)
    /// The order frame was already sent when this happened (no acknowledgement, or the socket closed while waiting),
    /// so Perpl may have placed it: the caller must not offer an immediate resend.
    public var outcomeUnknown: Bool {
        switch self {
        case .timeout, .closed: return true
        case .notSignedIn, .noAccount, .forwardingDisabled, .unavailable, .invalidOrder: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not connected to Perpl trading."
        case .noAccount: return "No Perpl trading account. Deposit AUSD first."
        case .forwardingDisabled: return "Enable one-click trading (order forwarding) on your Perpl account first."
        case .timeout: return "Perpl did not acknowledge the order in time."
        case .closed(let why): return why // already a full sentence from PerplClose.message
        case .unavailable(let why): return why
        case .invalidOrder(let why): return why
        }
    }
}

/// Why the trading socket closed, as the server reported it: the RFC 6455 close code plus Perpl's reason string
/// (api-docs README → "WebSocket Close Codes"). URLSession surfaces every server-initiated close as the same generic
/// "Socket is not connected" — the code and reason on the task are the only way to tell an idle timeout from a
/// rejected key from the per-wallet connection cap, so they are kept and turned into a specific message here.
public struct PerplClose: Sendable, Equatable {
    public let code: Int
    public let reason: String

    /// 3401 — the API key was rejected. Retrying with the same key can never succeed; the user must re-enroll.
    public var isAuthFailure: Bool { code == 3401 }
    /// 1008 "too many connections" — Perpl allows 4 trading sockets per WALLET (shared with app.perpl.xyz tabs).
    public var isConnectionCap: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many connections") }
    public var isRateLimit: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many requests") }

    public var message: String {
        switch code {
        case 3401:
            return "Perpl rejected this trading key. Remove the API key below and connect again to enroll a fresh one."
        case 1008 where isConnectionCap:
            return "Too many Perpl trading connections for this wallet — Perpl allows 4, shared with the Perpl web app. Close other Perpl sessions (or wait a minute) and try again."
        case 1008 where isRateLimit:
            return "Perpl's trading rate limit was hit. Wait a moment and try again."
        case 1008:
            return "Perpl closed the idle trading connection (\(reason)). It reconnects on your next order."
        case 1011:
            return "Perpl couldn't process a trading frame (\(reason)). Reconnect and try again."
        case 1013:
            return "Perpl dropped the trading connection because the app fell behind reading it. Try again."
        case 1001:
            return "Perpl's trading server is restarting. Try again in a moment."
        case 0:
            return reason.isEmpty ? "Perpl trading connection was lost." : "Perpl trading connection was lost: \(reason)."
        default:
            return reason.isEmpty ? "Perpl trading connection closed (code \(code))." : "Perpl trading connection closed (\(code): \(reason))."
        }
    }
}

/// One open order from the authenticated trading stream (mt:23/24) — a resting limit order or a pending keeper trigger
/// (TP/SL). Prices and sizes are the market's scaled integers (the market's decimals live in the app layer, so scaling
/// happens where a `PerpMarket` is in hand). `OrderType` here is Perpl's 1-indexed API enum, NOT the 0-indexed on-chain
/// `PerpOrderType`.
public struct PerplOpenOrder: Identifiable, Sendable, Hashable {
    public let oid: Int
    public let marketId: Int
    public let typeRaw: Int              // 1 OpenLong, 2 OpenShort, 3 CloseLong, 4 CloseShort
    public let statusRaw: Int            // 2 Open, 3 PartiallyFilled, 8 Untriggered, 9 Triggered
    public let priceRaw: Int             // limit price (0 = market)
    public let sizeRaw: Int              // original size
    public let filledRaw: Int
    public let triggerPriceRaw: Int?     // `tp`
    public let triggerConditionRaw: Int? // `tpc`: 1/2 last-based (take-profit), 3/4 mark-based (stop-loss)
    public let linkedPositionId: Int?
    public let leverageHundredths: Int
    public var id: Int { oid }

    public init(oid: Int, marketId: Int, typeRaw: Int, statusRaw: Int, priceRaw: Int, sizeRaw: Int, filledRaw: Int,
                triggerPriceRaw: Int?, triggerConditionRaw: Int?, linkedPositionId: Int?, leverageHundredths: Int) {
        self.oid = oid; self.marketId = marketId; self.typeRaw = typeRaw; self.statusRaw = statusRaw
        self.priceRaw = priceRaw; self.sizeRaw = sizeRaw; self.filledRaw = filledRaw
        self.triggerPriceRaw = triggerPriceRaw; self.triggerConditionRaw = triggerConditionRaw
        self.linkedPositionId = linkedPositionId; self.leverageHundredths = leverageHundredths
    }

    /// A keeper trigger (take-profit / stop-loss) rather than a plain resting order.
    public var isTrigger: Bool { (triggerPriceRaw ?? 0) != 0 }
    public var isReduceOnly: Bool { typeRaw == 3 || typeRaw == 4 }
    /// The side of the position a reduce-only trigger protects: CloseLong (3) protects a long.
    public var protectsLong: Bool { typeRaw == 3 }
    /// The trigger fires when price rises through it (GTE conditions 1/3) vs falls through it (LTE 2/4).
    private var firesOnRise: Bool { triggerConditionRaw == 1 || triggerConditionRaw == 3 }
    /// Take-profit vs stop-loss is defined by the close side and direction — a long is stopped out when price falls
    /// and takes profit when it rises (the reverse for a short) — NOT by whether last or mark is watched. This
    /// classifies triggers placed anywhere (including the Perpl web app), not only this app's own last/mark convention.
    public var isStopLoss: Bool { protectsLong ? !firesOnRise : firesOnRise }
    /// A resting order that can still open or grow a position (OpenLong / OpenShort, not a trigger). A trigger attached
    /// to such an entry (`tr`) waits for it to fill, so the triggers on its market are never treated as orphaned.
    public var isRestingEntry: Bool { !isTrigger && (typeRaw == 1 || typeRaw == 2) }
}

/// One position from the authenticated stream (mt:26 snapshot, mt:27 updates). `pid` is the id a trigger links to
/// (`lp`): Perpl cancels a position-linked trigger itself when that position closes or inverts. Size is the market's
/// scaled integer, like `PerplOpenOrder`.
public struct PerplLivePosition: Sendable, Hashable {
    public let pid: Int
    public let marketId: Int
    public let isLong: Bool
    public let sizeRaw: Int
    /// 1 Open, 2 Closed, 3 Liquidated, 4 Deleveraged, 5 Unwound, 6 Failed.
    public let statusRaw: Int

    public init(pid: Int, marketId: Int, isLong: Bool, sizeRaw: Int, statusRaw: Int) {
        self.pid = pid; self.marketId = marketId; self.isLong = isLong; self.sizeRaw = sizeRaw; self.statusRaw = statusRaw
    }

    public var isOpen: Bool { statusRaw == 1 && sizeRaw > 0 }
    public var wasLiquidated: Bool { statusRaw == 3 }
    /// Closed by the protocol rather than by an order: liquidated, deleveraged or unwound.
    public var endedByProtocol: Bool { statusRaw == 3 || statusRaw == 4 || statusRaw == 5 }
}

/// A keeper trigger (take-profit / stop-loss) changing state on the authenticated stream: it fired (Perpl is closing
/// the position), or it failed — refused after the gateway admitted it, or it fired and could not execute, which
/// leaves the position open without that protection.
public struct PerplTriggerEvent: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case triggered
        /// `reason` is Perpl's `sr` (OrderStatusReason), e.g. 64 TriggeredExecutionAttemptsExhausted.
        case failed(reason: Int)
    }
    public let order: PerplOpenOrder
    public let outcome: Outcome

    public init(order: PerplOpenOrder, outcome: Outcome) {
        self.order = order
        self.outcome = outcome
    }
}

/// Live authenticated connection: signs in, tracks the account (id, forwarding, request-id seed) and places orders.
@Observable
@MainActor
public final class PerplTradeClient {
    public private(set) var signedIn = false
    public private(set) var accountId: Int?
    public private(set) var forwardingEnabled = false
    public private(set) var error: String?
    /// The account's live open orders — resting limit orders AND pending keeper triggers (TP/SL) — as the authenticated
    /// stream reports them (mt:23 snapshot on connect, mt:24 updates after). This is the ONLY authoritative source for
    /// pending triggers, since they never touch the on-chain order book. Empty until the first snapshot arrives.
    public private(set) var openOrders: [PerplOpenOrder] = []
    private var ordersByOid: [Int: PerplOpenOrder] = [:]
    /// The mt:23 snapshot has arrived on this socket, so `openOrders` is the whole set rather than whatever updates
    /// came in first. Until then (and on a socket that dropped) the list proves nothing about what is live.
    public private(set) var hasOrdersSnapshot = false
    /// The account's open positions as the authenticated stream reports them (mt:26 snapshot, mt:27 updates) — the
    /// source of the position id a trigger links to (`lp`).
    public private(set) var positions: [PerplLivePosition] = []
    private var positionsByPid: [Int: PerplLivePosition] = [:]
    public private(set) var hasPositionsSnapshot = false
    /// Fired on the main actor whenever `openOrders` changes, so the owner can republish it.
    public var onOrdersUpdate: (@MainActor () -> Void)?
    /// Fired on the main actor when a trigger fires or fails (from mt:24 updates only — a snapshot is state, not a
    /// transition). Each trigger reports each outcome once.
    public var onTriggerEvent: (@MainActor (PerplTriggerEvent) -> Void)?
    /// Fired on the main actor when an update (mt:27) reports a position that is no longer open — closed by an order,
    /// or liquidated, deleveraged or unwound — after `positions` already reflects it.
    public var onPositionEnded: (@MainActor (PerplLivePosition) -> Void)?
    private var announcedTriggers: Set<String> = []
    private var endedPositions: Set<Int> = []
    /// Order requests between their first frame and their last ack (`place`, `placeAll`, `sendEach`).
    private var requestsInFlight = 0
    /// Fired on the main actor whenever account state (id / forwardingEnabled / lfr) changes — from the initial
    /// snapshot or a later AccountUpdate — so the owner can re-derive its status the moment forwarding turns on.
    public var onAccountUpdate: (@MainActor () -> Void)?
    /// Fired on the main actor when the socket drops, so the owner can flip status off `.connected` and reconnect on
    /// next use (the socket has no reconnect of its own).
    public var onDisconnect: (@MainActor () -> Void)?
    /// How the last socket ended, from the server's close frame — read it in `onDisconnect` to decide whether a
    /// retry can help (idle timeout: yes; 3401 rejected key: never; connection cap: only after backing off).
    public private(set) var lastClose: PerplClose?
    private var keepAlive: Task<Void, Never>?

    private let chainId: Int
    private let wsURL: URL
    private let key: PerplApiKey
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var lastForwardedRq = 0
    private var snCounter = 0
    private var pending: [Int: CheckedContinuation<PerplOrderAck, Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?

    public init(key: PerplApiKey, chainId: Int = 143, wsURL: URL = URL(string: "wss://app.perpl.xyz/ws/v1/trading")!, session: URLSession = .shared) {
        self.chainId = chainId
        self.key = key
        self.wsURL = wsURL
        self.session = session
    }

    /// Something sent on this socket is still waiting for Perpl: an order request mid-way through its frames, or a
    /// frame whose ack hasn't come back. Closing the socket now would leave its outcome unknown.
    public var hasRequestsInFlight: Bool { requestsInFlight > 0 || !pending.isEmpty }

    /// Connects and signs in, resolving once the WalletSnapshot has seeded the account and request-id counter.
    public func connect(timeout: TimeInterval = 10) async throws {
        if self.task != nil { disconnect() } // one socket per client, ever
        lastClose = nil
        hasOrdersSnapshot = false
        hasPositionsSnapshot = false
        let socket = session.webSocketTask(with: wsURL)
        self.task = socket
        socket.resume()
        // Sign in as the very first frame: Perpl closes the socket (1008 idle timeout) if it doesn't arrive promptly.
        try signIn()
        receive(on: socket)
        // Keep the socket alive with Perpl's APPLICATION ping (`mt:1`, api-docs websocket.md → Keep-Alive). A
        // WebSocket protocol ping is answered at the edge and never reaches Perpl as activity, so the server's idle
        // timeout would still close the socket between orders. 30s = 2 requests/min of the 120/min budget.
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.send(["mt": 1, "t": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            // Scoped to THIS socket: a stale attempt's timer must never fail a later connect's continuation.
            Task { try? await Task.sleep(for: .seconds(timeout)); if self.task === socket { self.failConnect(PerplTradeError.timeout) } }
        }
    }

    /// Tears the socket down and fails anything still waiting on it (an in-flight connect, unacknowledged orders),
    /// so no caller can hang on a socket that no longer exists.
    public func disconnect() {
        keepAlive?.cancel()
        keepAlive = nil
        let open = task
        task = nil
        signedIn = false
        hasOrdersSnapshot = false
        hasPositionsSnapshot = false
        open?.cancel(with: .goingAway, reason: nil)
        let closed = PerplTradeError.closed("Trading connection was closed.")
        failConnect(closed)
        for (_, c) in pending { c.resume(throwing: closed) }
        pending.removeAll()
    }

    /// Places the frames in order (entry first, then triggers), returning the entry's ack. Triggers are sent
    /// best-effort after the entry is accepted.
    public func place(_ frames: [PerplOrderFrame]) async throws -> PerplOrderAck {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var firstAck: PerplOrderAck?
        for frame in frames {
            let ack = try await send(frame)
            if firstAck == nil { firstAck = ack }
            if !ack.accepted { break }
        }
        return firstAck ?? PerplOrderAck(code: -1, error: "No frames")
    }

    /// Places the frames in order and returns EVERY frame's ack (stopping after the first rejection). Lets a caller
    /// verify that a linked take-profit / stop-loss actually landed, not just the entry — critical for a bracket that
    /// must never leave a position unprotected.
    public func placeAll(_ frames: [PerplOrderFrame]) async throws -> [PerplOrderAck] {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var acks: [PerplOrderAck] = []
        for (index, frame) in frames.enumerated() {
            let ack: PerplOrderAck
            do {
                ack = try await send(frame)
            } catch where index > 0 {
                // The entry was already acknowledged: this trigger isn't accepted, so the caller warns that the position
                // may be unprotected, instead of failing the whole bracket, which the order sheet would show as a failed
                // order — inviting a second entry. Sent and unanswered is "unknown" (it may be live); never sent is not.
                acks.append(Self.unanswered(error, fallback: "Perpl did not confirm this trigger."))
                continue
            }
            acks.append(ack)
            // Only a rejected ENTRY ends the bracket. A rejected take-profit must not keep the stop-loss from being sent
            // — the position would open with no stop at all.
            if !ack.accepted, index == 0 { break }
        }
        return acks
    }

    /// Sends each frame in turn and returns every frame's ack, whatever the others did — for independent requests such
    /// as cancelling several triggers. Throws only when nothing could be sent.
    public func sendEach(_ frames: [PerplOrderFrame]) async throws -> [PerplOrderAck] {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var acks: [PerplOrderAck] = []
        for frame in frames {
            do { acks.append(try await send(frame)) } catch { acks.append(Self.unanswered(error, fallback: "Perpl did not confirm this request.")) }
        }
        return acks
    }

    /// Checks a request before its first frame goes out: signed in, forwarding on, and every frame sendable.
    private func admit(_ frames: [PerplOrderFrame]) throws {
        guard signedIn, task != nil, accountId != nil else { throw PerplTradeError.notSignedIn }
        guard forwardingEnabled else { throw PerplTradeError.forwardingDisabled }
        if let problem = frames.lazy.compactMap(PerplOrders.problem).first { throw PerplTradeError.invalidOrder(problem) }
    }

    /// The ack to report for a frame whose send threw: unknown if it went out (Perpl may have it), rejected if not.
    private static func unanswered(_ error: Error, fallback: String) -> PerplOrderAck {
        let unknown = (error as? PerplTradeError)?.outcomeUnknown ?? true
        return PerplOrderAck(code: -1, error: (error as? LocalizedError)?.errorDescription ?? fallback, outcomeUnknown: unknown)
    }

    /// The next strictly-increasing request id, seeded from the account's last-forwarded id.
    public func nextRequestId() -> Int { lastForwardedRq += 1; return lastForwardedRq }

    // MARK: WS internals

    private func signIn() throws {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = PerplAuth.base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let canonical = PerplAuth.wsSigninCanonical(chainId: chainId, timestamp: timestamp, nonce: nonce)
        let signature = try PerplAuth.sign(Data(canonical.utf8), secret: key.secret)
        send(["mt": 29, "chain_id": chainId, "api_key": key.token, "timestamp": timestamp, "nonce": nonce, "signature": signature])
    }

    private func send(_ frame: PerplOrderFrame) async throws -> PerplOrderAck {
        // The socket closed between frames: this one never leaves the device (rather than waiting 8 s on a socket that
        // no longer exists and reporting an outcome that isn't in doubt).
        guard signedIn, task != nil else { throw PerplTradeError.notSignedIn }
        let rq = frame.requestId ?? max(nextRequestId(), lastForwardedRq)
        snCounter += 1
        let sn = snCounter
        return try await withCheckedThrowingContinuation { continuation in
            pending[sn] = continuation
            send(frame.json(rq: rq, sn: sn))
            Task { try? await Task.sleep(for: .seconds(8)); if let c = self.pending.removeValue(forKey: sn) { c.resume(throwing: PerplTradeError.timeout) } }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Reads frames from `socket` until it fails. The socket is captured (not re-read from `self.task`) so a close
    /// that lands after `disconnect()` swapped the task still reports the right close code, and a stale socket's
    /// failure can never be mistaken for the current one's.
    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) { self.handle(data) }
                    self.receive(on: socket)
                case .failure(let failure):
                    // A deliberate disconnect() already tore down and reported; ignore the cancelled socket's echo.
                    guard socket === self.task else { return }
                    let close = Self.closeInfo(socket, fallback: failure)
                    self.lastClose = close
                    self.task = nil
                    self.signedIn = false
                    self.error = close.message
                    let error = PerplTradeError.closed(close.message)
                    self.failConnect(error)
                    for (_, c) in self.pending { c.resume(throwing: error) }
                    self.pending.removeAll()
                    self.keepAlive?.cancel()
                    self.onDisconnect?()
                }
            }
        }
    }

    /// The server's close code + reason when it sent a close frame; otherwise a code-0 close carrying the transport's
    /// own description (a dropped network, a TLS failure, the app being suspended).
    private static func closeInfo(_ socket: URLSessionWebSocketTask, fallback: Error) -> PerplClose {
        let code = socket.closeCode
        guard code != .invalid else { return PerplClose(code: 0, reason: fallback.localizedDescription) }
        let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return PerplClose(code: code.rawValue, reason: reason)
    }

    /// Internal (not private) so tests can replay recorded frames.
    func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let mt = obj["mt"] as? Int else { return }
        switch mt {
        case 19: // WalletSnapshot — the accounts array is under `as` (Perpl `Wallet.as: Account[]`); the previous
                 // `accounts`/`acc` guesses never matched, so account id + forwarding flag never seeded on connect.
            signedIn = true
            applyAccounts(obj["as"] as? [[String: Any]] ?? obj["accounts"] as? [[String: Any]] ?? obj["acc"] as? [[String: Any]])
            resolveConnect()
        case 21: // AccountUpdate — fw / lfr change
            applyAccount(obj)
        case 23: // OrdersSnapshot — the full open-order set replaces what we hold
            ordersByOid.removeAll()
            for raw in (obj["d"] as? [[String: Any]]) ?? [] { applyOrder(raw, announce: false) }
            hasOrdersSnapshot = true
            publishOrders()
        case 24: // OrdersUpdate — upsert live orders, drop removed / terminal ones
            for raw in (obj["d"] as? [[String: Any]]) ?? [] { applyOrder(raw, announce: true) }
            publishOrders()
        case 26: // PositionsSnapshot — the full open-position set
            positionsByPid.removeAll()
            for raw in (obj["d"] as? [[String: Any]]) ?? [] { _ = applyPosition(raw) }
            hasPositionsSnapshot = true
            publishPositions()
        case 27: // PositionsUpdate — upsert open positions, drop ended ones, and report each ending once
            let ended = ((obj["d"] as? [[String: Any]]) ?? []).compactMap(applyPosition)
            publishPositions()
            for position in ended where endedPositions.insert(position.pid).inserted { onPositionEnded?(position) }
        case 3: // command status ack
            if let cid = obj["cid"] as? Int, let continuation = pending.removeValue(forKey: cid) {
                let status = obj["status"] as? [String: Any]
                continuation.resume(returning: PerplOrderAck(code: status?["code"] as? Int ?? -1, error: status?["error"] as? String))
            }
        default: break
        }
    }

    private func applyAccounts(_ accounts: [[String: Any]]?) {
        guard let first = accounts?.first else { return }
        applyAccount(first)
    }

    private func applyAccount(_ account: [String: Any]) {
        // `id` is the AccountID (`in` is the InstanceID — never use it as the account id).
        if let id = (account["id"] as? Int) ?? (account["id"] as? NSNumber)?.intValue { accountId = id }
        if let lfr = (account["lfr"] as? Int) ?? (account["lfr"] as? NSNumber)?.intValue { lastForwardedRq = max(lastForwardedRq, lfr) }
        if let fw = Self.boolValue(account["fw"]) { forwardingEnabled = fw }
        onAccountUpdate?()
    }

    /// Reads a JSON bool that may arrive as a real boolean or as 0/1.
    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// Upserts one `Order` from mt:23/24, or drops it when Perpl flags it removed (`r`) or it reaches a terminal
    /// status. Live statuses kept: Pending(1), Open(2), PartiallyFilled(3), Untriggered(8), Triggered(9).
    /// `announce` (updates only): report a trigger that fired or failed (`onTriggerEvent`).
    private func applyOrder(_ raw: [String: Any], announce: Bool) {
        guard let oid = Self.intValue(raw["oid"]) else { return }
        let previous = ordersByOid[oid]
        // An update without a status keeps the one it had, rather than reading as terminal and dropping a live order.
        let status = Self.intValue(raw["st"]) ?? previous?.statusRaw ?? 0
        let reason = Self.intValue(raw["sr"]) ?? 0
        let removed = Self.boolValue(raw["r"]) ?? false
        // An update may carry only what changed; the order's own terms (type, size, trigger) never do.
        let order = PerplOpenOrder(
            oid: oid,
            marketId: Self.intValue(raw["mkt"]) ?? previous?.marketId ?? 0,
            typeRaw: Self.intValue(raw["t"]) ?? previous?.typeRaw ?? 0,
            statusRaw: status,
            priceRaw: Self.intValue(raw["p"]) ?? previous?.priceRaw ?? 0,
            sizeRaw: Self.intValue(raw["os"]) ?? previous?.sizeRaw ?? 0,
            filledRaw: Self.intValue(raw["fs"]) ?? previous?.filledRaw ?? 0,
            triggerPriceRaw: Self.intValue(raw["tp"]) ?? previous?.triggerPriceRaw,
            triggerConditionRaw: Self.intValue(raw["tpc"]) ?? previous?.triggerConditionRaw,
            linkedPositionId: Self.intValue(raw["lp"]) ?? previous?.linkedPositionId,
            leverageHundredths: Self.intValue(raw["lv"]) ?? previous?.leverageHundredths ?? 0
        )
        if announce, order.isTrigger, let outcome = Self.triggerOutcome(status: status, reason: reason),
           announcedTriggers.insert("\(oid)-\(outcome == .triggered ? "fired" : "failed")").inserted {
            onTriggerEvent?(PerplTriggerEvent(order: order, outcome: outcome))
        }
        guard !removed, [1, 2, 3, 8, 9].contains(status) else { ordersByOid[oid] = nil; return }
        ordersByOid[oid] = order
    }

    /// What a trigger's status says happened to it, if anything worth reporting: Triggered (9) / Executed (10) /
    /// Filled (4) or a triggered-execution reason (54, 65, 66) means it fired; Failed (7) means it was refused or
    /// could not execute. Untriggered, open and cancelled triggers report nothing.
    static func triggerOutcome(status: Int, reason: Int) -> PerplTriggerEvent.Outcome? {
        if status == 7 { return .failed(reason: reason) }
        if [4, 9, 10].contains(status) || [54, 65, 66].contains(reason) { return .triggered }
        return nil
    }

    private func publishOrders() {
        openOrders = ordersByOid.values.sorted { $0.oid < $1.oid } // stable order so rows don't reshuffle between updates
        onOrdersUpdate?()
    }

    /// Upserts one `Position` from mt:26/27, dropping it once it is no longer open. Returns the position when this
    /// frame ended it (closed, liquidated, deleveraged, unwound), for `onPositionEnded`.
    private func applyPosition(_ raw: [String: Any]) -> PerplLivePosition? {
        guard let pid = Self.intValue(raw["pid"]) else { return nil }
        let previous = positionsByPid[pid]
        // The side is never guessed: a position whose side isn't known can't be matched to the triggers that close it.
        guard let isLong = Self.intValue(raw["sd"]).map({ $0 == 1 }) ?? previous?.isLong else { return nil }
        let position = PerplLivePosition(
            pid: pid,
            marketId: Self.intValue(raw["mkt"]) ?? previous?.marketId ?? 0,
            isLong: isLong,
            sizeRaw: Self.intValue(raw["s"]) ?? previous?.sizeRaw ?? 0,
            statusRaw: Self.intValue(raw["st"]) ?? previous?.statusRaw ?? 0
        )
        if position.isOpen {
            positionsByPid[pid] = position
            return nil
        }
        positionsByPid[pid] = nil
        // Closed (2) or ended by the protocol (3–5): an ending worth reporting. Failed (6) never opened.
        return (2...5).contains(position.statusRaw) ? position : nil
    }

    private func publishPositions() {
        positions = positionsByPid.values.sorted { $0.pid < $1.pid }
    }

    private func resolveConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    private func failConnect(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }
}
