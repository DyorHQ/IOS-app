import DyorKit
import Foundation
import Observation
import Security

/// Coordinates authenticated Perpl trading: enroll an Ed25519 API key with the wallet's EIP-712 signature (stored
/// in the Keychain), sign in to the trading WebSocket, enable one-click order forwarding, and place market / limit
/// orders with optional take-profit and stop-loss triggers. This is the only path that yields real TP/SL, because
/// the on-chain Exchange has no trigger primitive — Perpl's keeper watches the mark and fires the close.
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

    var isReady: Bool { status == .connected }
    /// The signed-in account id from the trading WS (same value the on-chain account reports).
    var accountId: Int? { client?.accountId }

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
            try await connect()
        } catch {
            status = .failed(describe(error))
            throw error
        }
    }

    /// Sign in to the trading WebSocket with the stored key.
    func connect() async throws {
        guard let key else { throw PerplTradeError.notSignedIn }
        status = .connecting
        let client = PerplTradeClient(key: key, chainId: Monad.chainId)
        // Re-derive status on every account update, so the moment Perpl reports forwarding enabled — which can lag the
        // on-chain allowOrderForwarding tx and arrives via an AccountUpdate — the UI flips to connected on its own.
        client.onAccountUpdate = { [weak self] in self?.syncStatus() }
        // A dropped socket must move status off `.connected` so `isReady` is honest and the next op reconnects.
        client.onDisconnect = { [weak self] in self?.syncStatus() }
        self.client = client
        do {
            try await client.connect()
            syncStatus()
        } catch {
            self.client = nil
            status = .failed(describe(error))
            throw error
        }
    }

    /// Derives `status` from the live client's signed-in + forwarding state. Idempotent; safe to call repeatedly. A
    /// dropped socket (`signedIn == false`) falls back to `.enrolled` so the next use reconnects.
    private func syncStatus() {
        guard let client, status != .connecting else { return }
        if client.signedIn {
            status = client.forwardingEnabled ? .connected : .needsForwarding
        } else if key != nil {
            status = .enrolled
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        if key != nil { status = .enrolled }
    }

    /// Turn on one-click trading (order forwarding) with a single on-chain call, then reconnect to pick it up.
    func enableForwarding(env: AppEnvironment, wallet: Wallet) async throws {
        let data = try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])
        _ = try await env.sender.run([.call(TransactionRequest(to: Perpl.exchange, data: data), label: "Enable one-click trading")], from: wallet) { _ in }
        disconnect()
        try await connect()
    }

    /// Places the entry order (market/limit) with optional take-profit / stop-loss triggers linked to it. Returns
    /// the entry's gateway acknowledgement.
    func submit(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int = 100) async throws -> PerplOrderAck {
        await ensureConnected()
        guard let client, status == .connected else { throw PerplTradeError.notSignedIn }
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
        guard let client, status == .connected, let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        return try await client.place([PerplOrders.cancel(perpId: perpId, orderId: orderId, accountId: accountId, head: head)])
    }

    /// Reduce-only market close of a position over the authenticated path. `side` is the POSITION's side; the close
    /// order is submitted on the opposite side (matches PerplService.closePositionPlan) so it actually reduces.
    @discardableResult
    func closePosition(market: PerpMarket, side: PositionSide, size: Double, slippageBps: Int, env: AppEnvironment) async throws -> PerplOrderAck {
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
        guard let client, status == .connected else { throw PerplTradeError.notSignedIn }
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
    /// if `status` is a stale `.connected` — which is the fix for "one-click works but starting a strategy / placing
    /// an order later fails" because the idle socket had silently dropped.
    func ensureConnected() async {
        guard key != nil else { return }
        if status == .connected, client?.signedIn == true { return }
        try? await connect()
    }

    func forget(address: Address) {
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
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
