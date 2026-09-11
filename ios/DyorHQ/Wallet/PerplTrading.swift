import DyorKit
import Foundation
import Observation
import Security

/// Coordinates authenticated Perpl trading: enroll an Ed25519 API key with the wallet's EIP-712 signature (stored
/// in the Keychain), sign in to the trading WebSocket, enable one-click order forwarding, and place market / limit
/// orders with optional take-profit and stop-loss triggers. This is the only path that yields real TP/SL, because
/// the on-chain Exchange has no trigger primitive — Perpl's keeper watches the mark and fires the close.
///
/// Exactly ONE trading socket is ever open per app. Perpl caps a wallet at 4 concurrent trading connections (shared
/// with the Perpl web app) and closes any beyond that with 1008 "too many connections" — so every connect goes
/// through a single in-flight task, tears the previous socket down first, and failed attempts back off before an
/// automatic retry.
@Observable
@MainActor
final class PerplTrading {
    enum Status: Equatable {
        case notEnrolled          // no key on this device
        case enrolled             // key stored, not connected
        case connecting
        case connected            // signed in, order forwarding on — ready to trade
        case needsForwarding      // signed in, but one-click trading is off
        case failed(String)
    }

    private(set) var status: Status = .notEnrolled
    private(set) var key: PerplApiKey?
    private var client: PerplTradeClient?
    /// The wallet (checksummed address) the trading session is bound to, so a wallet change tears the session down.
    private var boundAddress: String?
    /// The one connect in flight, if any — concurrent callers await it instead of opening a second socket.
    private var connectTask: Task<Void, Error>?
    /// Automatic reconnects (watchers, order submission) wait until this instant; a user's tap always tries.
    private var retryAfter: Date = .distantPast
    private var consecutiveFailures = 0
    /// Perpl rejected the key (close 3401). Automatic reconnects stop: the same key can never sign in again.
    private var keyRejected = false
    /// Set once `allowOrderForwarding(true)` has CONFIRMED on-chain for the bound wallet this session. There is no
    /// on-chain getter for the flag and Perpl's WS `fw` push can lag the keeper by seconds, so a confirmed tx is the
    /// authority: forwarding is treated as on from that moment, regardless of the (possibly stale) WS `fw`. Cleared
    /// on a wallet change / forget.
    private var forwardingGrantedOnChain = false

    var isReady: Bool { status == .connected }
    /// The signed-in account id from the trading WS (same value the on-chain account reports).
    var accountId: Int? { client?.accountId }
    /// The most recent failure, for callers that need to say why an authenticated action couldn't run.
    var failureMessage: String? { if case .failed(let why) = status { return why } else { return nil } }
    /// Live socket diagnostics, so the connection screen can show the ground truth behind `status`.
    var isSignedIn: Bool { client?.signedIn == true }
    var isForwarding: Bool { client?.forwardingEnabled == true || forwardingGrantedOnChain }

    /// Load any stored key for this address so the UI shows "enrolled" without a network call. Rebinds to the given
    /// wallet: when the wallet changes (or signs out) it tears down the previous wallet's authenticated session first,
    /// so a `connected` / one-click-ready state can never carry over to a different account.
    func refresh(address: Address?) {
        let target = address?.checksummed
        if target != boundAddress {
            disconnect()
            key = nil
            status = .notEnrolled
            boundAddress = target
            keyRejected = false
            forwardingGrantedOnChain = false
            resetRetry()
        }
        guard let address else { return }
        key = PerplKeychain.load(address: address.checksummed)
        if status == .notEnrolled || status == .enrolled { status = key == nil ? .notEnrolled : .enrolled }
    }

    /// Full one-time enrollment: generate a key, sign the server's typed data with the wallet, store, and connect.
    /// Any wallet that can sign a digest (Privy embedded or an imported local wallet) can enroll.
    func enroll(wallet: any DigestSigner, address: Address) async throws {
        status = .connecting
        do {
            let secret = PerplAuth.newSecret()
            let publicKeyHex = try PerplAuth.publicKeyHex(secret: secret)
            let auth = PerplAuthClient(chainId: Monad.chainId)
            let payload = try await auth.requestPayload(address: address.checksummed, publicKeyHex: publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ")
            let walletSignature = try await wallet.signDigest(payload.digest)
            let enrolled = try await auth.enroll(address: address.checksummed, secret: secret, payload: payload, walletSignature: walletSignature, scopeMask: PerplScope.trade)
            PerplKeychain.save(enrolled, address: address.checksummed)
            key = enrolled
            keyRejected = false
            resetRetry()
            try await connect()
        } catch {
            status = .failed(describe(error))
            throw error
        }
    }

    /// Sign in to the trading WebSocket with the stored key. Single-flight: a call made while a connect is already in
    /// progress awaits that one instead of opening a second socket.
    func connect() async throws {
        if let connectTask { try await connectTask.value; return }
        let task = Task<Void, Error> { [self] in
            defer { self.connectTask = nil }
            try await self.performConnect()
        }
        connectTask = task
        try await task.value
    }

    private func performConnect() async throws {
        guard let key else { throw PerplTradeError.notSignedIn }
        // One socket per app: close whatever was open before opening another.
        client?.disconnect()
        client = nil
        status = .connecting
        let client = PerplTradeClient(key: key, chainId: Monad.chainId)
        // Both callbacks check the client is still the current one, so a superseded socket can't touch status.
        client.onAccountUpdate = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.syncStatus()
        }
        client.onDisconnect = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.socketDropped(client.lastClose)
        }
        self.client = client
        do {
            try await client.connect()
            keyRejected = false
            resetRetry()
            syncStatus()
        } catch {
            client.disconnect()
            // Report only if this attempt is still current — a deliberate disconnect() or a newer connect has already
            // moved status on, and a stale failure must not overwrite it.
            guard self.client === client else { throw error }
            self.client = nil
            noteFailure(client.lastClose)
            status = .failed(describe(error))
            throw error
        }
    }

    /// Derives `status` from the live client's signed-in + forwarding state. Idempotent; safe to call repeatedly.
    ///
    /// Once the client is signed in, ALWAYS advance — including out of `.connecting`, which is the whole point of the
    /// call at the end of a successful connect (the socket signed in, so `.connecting` must resolve to `.connected` /
    /// `.needsForwarding`). Only when NOT yet signed in is `.connecting` held, so a spurious callback during the
    /// handshake can't prematurely downgrade a connect that is still in flight.
    private func syncStatus() {
        guard let client else { return }
        if client.signedIn {
            // Forwarding is on if the WS says so OR we confirmed the on-chain grant this session (the WS can lag it).
            status = (client.forwardingEnabled || forwardingGrantedOnChain) ? .connected : .needsForwarding
        } else if status != .connecting {
            status = key != nil ? .enrolled : .notEnrolled
        }
    }

    /// The live socket closed on its own. A rejected key or the connection cap surfaces as a failure the user can
    /// read; any other drop (idle timeout, server restart, network) just leaves the session `enrolled` so the next
    /// authenticated action reconnects after backoff — that is what keeps an active strategy's socket self-healing.
    private func socketDropped(_ close: PerplClose?) {
        guard status != .connecting else { return } // the in-flight connect reports its own outcome
        noteFailure(close)
        if let close, close.isAuthFailure || close.isConnectionCap {
            status = .failed(close.message)
        } else {
            status = key != nil ? .enrolled : .notEnrolled
        }
    }

    private func noteFailure(_ close: PerplClose?) {
        if close?.isAuthFailure == true { keyRejected = true }
        consecutiveFailures += 1
        // 5s, 10s, 20s, 40s, 80s (capped at 2 min); the connection cap starts at 30s since slots free up slowly.
        let base: TimeInterval = close?.isConnectionCap == true ? 30 : 5
        retryAfter = Date().addingTimeInterval(min(120, base * pow(2, Double(min(consecutiveFailures - 1, 4)))))
    }

    private func resetRetry() {
        consecutiveFailures = 0
        retryAfter = .distantPast
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        if key != nil { status = .enrolled }
    }

    /// Turn on one-click trading (order forwarding) with a single on-chain call. Perpl pushes the new `fw` flag as an
    /// AccountUpdate on the live socket, so wait for that first and only reconnect (for a fresh snapshot) if it
    /// doesn't arrive — every reconnect spends one of the wallet's 4 connection slots.
    func enableForwarding(env: AppEnvironment, wallet: Wallet) async throws {
        let data = try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])
        _ = try await env.sender.run([.call(TransactionRequest(to: Perpl.exchange, data: data), label: "Enable one-click trading")], from: wallet) { _ in }
        // The tx confirmed, so forwarding is now enabled on-chain — the authority. Reflect it immediately instead of
        // waiting on Perpl's WS `fw` echo, which can lag the keeper by seconds and left the user stuck on
        // "Enable one-click" even after the grant landed.
        forwardingGrantedOnChain = true
        if client?.signedIn == true {
            syncStatus() // → .connected right away via the flag; no needless reconnect that spends a connection slot
        } else {
            resetRetry()
            try await connect()
        }
        // Best-effort: let the WS echo the new `fw` so the flag becomes redundant. Status is already connected.
        for _ in 0..<8 where client?.forwardingEnabled != true { try? await Task.sleep(for: .seconds(1)) }
        syncStatus()
    }

    /// The connected, forwarding-enabled client — or the most specific error for why there isn't one.
    private func liveClient() throws -> PerplTradeClient {
        guard let client, status == .connected else {
            if let failureMessage { throw PerplTradeError.closed(failureMessage) }
            if status == .needsForwarding { throw PerplTradeError.forwardingDisabled }
            throw PerplTradeError.notSignedIn
        }
        return client
    }

    /// Places the entry order (market/limit) with optional take-profit / stop-loss triggers linked to it. Returns
    /// the entry's gateway acknowledgement.
    func submit(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int = 100) async throws -> PerplOrderAck {
        await ensureConnected()
        let client = try liveClient()
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        var entry = PerplOrders.entry(input, accountId: accountId, head: head, ttlBlocks: ttlBlocks)
        let entryRq = client.nextRequestId()
        entry.requestId = entryRq

        var frames = [entry]
        if let takeProfit {
            var frame = PerplOrders.takeProfit(side: input.side, price: takeProfit, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil)
            frame.linkedRequestId = entryRq
            frame.requestId = client.nextRequestId()
            frames.append(frame)
        }
        if let stopLoss {
            var frame = PerplOrders.stopLoss(side: input.side, price: stopLoss, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil)
            frame.linkedRequestId = entryRq
            frame.requestId = client.nextRequestId()
            frames.append(frame)
        }
        return try await client.place(frames)
    }

    /// Cancels a resting order over the authenticated path (no wallet signature) — for recycling / stopping a strategy.
    @discardableResult
    func cancel(perpId: Int, orderId: Int, env: AppEnvironment) async throws -> PerplOrderAck {
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        return try await client.place([PerplOrders.cancel(perpId: perpId, orderId: orderId, accountId: accountId, head: head)])
    }

    /// Reduce-only market close of a position over the authenticated path. `side` is the POSITION's side; the close
    /// order is submitted on the opposite side (matches PerplService.closePositionPlan) so it actually reduces.
    @discardableResult
    func closePosition(market: PerpMarket, side: PositionSide, size: Double, slippageBps: Int, env: AppEnvironment) async throws -> PerplOrderAck {
        await ensureConnected()
        guard let accountId = client?.accountId else { throw PerplTradeError.notSignedIn }
        let input = OrderInput(market: market, side: side.opposite, kind: .market, size: size, leverage: 1, reduceOnly: true, slippageBps: slippageBps)
        return try await submit(input: input, accountId: accountId, takeProfit: nil, stopLoss: nil, env: env)
    }

    /// The per-frame acceptance of a bracket placement, so an automated caller can refuse to record a level whose
    /// take-profit or stop-loss trigger was rejected (which would leave a position unprotected).
    struct BracketResult: Sendable { var entry: Bool; var takeProfit: Bool?; var stopLoss: Bool?; var error: String? }

    /// Places a bracket (entry + linked TP/SL) and reports whether the entry AND each requested trigger were
    /// individually accepted — unlike `submit`, which returns only the entry ack.
    func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int) async throws -> BracketResult {
        await ensureConnected()
        let client = try liveClient()
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        var entry = PerplOrders.entry(input, accountId: accountId, head: head, ttlBlocks: ttlBlocks)
        let entryRq = client.nextRequestId()
        entry.requestId = entryRq
        var frames = [entry]
        var labels = ["entry"]
        if let takeProfit {
            var frame = PerplOrders.takeProfit(side: input.side, price: takeProfit, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil)
            frame.linkedRequestId = entryRq; frame.requestId = client.nextRequestId()
            frames.append(frame); labels.append("tp")
        }
        if let stopLoss {
            var frame = PerplOrders.stopLoss(side: input.side, price: stopLoss, size: input.size, market: input.market, accountId: accountId, linkedPositionId: nil)
            frame.linkedRequestId = entryRq; frame.requestId = client.nextRequestId()
            frames.append(frame); labels.append("sl")
        }
        let acks = try await client.placeAll(frames)
        func accepted(_ label: String) -> Bool {
            guard let i = labels.firstIndex(of: label), i < acks.count else { return false }
            return acks[i].accepted
        }
        return BracketResult(entry: accepted("entry"),
                             takeProfit: takeProfit != nil ? accepted("tp") : nil,
                             stopLoss: stopLoss != nil ? accepted("sl") : nil,
                             error: acks.first { !$0.accepted }?.error)
    }

    /// Ensures a LIVE trading socket before an authed operation. Reconnects when the socket isn't truly alive — even
    /// if `status` is a stale `.connected` — but never hammers Perpl: it joins an in-flight connect, waits out the
    /// backoff after a failure, and gives up on a key Perpl has rejected (the user must re-enroll).
    func ensureConnected() async {
        guard key != nil, !keyRejected else { return }
        if status == .connected, client?.signedIn == true { return }
        if let connectTask { _ = try? await connectTask.value; return }
        guard Date() >= retryAfter else { return }
        try? await connect()
    }

    func forget(address: Address) {
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
        keyRejected = false
        forwardingGrantedOnChain = false
        resetRetry()
        status = .notEnrolled
    }
}

/// Keychain storage for the Perpl API key (opaque token + 32-byte Ed25519 secret), one per wallet address.
enum PerplKeychain {
    private static let service = "fun.dyorhq.perpl"

    static func save(_ key: PerplApiKey, address: String) {
        guard let data = try? JSONEncoder().encode(key) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: keep the Perpl API secret off iCloud Keychain
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(address: String) -> PerplApiKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PerplApiKey.self, from: data)
    }

    static func delete(address: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
    }
}
