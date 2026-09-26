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
///
/// A passkey (Mera) account's trading key is different (MERA-PLAN §3): its Ed25519 secret is derived from the passkey's
/// utility output when a session opens and held in memory only — the Keychain keeps just the token, which can't sign
/// in to the socket alone. The key, the socket and the keep-alive live exactly as long as the session: `end()` drops
/// all three (`MeraSessionLifecycle`), nothing reconnects while it is locked, and orders need the live session and fit
/// its caps, or a step-up.
@Observable
@MainActor
final class PerplTrading: MeraSessionLifecycle {
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
    /// The account's live open orders + pending keeper triggers, mirrored from the trading socket (mt:23/24). The
    /// authoritative source for TP/SL — the on-chain order book has none. Empty when the socket isn't live.
    private(set) var openOrders: [PerplOpenOrder] = []
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
    /// Keeps the single trading socket alive for as long as a key is enrolled, reconnecting automatically after any
    /// drop (network change, server restart, app resume) so the user never has to reconnect by hand to place TP/SL.
    /// It runs from the moment a key is present until the key is removed or the wallet changes; only Perpl rejecting
    /// the key (close 3401) makes it stand down (that key can never sign in again — the user must re-enroll). For a
    /// passkey account it runs only while the session is live.
    private var keepAlive: Task<Void, Never>?
    /// The passkey session a Mera account's trading key lives in.
    private let mera: MeraSession?
    /// The bound wallet is a passkey (Mera) account: its key exists only while that account's session is live.
    private var boundToPasskey = false
    /// A passkey account's stored token (never its secret).
    private var storedToken: PerplToken?

    init(mera: MeraSession? = nil) {
        self.mera = mera
        mera?.lifecycle = self
    }

    var isReady: Bool { status == .connected }
    /// A key is enrolled for this wallet: loaded, or — for a passkey account whose session is locked — its token only.
    var isEnrolled: Bool { key != nil || storedToken != nil }
    /// The signed-in account id from the trading WS (same value the on-chain account reports).
    var accountId: Int? { client?.accountId }
    /// The most recent failure, for callers that need to say why an authenticated action couldn't run.
    var failureMessage: String? { if case .failed(let why) = status { return why } else { return nil } }
    /// Live socket diagnostics, so the connection screen can show the ground truth behind `status`.
    var isSignedIn: Bool { client?.signedIn == true }
    var isForwarding: Bool { client?.forwardingEnabled == true || forwardingGrantedOnChain }

    /// Load any stored key for this account so the UI shows "enrolled" without a network call. Rebinds to the given
    /// wallet: when the wallet changes (or signs out) it tears down the previous wallet's authenticated session first,
    /// so a `connected` / one-click-ready state can never carry over to a different account. A passkey account loads
    /// its token only; its key exists while its session is live.
    func refresh(account: Session.Account?) {
        let address = account?.address
        let passkey = account?.method == .meraPasskey
        let target = address?.checksummed
        if target != boundAddress || passkey != boundToPasskey {
            disconnect()
            key = nil
            storedToken = nil
            status = .notEnrolled
            boundAddress = target
            boundToPasskey = passkey
            keyRejected = false
            forwardingGrantedOnChain = false
            resetRetry()
        }
        guard let address else { stopKeepAlive(); return }
        if passkey {
            storedToken = PerplKeychain.loadToken(address: address.checksummed)
            syncSessionKey()
        } else {
            key = PerplKeychain.load(address: address.checksummed)
        }
        if status == .notEnrolled || status == .enrolled { status = isEnrolled ? .enrolled : .notEnrolled }
        if key != nil { startKeepAlive() } else { stopKeepAlive() }
    }

    // MARK: Passkey (Mera) accounts

    /// Whether automatic reconnects may run: always, except for a passkey account whose session is locked.
    private var sessionAllowsTrading: Bool { !boundToPasskey || mera?.isUnlocked == true }

    /// A passkey account's key: its stored token with the live session's trading secret. Nil while locked.
    private func sessionKey() -> PerplApiKey? {
        guard boundToPasskey, let storedToken, let mera, let boundAddress, mera.address?.checksummed == boundAddress else { return nil }
        return mera.perplKey(token: storedToken.token, scopeMask: storedToken.scopeMask, keyNonce: storedToken.keyNonceData)
    }

    /// Brings a passkey account's `key` in line with its session: the live session's key (the socket and keep-alive
    /// follow it), or none.
    private func syncSessionKey() {
        let fresh = sessionKey()
        if fresh != key {
            // A socket signed in with another key must not outlive it.
            if key != nil { disconnect() }
            key = fresh
        }
        if key != nil {
            if status == .notEnrolled { status = .enrolled }
            startKeepAlive()
        } else {
            stopKeepAlive()
        }
    }

    func meraSessionDidOpen(_ session: MeraSession) {
        guard boundToPasskey else { return }
        syncSessionKey()
    }

    /// MERA-PLAN §3 `end()`: the socket closes, the keep-alive stops and the key is dropped. The token stays.
    func meraSessionDidEnd(_ session: MeraSession) {
        guard boundToPasskey else { return }
        stopKeepAlive()
        key = nil
        disconnect()
        // A key Perpl rejected keeps saying so; anything else reads as enrolled (token kept) or not.
        if !keyRejected { status = storedToken != nil ? .enrolled : .notEnrolled }
    }

    /// For a tap on a passkey account: opens the session when it is locked (one pinned ceremony), and fetches the
    /// utility output if the provider evaluated one salt only. Automatic reconnects never come here.
    private func unlockPasskeyKey() async throws {
        guard let mera, storedToken != nil else { throw PerplTradeError.notSignedIn }
        try await mera.unlock()
        if sessionKey() == nil { try await mera.loadUtility() }
        syncSessionKey()
        guard key != nil else { throw PerplTradeError.notSignedIn }
    }

    /// MERA-PLAN §3 for a passkey account's order: it goes out only inside a live session and within its caps (the
    /// order's worst-case notional, at most $100 per order and $250 per session), and a reduce-only close always needs
    /// a step-up. Otherwise `MeraSession.StepUpRequired`: the sheet answers it with one pinned ceremony and retries with
    /// the approval, which covers that one order. Other accounts are unaffected.
    private func authorize(_ input: OrderInput, approval: MeraSession.StepUp?) throws -> MeraSession.Charge? {
        guard boundToPasskey else { return nil }
        guard let mera else { throw PerplTradeError.notSignedIn }
        if input.reduceOnly {
            try mera.requireStepUp(approval, for: .reduceOnlyClose)
            return nil
        }
        return try mera.authorize(usd: Mera.SpendingCaps.notionalUSD(of: input), approval: approval)
    }

    /// Starts the always-on reconnect loop (idempotent). While a key is enrolled and Perpl hasn't rejected it, this
    /// brings the socket back within seconds of any drop, so `isReady` stays true across the whole app without the
    /// user reconnecting. It never opens a second socket — `ensureConnected` is single-flight and backs off on failure.
    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        keepAlive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Only act when the socket is actually down. A live socket (signed in — whether `.connected` or
                // `.needsForwarding`) is left alone; the client's own ping keeps it from idling out.
                if let self, self.key != nil, !self.keyRejected, self.sessionAllowsTrading, self.client?.signedIn != true {
                    await self.ensureConnected()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopKeepAlive() {
        keepAlive?.cancel()
        keepAlive = nil
    }

    /// Full one-time enrollment: generate a key, sign the server's typed data with the wallet, store, and connect.
    /// Any wallet that can sign a digest (Privy embedded or an imported local wallet) can enroll. The typed data is
    /// validated before the wallet sees anything (`PerplEnrollment`): it must register exactly this key for exactly
    /// this wallet on the terms the app asked for, and the digest signed is recomputed on device.
    ///
    /// A passkey (Mera) account enrols inside its session instead: the trading key is derived from the passkey
    /// (utility namespace, purpose-scoped, with a fresh nonce per enrolment because Perpl never registers a key twice —
    /// never stored, never backed up), and the session validates the typed data and signs its digest itself. Only the
    /// token and its nonce are stored, so a new device, or this one after it forgot the token, simply enrols again.
    func enroll(wallet: any Wallet, address: Address) async throws {
        status = .connecting
        do {
            // The payload is bound to `address`; only that wallet may sign it.
            guard wallet.address == address else { throw PerplEnrollmentError.foreignSigner }
            if let passkey = wallet as? MeraWallet {
                guard boundToPasskey, boundAddress == address.checksummed else { throw PerplTradeError.notSignedIn }
                // A fresh key for every enrolment (Perpl never registers one twice), so a new device — or this one after
                // it forgot its token — enrols again with one passkey prompt at most, none inside a live session.
                let enrolled = try await passkey.session.enrollPerpl(label: "DyorHQ")
                let token = PerplToken(enrolled.key, keyNonce: enrolled.keyNonce)
                PerplKeychain.saveToken(token, address: address.checksummed)
                storedToken = token
                // From the live session, not the enrolment's copy: nothing outlives a session that ended meanwhile.
                key = sessionKey()
                guard key != nil else { throw Mera.SessionError.sessionEnded }
            } else if let signer = wallet as? DigestSigner {
                let secret = PerplAuth.newSecret()
                let publicKeyHex = try PerplAuth.publicKeyHex(secret: secret)
                let auth = PerplAuthClient(chainId: Monad.chainId)
                let payload = try await auth.requestPayload(address: address.checksummed, publicKeyHex: publicKeyHex, scopeMask: PerplScope.trade, label: "DyorHQ")
                let walletSignature = try await signer.signDigest(payload.digest)
                let enrolled = try await auth.enroll(address: address.checksummed, secret: secret, payload: payload, walletSignature: walletSignature, scopeMask: PerplScope.trade)
                PerplKeychain.save(enrolled, address: address.checksummed)
                key = enrolled
            } else {
                throw PerplTradeError.notSignedIn
            }
            keyRejected = false
            resetRetry()
            startKeepAlive()
            try await connect()
        } catch {
            status = .failed(describe(error))
            throw error
        }
    }

    /// Sign in to the trading WebSocket with the stored key, for a tap (Reconnect, Try Again, after enrolling or
    /// enabling forwarding). A passkey account whose session is locked asks for the passkey first; automatic
    /// reconnects go through `ensureConnected`, which never asks.
    func connect() async throws {
        if boundToPasskey { try await unlockPasskeyKey() }
        try await openSocket()
    }

    /// Opens the one trading socket. Single-flight: a call made while a connect is already in progress awaits that one
    /// instead of opening a second socket.
    private func openSocket() async throws {
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
        client.onOrdersUpdate = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.openOrders = client.openOrders
        }
        client.onDisconnect = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            self.socketDropped(client.lastClose)
        }
        self.client = client
        do {
            try await client.connect()
            // Disconnected while signing in (a wallet change, or a passkey session that ended): the catch below closes
            // this socket too, rather than leaving it signed in with nobody holding it.
            guard self.client === client else { throw PerplTradeError.notSignedIn }
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
            status = isEnrolled ? .enrolled : .notEnrolled
        }
    }

    /// The live socket closed on its own. A rejected key or the connection cap surfaces as a failure the user can
    /// read; any other drop (idle timeout, server restart, network) just leaves the session `enrolled` so the next
    /// authenticated action reconnects after backoff — that is what keeps an active trading socket self-healing.
    private func socketDropped(_ close: PerplClose?) {
        guard status != .connecting else { return } // the in-flight connect reports its own outcome
        noteFailure(close)
        if let close, close.isAuthFailure || close.isConnectionCap {
            status = .failed(close.message)
        } else {
            status = isEnrolled ? .enrolled : .notEnrolled
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
        openOrders = []
        if key != nil { status = .enrolled }
    }

    /// Turn on one-click trading (order forwarding) with a single on-chain call. Perpl pushes the new `fw` flag as an
    /// AccountUpdate on the live socket, so wait for that first and only reconnect (for a fresh snapshot) if it
    /// doesn't arrive — every reconnect spends one of the wallet's 4 connection slots.
    func enableForwarding(env: AppEnvironment, wallet: Wallet) async throws {
        let data = try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])
        let hash = try await env.sender.run([.call(TransactionRequest(to: Perpl.exchange, data: data), label: "Enable one-click trading")], from: wallet) { _ in }
        Activity.record(ActivityRecord(kind: .perp, title: "One-click trading enabled", subtitle: "Order forwarding authorized on Perpl", hash: hash, section: "perps"), owner: wallet.address)
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
    /// A passkey account's order must fit its live session (`authorize`) or carry a step-up `approval`.
    func submit(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int = 100,
                approval: MeraSession.StepUp? = nil) async throws -> PerplOrderAck {
        let charge = try authorize(input, approval: approval)
        await ensureConnected()
        let client: PerplTradeClient
        do { client = try liveClient() } catch { mera?.refund(charge); throw error }
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
        let ack = try await client.place(frames)
        if !ack.accepted { mera?.refund(charge) }
        return ack
    }

    /// Cancels a resting order over the authenticated path (no wallet signature) — for recycling / cancelling an order.
    /// A passkey account's cancel always needs a step-up `approval` (MERA-PLAN §3).
    @discardableResult
    func cancel(perpId: Int, orderId: Int, env: AppEnvironment, approval: MeraSession.StepUp? = nil) async throws -> PerplOrderAck {
        if boundToPasskey {
            guard let mera else { throw PerplTradeError.notSignedIn }
            try mera.requireStepUp(approval, for: .cancelOrder)
        }
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        return try await client.place([PerplOrders.cancel(perpId: perpId, orderId: orderId, accountId: accountId, head: head)])
    }

    /// Reduce-only market close of a position over the authenticated path. `side` is the POSITION's side; the close
    /// order is submitted on the opposite side (matches PerplService.closePositionPlan) so it actually reduces. A
    /// passkey account's close always needs a step-up `approval` (MERA-PLAN §3; `submit` checks it).
    @discardableResult
    func closePosition(market: PerpMarket, side: PositionSide, size: Double, slippageBps: Int, env: AppEnvironment,
                       approval: MeraSession.StepUp? = nil) async throws -> PerplOrderAck {
        // Asked for before connecting; `submit` spends the approval.
        if boundToPasskey, approval == nil { throw MeraSession.StepUpRequired(reason: .reduceOnlyClose) }
        await ensureConnected()
        guard let accountId = client?.accountId else { throw PerplTradeError.notSignedIn }
        let input = OrderInput(market: market, side: side.opposite, kind: .market, size: size, leverage: 1, reduceOnly: true, slippageBps: slippageBps)
        return try await submit(input: input, accountId: accountId, takeProfit: nil, stopLoss: nil, env: env, approval: approval)
    }

    /// The per-frame acceptance of a bracket placement, so an automated caller can refuse to record a level whose
    /// take-profit or stop-loss trigger was rejected (which would leave a position unprotected).
    struct BracketResult: Sendable { var entry: Bool; var takeProfit: Bool?; var stopLoss: Bool?; var error: String? }

    /// Places a bracket (entry + linked TP/SL) and reports whether the entry AND each requested trigger were
    /// individually accepted — unlike `submit`, which returns only the entry ack. A passkey account's bracket must fit
    /// its live session (`authorize`) or carry a step-up `approval`.
    func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int,
                       approval: MeraSession.StepUp? = nil) async throws -> BracketResult {
        let charge = try authorize(input, approval: approval)
        await ensureConnected()
        let client: PerplTradeClient
        do { client = try liveClient() } catch { mera?.refund(charge); throw error }
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
        if !accepted("entry") { mera?.refund(charge) }
        return BracketResult(entry: accepted("entry"),
                             takeProfit: takeProfit != nil ? accepted("tp") : nil,
                             stopLoss: stopLoss != nil ? accepted("sl") : nil,
                             error: acks.first { !$0.accepted }?.error)
    }

    /// Ensures a LIVE trading socket before an authed operation. Reconnects when the socket isn't truly alive — even
    /// if `status` is a stale `.connected` — but never hammers Perpl: it joins an in-flight connect, waits out the
    /// backoff after a failure, and gives up on a key Perpl has rejected (the user must re-enroll). It never prompts:
    /// a passkey account reconnects only while its session is live (the keep-alive and RootView's resume come here).
    func ensureConnected() async {
        guard key != nil, !keyRejected, sessionAllowsTrading else { return }
        if status == .connected, client?.signedIn == true { return }
        if let connectTask { _ = try? await connectTask.value; return }
        guard Date() >= retryAfter else { return }
        try? await openSocket()
    }

    func forget(address: Address) {
        stopKeepAlive()
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
        storedToken = nil
        keyRejected = false
        forwardingGrantedOnChain = false
        resetRetry()
        status = .notEnrolled
    }
}

/// What a passkey (Mera) account stores of its Perpl API key: the token, and the nonce of the enrolment that issued it
/// (`Mera.Purpose.perplTrading(nonce:)`). Neither can sign in to the trading socket without the Ed25519 secret, which
/// the passkey re-derives at every unlock and is never stored.
struct PerplToken: Codable, Equatable {
    let token: String
    let address: String
    let scopeMask: Int
    /// Hex; nil for a token enrolled before enrolments carried a nonce (its key is the purpose's own).
    let keyNonce: String?

    init(_ key: PerplApiKey, keyNonce: Data?) {
        token = key.token
        address = key.address
        scopeMask = key.scopeMask
        self.keyNonce = keyNonce?.hexString
    }

    var keyNonceData: Data? { keyNonce.flatMap { Data(hex: $0) } }
}

/// Keychain storage for the Perpl API key (opaque token + 32-byte Ed25519 secret), one per wallet address — or, for a
/// passkey account, its token only (`saveToken`).
enum PerplKeychain {
    private static let service = "fun.dyorhq.perpl"

    static func save(_ key: PerplApiKey, address: String) {
        guard let data = try? JSONEncoder().encode(key) else { return }
        write(data, address: address)
    }

    static func load(address: String) -> PerplApiKey? {
        read(address: address).flatMap { try? JSONDecoder().decode(PerplApiKey.self, from: $0) }
    }

    /// A passkey account's token. Replaces whatever was stored for the address.
    static func saveToken(_ token: PerplToken, address: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        write(data, address: address)
    }

    /// A passkey account's token. An earlier build stored such an account's whole key; the secret in it is dropped here
    /// (the token is kept with no nonce, and the passkey re-derives the pre-nonce secret).
    static func loadToken(address: String) -> PerplToken? {
        guard let data = read(address: address), let token = try? JSONDecoder().decode(PerplToken.self, from: data) else { return nil }
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["secret"] != nil { saveToken(token, address: address) }
        return token
    }

    private static func write(_ data: Data, address: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: keep the Perpl API secret off iCloud Keychain
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(address: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    static func delete(address: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
        SecItemDelete(query as CFDictionary)
    }
}
