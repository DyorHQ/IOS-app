import DyorKit
import Foundation
import Observation
import Security
import UIKit

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
    /// The account's open orders + pending keeper triggers, mirrored from the trading socket (mt:23/24). The
    /// authoritative source for TP/SL — the on-chain order book has none — but only while `ordersAreLive`: after the
    /// socket drops on its own this is the LAST KNOWN list (a trigger may have fired or been cancelled since), and it is
    /// emptied when the session is deliberately closed, the wallet changes or the key is removed.
    private(set) var openOrders: [PerplOpenOrder] = []
    /// A take-profit / stop-loss fired or failed, or a position was liquidated, since the app opened (security audit
    /// GT-9) — for the trade screen to show in place, besides the notification.
    private(set) var protectionNotice: ProtectionNotice?
    /// Markets the app has seen, for naming and scaling what the trading stream reports (`noteMarkets`).
    private var markets: [Int: PerpMarket] = [:]
    /// Orders (by market and id) a cancel was already sent for, so the automatic sibling cleanup never sends one twice.
    private var cancelsSent: Set<PerplOpenOrder.Key> = []
    /// Sides of markets an entry was sent to recently: its triggers may be on the stream before the entry is.
    private var recentEntries: [PerplMarketSide: Date] = [:]
    /// Markets whose position the trading stream explained as it happened — liquidated, deleveraged or unwound by Perpl,
    /// or a take-profit / stop-loss on it triggered — and when, so the app-wide watcher doesn't report the ending again
    /// (`endingExplained`, `PerpEndingNotice`).
    private var explainedEndings: [Int: Date] = [:]
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
    /// Reads a wallet's open positions on-chain over the given markets (set by AppEnvironment), throwing when the read
    /// is incomplete. The automatic clean-up of leftover TP/SL cancels only what the chain agrees has closed.
    @ObservationIgnored var readPositions: ((Address, [PerpMarket]) async throws -> [PerpPosition])?

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
    /// `openOrders` is Perpl's current, complete list: the socket is signed in (one-click on or not) and has sent its
    /// open-orders snapshot. Otherwise the TP/SL on screen can't be verified (security audit GT-3).
    var ordersAreLive: Bool { client?.signedIn == true && client?.hasOrdersSnapshot == true }
    /// The account's open positions as the live trading socket reports them — the position id a TP/SL links to.
    /// Empty when the socket isn't live, or before its positions snapshot.
    var livePositions: [PerplLivePosition] { client?.hasPositionsSnapshot == true ? client?.positions ?? [] : [] }
    /// `livePositions` is Perpl's current, complete list (the socket is signed in and sent its positions snapshot).
    var positionsAreLive: Bool { client?.signedIn == true && client?.hasPositionsSnapshot == true }

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
            resetProtection()
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
    ///
    /// An order already on the wire keeps its socket until Perpl answers it (security audit GL-1): the session often
    /// ends because the app left the foreground mid-bracket, and closing then fails the unanswered frames — the entry
    /// may be live at Perpl while its stop-loss was never sent. So does an approved operation still running (a bracket,
    /// a cancel-then-place of a TP/SL, a cancel): between its steps nothing is in flight, but closing then would leave
    /// the old stop cancelled and the new one unsent. The socket is detached at once, so nothing new can use it, and
    /// closed as soon as its acks are in and its operation is done — after the 8 s an ack is given at most, or 20 s for
    /// a running operation. Whatever is still waiting then fails as "outcome unknown", which the sheets show as such,
    /// never as a failure to retry.
    func meraSessionDidEnd(_ session: MeraSession) {
        guard boundToPasskey else { return }
        stopKeepAlive()
        key = nil
        if let busy = client, busy.hasRequestsInFlight || operationsRunning > 0 {
            client = nil
            openOrders = []
            drain(busy)
        } else {
            disconnect()
        }
        // A key Perpl rejected keeps saying so; anything else reads as enrolled (token kept) or not.
        if !keyRejected { status = storedToken != nil ? .enrolled : .notEnrolled }
    }

    /// A socket detached from the session, kept only until the requests already on it are answered.
    private var draining: PerplTradeClient?
    /// Approved operations still running (`operation`), which keep a detached socket open until they finish.
    private var operationsRunning = 0

    private func drain(_ socket: PerplTradeClient) {
        draining?.disconnect()
        draining = socket
        // Held so iOS doesn't suspend the app, and freeze the socket, before its answers are in (GL-1).
        let background = PerplBackgroundTime("Perpl trading")
        Task { @MainActor [weak self] in
            defer { background.end() }
            let start = Date()
            while Date().timeIntervalSince(start) < 20 {
                let operating = (self?.operationsRunning ?? 0) > 0
                guard socket.hasRequestsInFlight || operating else { break }
                if !operating, Date().timeIntervalSince(start) >= 8 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            socket.disconnect()
            if self?.draining === socket { self?.draining = nil }
        }
    }

    /// Starts an operation the user approved (a bracket, a TP/SL change, a cancel): it holds background time, and a
    /// passkey session that ends meanwhile keeps its socket until it is done (`drain`, GL-1). Call the result when it is.
    private func operation(_ name: String) -> () -> Void {
        let background = PerplBackgroundTime(name)
        operationsRunning += 1
        return { [weak self] in
            background.end()
            self?.operationsRunning -= 1
        }
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
        let passkeyWallet = wallet is MeraWallet
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
                // Stored under the address it was enrolled for, whoever is signed in now (the Keychain is per address).
                PerplKeychain.saveToken(token, address: address.checksummed)
                try requireBound(to: address, passkey: true)
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
                // The user may have signed out or switched wallets while the wallet signed: this key belongs to
                // `address`, and must never become the key of whichever account is bound now.
                try requireBound(to: address, passkey: false)
                key = enrolled
            } else {
                throw PerplTradeError.notSignedIn
            }
            keyRejected = false
            resetRetry()
            startKeepAlive()
            try await connect()
        } catch {
            // A failure that belongs to another account (the wallet changed mid-enrolment) doesn't overwrite this one's.
            if isBound(to: address, passkey: passkeyWallet) { status = .failed(describe(error)) }
            throw error
        }
    }

    /// The trading session is still bound to `address` (and the same kind of account) — checked after every await
    /// that a sign-out or wallet switch could have outlived.
    private func isBound(to address: Address, passkey: Bool) -> Bool {
        boundAddress == address.checksummed && boundToPasskey == passkey
    }

    private func requireBound(to address: Address, passkey: Bool) throws {
        guard isBound(to: address, passkey: passkey) else {
            throw PerplTradeError.unavailable("You switched accounts while this was in progress. Nothing was applied to the account you're signed in to now.")
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
        client.onTriggerEvent = { [weak self, weak client] event in
            guard let self, let client, self.client === client else { return }
            self.triggerChanged(event)
        }
        client.onPositionEnded = { [weak self, weak client] position in
            guard let self, let client, self.client === client else { return }
            self.positionEnded(position)
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
        draining?.disconnect()
        draining = nil
        openOrders = []
        if key != nil { status = .enrolled }
    }

    /// Turn on one-click trading (order forwarding) with a single on-chain call. Perpl pushes the new `fw` flag as an
    /// AccountUpdate on the live socket, so wait for that first and only reconnect (for a fresh snapshot) if it
    /// doesn't arrive — every reconnect spends one of the wallet's 4 connection slots.
    func enableForwarding(env: AppEnvironment, wallet: Wallet) async throws {
        let passkey = boundToPasskey
        let data = try ABI.encodeCall("allowOrderForwarding(bool)", [.bool(true)])
        let hash = try await env.sender.run([.call(TransactionRequest(to: Perpl.exchange, data: data), label: "Enable one-click trading")], from: wallet) { _ in }
        Activity.record(ActivityRecord(kind: .perp, title: "One-click trading enabled", subtitle: "Order forwarding authorized on Perpl", hash: hash, section: "perps"), owner: wallet.address)
        // The grant is for `wallet`'s Perpl account. If the user switched accounts while it confirmed, the account bound
        // now must not be marked as forwarding (its orders would be sent and refused), nor reconnected on its behalf.
        try requireBound(to: wallet.address, passkey: passkey)
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
        for _ in 0..<8 where client?.forwardingEnabled != true && isBound(to: wallet.address, passkey: passkey) {
            try? await Task.sleep(for: .seconds(1))
        }
        syncStatus()
    }

    /// The connected, forwarding-enabled client — or the most specific error for why there isn't one.
    private func liveClient() throws -> PerplTradeClient {
        guard let client, status == .connected else {
            if let failureMessage { throw PerplTradeError.unavailable(failureMessage) } // nothing was sent
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
        try Self.checkTriggers(input: input, takeProfit: takeProfit, stopLoss: stopLoss)
        let charge = try authorize(input, approval: approval)
        await ensureConnected()
        let client: PerplTradeClient
        do { client = try liveClient() } catch { mera?.refund(charge); throw error }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        var entry = PerplOrders.entry(input, accountId: accountId, head: head, ttlBlocks: ttlBlocks)
        let entryRq = client.nextRequestId()
        entry.requestId = entryRq
        if !input.reduceOnly { recentEntries[PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)] = Date() }

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
        let ack: PerplOrderAck
        do { ack = try await client.place(frames) } catch let error as PerplTradeError where !error.outcomeUnknown { mera?.refund(charge); throw error }
        if !ack.accepted, !ack.outcomeUnknown { mera?.refund(charge) }
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
        let done = operation("Perpl cancel")
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        return try await client.place([PerplOrders.cancel(perpId: perpId, orderId: orderId, accountId: accountId, head: head)])
    }

    /// Cancels open orders or keeper triggers (TP/SL) from the live list, as ONE action: a passkey account's single
    /// step-up `approval` covers all of them (MERA-PLAN §3 — a cancel always asks). Each cancel is sent whatever the
    /// others did, and each order's ack is returned by its market and id. An accepted ack means Perpl admitted the
    /// cancel; the order leaves `openOrders` when the stream confirms it (mt:24).
    func cancel(orders: [PerplOpenOrder], approval: MeraSession.StepUp? = nil) async throws -> [PerplOpenOrder.Key: PerplOrderAck] {
        guard !orders.isEmpty else { return [:] }
        if boundToPasskey {
            guard let mera else { throw PerplTradeError.notSignedIn }
            try mera.requireStepUp(approval, for: .cancelOrder)
        }
        let done = operation("Perpl cancel")
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }
        cancelsSent.formUnion(orders.map(\.id))
        let acks = try await client.sendEach(orders.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: accountId, head: 0) })
        return Dictionary(zip(orders.map(\.id), acks), uniquingKeysWith: { first, _ in first })
    }

    /// One kind of trigger to set on an open position: the price for a new one (nil to only remove), and the live
    /// triggers of that kind it replaces.
    struct TriggerChange: Sendable {
        let kind: PerplTriggerKind
        let price: Double?
        let replacing: [PerplOpenOrder]
    }

    /// What happened to one `TriggerChange`, step by step, so the sheet can say exactly where the position stands.
    enum TriggerChangeOutcome: Equatable, Sendable {
        /// The new trigger was admitted (any it replaces were cancelled first).
        case placed
        /// The old triggers were cancelled and nothing new was asked for.
        case removed
        /// Nothing changed: a cancel was refused or never sent (the old trigger stays live and nothing new was placed),
        /// or a new trigger that replaced nothing was refused.
        case unchanged(String)
        /// Some of the triggers it replaces were cancelled and another was refused (it stays live): nothing new placed.
        case partlyRemoved(String)
        /// A cancel went unanswered: nothing new was placed; the old trigger may or may not still be live.
        case cancelUnknown
        /// Perpl admitted every cancel, but its live list didn't confirm the old trigger gone (still listed when the
        /// wait ran out, or the stream dropped): nothing new was placed; the old one may still be live.
        case cancelNotConfirmed
        /// The old trigger(s) were cancelled but the new one was refused: the position has none of this kind now.
        case unprotected(String)
        /// The new trigger went unanswered (the old ones, if any, were cancelled): it may or may not be live.
        case placementUnknown
    }

    /// Sets, moves or removes the take-profit / stop-loss of an open position (security audit GT-1). Each new trigger
    /// is linked to the position (`lp`), so Perpl cancels it when the position closes, and closes the position's whole
    /// size as the stream reports it now — a fixed size, which the sheet says (GT-5). Moving a trigger is
    /// cancel-then-place: the new one is sent only once every trigger it replaces was admitted for cancellation AND
    /// has left Perpl's live list (an admitted cancel can still fail on-chain), so a refused, unanswered or unconfirmed
    /// cancel never leaves two stops behind; if the placement then fails, the outcome says the position is
    /// unprotected. Stop-loss first. One action: a passkey account's one step-up `approval` covers it.
    func changeTriggers(_ changes: [TriggerChange], market: PerpMarket, position: PerplLivePosition, reference: Double, liquidation: Double?,
                        approval: MeraSession.StepUp? = nil) async throws -> [PerplTriggerKind: TriggerChangeOutcome] {
        let side: PositionSide = position.isLong ? .long : .short
        let size = Double(position.sizeRaw) / pow(10, Double(market.lotDecimals))
        guard position.isOpen, position.marketId == market.id, size > 0 else { throw PerplTradeError.invalidOrder("This position is no longer open.") }
        for change in changes {
            guard change.replacing.allSatisfy({ $0.marketId == market.id && $0.isTrigger && $0.protectsLong == position.isLong }) else {
                throw PerplTradeError.invalidOrder("That trigger isn't on this position.")
            }
            if let price = change.price, let problem = PerplTriggerRules.problem(change.kind, price: price, side: side, reference: reference, liquidation: liquidation, priceDecimals: market.priceDecimals) {
                throw PerplTradeError.invalidOrder(problem.message(market: market, referenceName: "the mark price"))
            }
        }
        if boundToPasskey {
            guard let mera else { throw PerplTradeError.notSignedIn }
            let cancels = changes.contains { !$0.replacing.isEmpty }
            try mera.requireStepUp(approval, for: cancels ? .cancelOrder : .reduceOnlyClose)
        }
        // Cancel-then-place: leaving the app between the two must not freeze or close the socket with the old stop gone
        // and the new one unsent (GL-1).
        let done = operation("Perpl TP/SL")
        defer { done() }
        await ensureConnected()
        let client = try liveClient()
        guard let accountId = client.accountId else { throw PerplTradeError.notSignedIn }

        var outcomes: [PerplTriggerKind: TriggerChangeOutcome] = [:]
        for change in changes.sorted(by: { $0.kind == .stopLoss && $1.kind != .stopLoss }) {
            if !change.replacing.isEmpty {
                let acks: [PerplOrderAck]
                do {
                    acks = try await client.sendEach(change.replacing.map { PerplOrders.cancel(perpId: market.id, orderId: $0.oid, accountId: accountId, head: 0) })
                } catch {
                    // Nothing of this change was sent (the socket closed after an earlier change): report it, keep the rest.
                    outcomes[change.kind] = .unchanged(describe(error))
                    continue
                }
                cancelsSent.formUnion(change.replacing.map(\.id))
                if let refused = acks.first(where: { !$0.accepted && !$0.outcomeUnknown }) {
                    let why = refused.error ?? "Perpl refused the cancel."
                    outcomes[change.kind] = acks.contains(where: \.accepted) ? .partlyRemoved(why) : .unchanged(why)
                    continue
                }
                if acks.contains(where: \.outcomeUnknown) { outcomes[change.kind] = .cancelUnknown; continue }
                guard await awaitRemoval(of: Set(change.replacing.map(\.id)), from: client) else {
                    outcomes[change.kind] = .cancelNotConfirmed
                    continue
                }
            }
            guard let price = change.price else { outcomes[change.kind] = .removed; continue }
            let frame = change.kind == .takeProfit
                ? PerplOrders.takeProfit(side: side, price: price, size: size, market: market, accountId: accountId, linkedPositionId: position.pid)
                : PerplOrders.stopLoss(side: side, price: price, size: size, market: market, accountId: accountId, linkedPositionId: position.pid)
            let ack: PerplOrderAck
            do {
                ack = try await client.sendEach([frame]).first ?? PerplOrderAck(code: -1, error: "Not sent.")
            } catch {
                ack = PerplOrderAck(code: -1, error: describe(error)) // never sent: refused on the device or no socket
            }
            if ack.accepted {
                outcomes[change.kind] = .placed
            } else if ack.outcomeUnknown {
                outcomes[change.kind] = .placementUnknown
            } else {
                outcomes[change.kind] = change.replacing.isEmpty ? .unchanged(ack.error ?? "Perpl refused it.") : .unprotected(ack.error ?? "Perpl refused it.")
            }
        }
        return outcomes
    }

    /// Waits for the stream to confirm (mt:24) that none of `orders` (by market and id) is live any more. A gateway ack
    /// only admits a cancel; the chain can still refuse it (a trigger that fired meanwhile, a reverted forward). False
    /// when the list stops being live, or after `timeout`.
    private func awaitRemoval(of orders: Set<PerplOpenOrder.Key>, from client: PerplTradeClient, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while client.signedIn, client.hasOrdersSnapshot {
            if !client.openOrders.contains(where: { orders.contains($0.id) }) { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
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
    struct BracketResult: Sendable {
        var entry: Bool; var takeProfit: Bool?; var stopLoss: Bool?; var error: String?
        /// A requested trigger was sent but never answered (the socket closed or the ack timed out): it may be live, so
        /// it is reported as neither placed nor refused.
        var takeProfitUnknown = false; var stopLossUnknown = false
    }

    /// Places a bracket (entry + linked TP/SL) and reports whether the entry AND each requested trigger were
    /// individually accepted — unlike `submit`, which returns only the entry ack. A passkey account's bracket must fit
    /// its live session (`authorize`) or carry a step-up `approval`. `onChainPositions` / `onChainOrders`: the account's
    /// positions and orders as the Exchange last reported them, for `checkOpening`.
    func submitBracket(input: OrderInput, accountId: Int, takeProfit: Double?, stopLoss: Double?, env: AppEnvironment, ttlBlocks: Int,
                       approval: MeraSession.StepUp? = nil, onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) async throws -> BracketResult {
        try Self.checkTriggers(input: input, takeProfit: takeProfit, stopLoss: stopLoss)
        let charge = try authorize(input, approval: approval)
        // The entry and its stop-loss go out one after the other: leaving the app between them must not freeze or close
        // the socket with the entry live and the stop-loss unsent (GL-1).
        let done = operation("Perpl order")
        defer { done() }
        await ensureConnected()
        let client: PerplTradeClient
        do {
            client = try liveClient()
            try await checkOpening(input, withTriggers: takeProfit != nil || stopLoss != nil, on: client,
                                   onChainPositions: onChainPositions, onChainOrders: onChainOrders)
        } catch {
            mera?.refund(charge)
            throw error
        }
        let head = (try? await env.rpc.blockNumber()).map { Int($0) } ?? 0
        var entry = PerplOrders.entry(input, accountId: accountId, head: head, ttlBlocks: ttlBlocks)
        let entryRq = client.nextRequestId()
        entry.requestId = entryRq
        if !input.reduceOnly { recentEntries[PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)] = Date() }
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
        let acks: [PerplOrderAck]
        do { acks = try await client.placeAll(frames) } catch let error as PerplTradeError where !error.outcomeUnknown { mera?.refund(charge); throw error }
        func ack(_ label: String) -> PerplOrderAck? {
            guard let i = labels.firstIndex(of: label), i < acks.count else { return nil }
            return acks[i]
        }
        func accepted(_ label: String) -> Bool { ack(label)?.accepted == true }
        if !accepted("entry") { mera?.refund(charge) }
        return BracketResult(entry: accepted("entry"),
                             takeProfit: takeProfit != nil ? accepted("tp") : nil,
                             stopLoss: stopLoss != nil ? accepted("sl") : nil,
                             error: acks.first { !$0.accepted && !$0.outcomeUnknown }?.error ?? acks.first { !$0.accepted }?.error,
                             takeProfitUnknown: ack("tp")?.outcomeUnknown == true,
                             stopLossUnknown: ack("sl")?.outcomeUnknown == true)
    }

    /// Refuses, before anything is charged or sent, triggers that can't do what they say (security audit GT-6, GT-7):
    /// none on a reduce-only order — its triggers would close the side the account doesn't hold — and each price at
    /// least one tick and on the market's tick grid. The ticket also checks the side and the liquidation price.
    private static func checkTriggers(input: OrderInput, takeProfit: Double?, stopLoss: Double?) throws {
        guard takeProfit != nil || stopLoss != nil else { return }
        if input.reduceOnly { throw PerplTradeError.invalidOrder(PerplTriggerRules.Problem.reduceOnly.message(market: input.market)) }
        for (kind, price) in [(PerplTriggerKind.takeProfit, takeProfit), (.stopLoss, stopLoss)] {
            guard let price else { continue }
            if let problem = PerplTriggerRules.problem(kind, price: price, side: input.side, reference: 0, liquidation: nil, priceDecimals: input.market.priceDecimals) {
                throw PerplTradeError.invalidOrder(problem.message(market: input.market))
            }
        }
    }

    /// Checks an opening order against Perpl's live lists where it is sent, not only when the ticket was tapped (a
    /// passkey account's stream is down until its session opens, which is after the tap). Refused, before anything is
    /// sent (security audit GT-2, GT-6):
    /// - while TP/SL left from an earlier position on that side of the market are still armed: they would act on the
    ///   position this opens (a leftover stop-loss can close it at once);
    /// - TP/SL on an order that only shrinks the open position on the other side.
    /// It waits briefly for the stream's order and position lists; without them nothing can be checked, so nothing is
    /// sent.
    private func checkOpening(_ input: OrderInput, withTriggers: Bool, on client: PerplTradeClient,
                              onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) async throws {
        guard !input.reduceOnly else { return }
        let deadline = Date().addingTimeInterval(3)
        while client.signedIn, !(client.hasOrdersSnapshot && client.hasPositionsSnapshot), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard self.client === client, ordersAreLive, positionsAreLive else {
            throw PerplTradeError.unavailable("Perpl hasn't sent your open orders yet, so take-profit and stop-loss left from an earlier position can't be checked. Nothing was sent. Try again in a moment.")
        }
        let side = PerplMarketSide(marketId: input.market.id, isLong: input.side == .long)
        let leftovers = orphanedTriggers(onChainPositions: onChainPositions, onChainOrders: onChainOrders).filter { $0.side == side }
        if !leftovers.isEmpty {
            throw PerplTradeError.invalidOrder(Self.leftoverMessage(count: leftovers.count, asset: input.market.asset, side: input.side))
        }
        guard withTriggers else { return }
        let scale = pow(10, Double(input.market.lotDecimals))
        let held = onChainPositions.filter { $0.perpId == input.market.id }.map { ($0.side, $0.size) }
            + client.positions.filter { $0.marketId == input.market.id && $0.isOpen }.map { ($0.isLong ? PositionSide.long : .short, Double($0.sizeRaw) / scale) }
        if let position = held.first(where: { PerplTriggerRules.onlyReduces(side: input.side, size: input.size, positionSide: $0.0, positionSize: $0.1) }) {
            throw PerplTradeError.invalidOrder(PerplTriggerRules.Problem.reducesPosition(position.0).message(market: input.market))
        }
    }

    /// Why an order can't open on a side of a market where TP/SL from an earlier position are still armed.
    static func leftoverMessage(count: Int, asset: String, side: PositionSide) -> String {
        let one = count == 1
        return "\(count) take-profit/stop-loss order\(one ? "" : "s") from an earlier \(asset) \(side == .long ? "long" : "short") \(one ? "is" : "are") still armed on Perpl and would act on this new position. Cancel \(one ? "it" : "them") from Orders first."
    }

    /// Brings the trading stream up without a prompt (a key account, or a passkey account whose session is open) and
    /// waits up to `timeout` for its order and position lists — for a check an on-chain order needs before it is signed.
    /// Returns at once when the stream can't come up without the user.
    func awaitLiveStream(timeout: TimeInterval) async {
        guard key != nil, !keyRejected, sessionAllowsTrading else { return }
        let deadline = Date().addingTimeInterval(timeout)
        Task { await self.ensureConnected() } // single-flight; keeps going if it outlasts the wait
        while !(ordersAreLive && positionsAreLive), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
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

    // MARK: Protection events (security audit GT-2, GT-9)

    /// A fired or failed TP/SL, or a position the protocol closed, as the trade screen shows it.
    struct ProtectionNotice: Equatable, Identifiable {
        let id = UUID()
        let marketId: Int
        let title: String
        let body: String
        /// A warning (a failed stop, a liquidation) rather than news of a trigger doing its job.
        let warning: Bool
        let time = Date()
    }

    /// Markets the trade screen loaded, so what the stream reports can be named and scaled.
    func noteMarkets(_ list: [PerpMarket]) {
        for market in list { markets[market.id] = market }
    }

    /// The trading stream already said, in the last few minutes, how this market's position ended or was closing: Perpl
    /// liquidated, deleveraged or unwound it, or a take-profit / stop-loss on it triggered. The app-wide watcher then
    /// stays quiet about the position's ending, so it is one notice, not two. An ending the stream saw but didn't explain
    /// (an order closed it, on this device or another) is the watcher's to report.
    func endingExplained(marketId: Int, within window: TimeInterval = 300) -> Bool {
        explainedEndings[marketId].map { Date().timeIntervalSince($0) < window } ?? false
    }

    func dismissProtectionNotice() { protectionNotice = nil }

    /// The live TP/SL with nothing left to protect (security audit GT-2): no open position on the side they close —
    /// neither on the stream nor in `onChainPositions` — and no entry resting on, or sent in the last minute to, that
    /// side of their market. Empty unless both of the stream's lists are live, so a gap in the data never reads as an
    /// orphan.
    func orphanedTriggers(onChainPositions: [PerpPosition], onChainOrders: [PerpOrder]) -> [PerplOpenOrder] {
        guard ordersAreLive, positionsAreLive else { return [] }
        let onChain = onChainPositions.map { PerplLivePosition(pid: -1, marketId: $0.perpId, isLong: $0.side == .long, sizeRaw: 1, statusRaw: 1) }
        let resting = Set(onChainOrders.filter { !$0.reduceOnly }.map { PerplMarketSide(marketId: $0.perpId, isLong: $0.side == .buy) }).union(recentEntrySides)
        return PerplTriggerCleanup.orphans(orders: openOrders, positions: livePositions + onChain, extraRestingEntries: resting)
    }

    /// The positions poll saw this side of a market close. The stream normally reports it first (mt:27); this covers a
    /// missed update. The same guarded clean-up runs, and a cancel is never sent twice.
    func positionClosedOnChain(marketId: Int, isLong: Bool) {
        cancelLeftovers(of: PerplLivePosition(pid: -1, marketId: marketId, isLong: isLong, sizeRaw: 0, statusRaw: 2))
    }

    private var recentEntrySides: Set<PerplMarketSide> { Set(recentEntries.filter { Date().timeIntervalSince($0.value) < 60 }.keys) }

    private func resetProtection() {
        protectionNotice = nil
        cancelsSent = []
        recentEntries = [:]
        explainedEndings = [:]
    }

    /// The bound wallet, for owner-keyed records.
    private var boundOwner: Address? { boundAddress.flatMap { Address($0) } }

    private func marketName(_ id: Int) -> String {
        let asset = markets[id]?.asset ?? PerplService.markets.first(where: { $0.id == id })?.symbol ?? "Market \(id)"
        return "\(asset)-PERP"
    }

    /// A take-profit / stop-loss fired, or failed after Perpl admitted it: recorded and notified (in-app and, when
    /// allowed, as a system notification) and shown on the trade screen. A failed stop-loss is the one that matters
    /// most — the position is still open without it.
    private func triggerChanged(_ event: PerplTriggerEvent) {
        let order = event.order
        let kind = order.isStopLoss ? "Stop-loss" : "Take-profit"
        let side = order.protectsLong ? "long" : "short"
        var detail = "\(marketName(order.marketId)) \(side)"
        if let market = markets[order.marketId], let raw = order.triggerPriceRaw {
            detail += " · \(NumberStyle.number(Double(raw) / pow(10, Double(market.priceDecimals)))) · \(NumberStyle.number(Double(order.sizeRaw) / pow(10, Double(market.lotDecimals)))) \(market.asset)"
        }
        let title: String
        let body: String
        let warning: Bool
        switch event.outcome {
        case .triggered:
            title = "\(kind) triggered"
            body = "\(detail). Perpl is closing that part of the position."
            warning = false
            explainedEndings[order.marketId] = Date()
        case .failed(let reason):
            // 64/67/68: it fired but couldn't execute; otherwise Perpl refused it after admitting it.
            let fired = [64, 67, 68].contains(reason)
            title = fired ? "\(kind) couldn't execute" : "\(kind) not placed"
            body = "\(detail). " + (fired ? "It triggered but Perpl couldn't close the position, so it is still open." : "Perpl refused it after accepting the order, so it isn't protecting your position.") + " Check the position on Perps."
            warning = true
        case .expired:
            title = "\(kind) expired"
            body = "\(detail). It expired without triggering, so it no longer protects your position. Check the position on Perps."
            warning = true
        }
        publish(ProtectionNotice(marketId: order.marketId, title: title, body: body, warning: warning))
    }

    /// A position ended on the stream. Liquidation, deleveraging or an unwind is reported like a fired trigger; any
    /// ending then cancels the TP/SL left over for that side (below).
    private func positionEnded(_ position: PerplLivePosition) {
        if position.endedByProtocol {
            explainedEndings[position.marketId] = Date()
            let how = position.wasLiquidated ? "liquidated" : position.statusRaw == 4 ? "deleveraged" : "unwound"
            publish(ProtectionNotice(marketId: position.marketId, title: "Position \(how)",
                                     body: "Your \(marketName(position.marketId)) \(position.isLong ? "long" : "short") was \(how) by Perpl.", warning: true))
        }
        cancelLeftovers(of: position)
    }

    private func publish(_ notice: ProtectionNotice) {
        protectionNotice = notice
        guard let owner = boundOwner else { return }
        // A tap opens that market's position (`PerpAlertText.reference`).
        Activity.record(ActivityRecord(kind: .perp, title: notice.title, subtitle: notice.body, hash: nil, section: "perps",
                                       reference: PerpAlertText.reference(perpId: notice.marketId)), owner: owner)
    }

    /// Cancels the TP/SL that were closing `ended`'s side of its market, once it has closed (security audit GT-2).
    /// Perpl drops a position-linked trigger itself, but the ticket's triggers are linked to their entry, and nothing
    /// documents that those go with the position: left armed, a stop-loss would fire against the NEXT position on that
    /// side. Only what is provably orphaned goes: no open position on that side, no resting entry on that side of the
    /// market (a trigger may be waiting on it) and no entry sent from here in the last minute. It waits two seconds for
    /// Perpl's own clean-up to arrive first. The stream alone never decides it: nothing is cancelled unless a fresh
    /// on-chain read agrees that side holds no position (a partial liquidation, or a stream that got it wrong, must
    /// not take the stop-loss off a position that is still open); while the chain still shows it, it tries again a
    /// few times and then leaves them to the trade screen's warning. A passkey account's cancel needs Face ID, so it
    /// is left to the trade screen's "Cancel leftover TP/SL" instead.
    private func cancelLeftovers(of ended: PerplLivePosition) {
        guard !boundToPasskey, let owner = boundOwner else { return }
        let side = PerplMarketSide(marketId: ended.marketId, isLong: ended.isLong)
        Task { @MainActor [weak self] in
            for delay in [2, 4, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.boundOwner == owner, self.leftovers(of: ended) != nil else { return }
                // The chain's word, read now: its position on that side is gone.
                guard let read = self.readPositions, let chain = try? await read(owner, Array(self.markets.values)),
                      !chain.contains(where: { $0.perpId == side.marketId && ($0.side == .long) == side.isLong }) else { continue }
                // Re-read after the await: the stream may have moved on (a new position, a cancel of its own).
                guard self.boundOwner == owner, let client = self.client, let accountId = client.accountId,
                      let leftovers = self.leftovers(of: ended) else { return }
                self.cancelsSent.formUnion(leftovers.map(\.id))
                let background = PerplBackgroundTime("Cancel leftover TP/SL")
                defer { background.end() }
                guard let acks = try? await client.sendEach(leftovers.map { PerplOrders.cancel(perpId: $0.marketId, orderId: $0.oid, accountId: accountId, head: 0) }) else { return }
                self.recordLeftoversCancelled(acks.filter(\.accepted).count, of: ended, owner: owner)
                return
            }
        }
    }

    /// The live stream's triggers left over from `ended`'s side, not already being cancelled — nil when there are none,
    /// or the stream can't say (not signed in, or before its snapshots).
    private func leftovers(of ended: PerplLivePosition) -> [PerplOpenOrder]? {
        guard let client, client.signedIn, client.hasOrdersSnapshot, client.hasPositionsSnapshot else { return nil }
        let leftovers = PerplTriggerCleanup.siblings(of: ended, orders: client.openOrders, positions: client.positions, extraRestingEntries: recentEntrySides)
            .filter { !cancelsSent.contains($0.id) }
        return leftovers.isEmpty ? nil : leftovers
    }

    private func recordLeftoversCancelled(_ cancelled: Int, of ended: PerplLivePosition, owner: Address) {
        guard cancelled > 0 else { return }
        // Recorded quietly: the ending itself was the news.
        Activity.record(ActivityRecord(kind: .perp, title: "Cancelled leftover TP/SL",
                                       subtitle: "\(marketName(ended.marketId)) · \(cancelled) order\(cancelled == 1 ? "" : "s") from the closed \(ended.isLong ? "long" : "short")",
                                       hash: nil, section: "perps"), owner: owner, notify: false)
    }

    func forget(address: Address) {
        stopKeepAlive()
        PerplKeychain.delete(address: address.checksummed)
        disconnect()
        key = nil
        storedToken = nil
        keyRejected = false
        forwardingGrantedOnChain = false
        resetProtection()
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

/// The background time iOS grants an app that leaves the foreground (about 30 s), held while frames are on their way to
/// Perpl or their answers are awaited (security audit 2026-09-26, GL-1): a suspended app freezes its socket, which could
/// leave an entry live with its stop-loss unsent, or an old stop cancelled with the new one unsent. Always handed back:
/// by `end` when the work is done, or when the time runs out.
@MainActor
private final class PerplBackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
