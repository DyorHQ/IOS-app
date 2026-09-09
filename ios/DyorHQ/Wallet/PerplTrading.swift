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

    var isReady: Bool { status == .connected }

    /// Load any stored key for this address so the UI shows "enrolled" without a network call.
    func refresh(address: Address?) {
        guard let address else { key = nil; status = .notEnrolled; return }
        key = PerplKeychain.load(address: address.checksummed)
        if status == .notEnrolled || status == .enrolled { status = key == nil ? .notEnrolled : .enrolled }
    }

    /// Full one-time enrollment: generate a key, sign the server's typed data with the wallet, store, and connect.
    func enroll(wallet: PrivyWallet, address: Address) async throws {
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
        do {
            try await client.connect()
            self.client = client
            status = client.forwardingEnabled ? .connected : .needsForwarding
        } catch {
            status = .failed(describe(error))
            throw error
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
    func submit(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment) async throws -> PerplOrderAck {
        guard let client, status == .connected else { throw PerplTradeError.notSignedIn }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        var entry = PerplOrders.entry(input, accountId: accountId, head: head)
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

    func forget(address: Address) {
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
        status = .notEnrolled
    }
}

/// Keychain storage for the Perpl API key (opaque token + 32-byte Ed25519 secret), one per wallet address.
enum PerplKeychain {
    private static let service = "xyz.dyorhq.perpl"

    static func save(_ key: PerplApiKey, address: String) {
        guard let data = try? JSONEncoder().encode(key) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
