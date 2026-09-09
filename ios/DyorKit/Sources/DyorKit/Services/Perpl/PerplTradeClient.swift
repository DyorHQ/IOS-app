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
    private static func scalePrice(_ price: Double, _ market: PerpMarket) -> Int { Int((price * pow(10, Double(market.priceDecimals))).rounded()) }
    private static func scaleSize(_ size: Double, _ market: PerpMarket) -> Int { Int((size * pow(10, Double(market.lotDecimals))).rounded()) }

    /// The entry order. A market order is a marketable-limit IOC at the slippage bound (`p:0`, `ms`, `fl:4`).
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
            lastExecutionBlock: head + ttlBlocks
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
        PerplOrderFrame(type: .cancel, marketId: perpId, accountId: accountId, pricePNS: 0, lotLNS: 0, leverageHdths: 0, ioc: false, lastExecutionBlock: head + 100, orderId: orderId)
    }
}

/// The result of an order request: the gateway ack (`mt:3`). `code == 0` means accepted for forwarding.
public struct PerplOrderAck: Sendable {
    public let code: Int
    public let error: String?
    public var accepted: Bool { code == 0 }
}

public enum PerplTradeError: LocalizedError {
    case notSignedIn, noAccount, forwardingDisabled, timeout, closed(String)
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not connected to Perpl trading."
        case .noAccount: return "No Perpl trading account. Deposit AUSD first."
        case .forwardingDisabled: return "Enable one-click trading (order forwarding) on your Perpl account first."
        case .timeout: return "Perpl did not acknowledge the order in time."
        case .closed(let why): return "Perpl trading connection closed: \(why)."
        }
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

    /// Connects and signs in, resolving once the WalletSnapshot has seeded the account and request-id counter.
    public func connect(timeout: TimeInterval = 10) async throws {
        let task = session.webSocketTask(with: wsURL)
        self.task = task
        task.resume()
        try signIn()
        receive()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            Task { try? await Task.sleep(for: .seconds(timeout)); self.failConnect(PerplTradeError.timeout) }
        }
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        signedIn = false
    }

    /// Places the frames in order (entry first, then triggers), returning the entry's ack. Triggers are sent
    /// best-effort after the entry is accepted.
    public func place(_ frames: [PerplOrderFrame]) async throws -> PerplOrderAck {
        guard signedIn, let accountId else { throw PerplTradeError.notSignedIn }
        guard forwardingEnabled else { throw PerplTradeError.forwardingDisabled }
        _ = accountId
        var firstAck: PerplOrderAck?
        for frame in frames {
            let ack = try await send(frame)
            if firstAck == nil { firstAck = ack }
            if !ack.accepted { break }
        }
        return firstAck ?? PerplOrderAck(code: -1, error: "No frames")
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

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) { self.handle(data) }
                    self.receive()
                case .failure(let failure):
                    self.signedIn = false
                    self.error = failure.localizedDescription
                    self.failConnect(PerplTradeError.closed(failure.localizedDescription))
                    for (_, c) in self.pending { c.resume(throwing: PerplTradeError.closed(failure.localizedDescription)) }
                    self.pending.removeAll()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let mt = obj["mt"] as? Int else { return }
        switch mt {
        case 19: // WalletSnapshot — accounts + sequence seed
            applyAccounts(obj["accounts"] as? [[String: Any]] ?? obj["acc"] as? [[String: Any]])
            signedIn = true
            resolveConnect()
        case 21: // AccountUpdate — fw / lfr change
            applyAccount(obj)
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
        if let id = account["id"] as? Int ?? account["in"] as? Int { accountId = id }
        if let lfr = account["lfr"] as? Int { lastForwardedRq = max(lastForwardedRq, lfr) }
        if let fw = account["fw"] as? Bool { forwardingEnabled = fw }
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
