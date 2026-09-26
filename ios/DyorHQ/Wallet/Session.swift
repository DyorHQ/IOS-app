import AuthenticationServices
import DyorKit
import Foundation
import Observation
import PrivySDK
import Security

/// Who is signed in and with what wallet. Privy handles Apple, Google, email and passkey sign-in and holds the
/// embedded wallet's key; a watch-only address lets someone follow a wallet without signing anything.
@Observable
@MainActor
final class Session {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(Account)
    }

    enum Method: String, Codable, Equatable {
        case apple, google, email, emailPassword, passkey, meraPasskey, imported, watchOnly

        var title: String {
            switch self {
            case .apple: return "Apple"
            case .google: return "Google"
            case .email: return "Email"
            case .emailPassword: return "Email & Password"
            case .passkey: return "Passkey (Privy)"
            case .meraPasskey: return "Passkey"
            case .imported: return "Imported wallet"
            case .watchOnly: return "Watch only"
            }
        }
    }

    struct Account: Equatable, Codable {
        let address: Address
        let method: Method
        /// The email or display name the account signed in with, when known.
        let label: String?
        var canSign: Bool { method != .watchOnly }
    }

    private(set) var state: State = .loading
    /// Signs transactions for the current account; nil while watching an address.
    private(set) var wallet: (any Wallet)?
    let config: AppConfig
    private let privy: (any Privy)?
    /// The Mera passkey account layer: a wallet derived from the passkey's PRF output, nothing stored.
    let mera: MeraSession
    /// The backend (wallet-auth) session. `signInWithMera` signs in to it while the new passkey session is live.
    private let backend: SocialSession
    private var observing = false
    /// While true, a Privy `.authenticated` event is NOT adopted as the signer — used to verify an email at
    /// sign-up (Privy OTP) without letting Privy's embedded wallet take over from the deterministic one.
    private var suppressPrivyAdoption = false

    /// Set once a passkey account's deletion has finished (`AccountDeletion.deletePasskeyAccount`): the "Account
    /// deleted." screen, which RootView shows in place of onboarding until it is closed. It outlives the deletion's own
    /// sheet, which goes with the signed-in screens. Memory only.
    var passkeyDeletion: Mera.AccountDeletion.Done?

    var account: Account? { if case .signedIn(let account) = state { return account } else { return nil } }
    var address: Address? { account?.address }
    var canSign: Bool { account?.canSign ?? false }
    /// Whether the account can sign right now without showing anything: every signer except a passkey (Mera) account
    /// whose session is locked, where a signature means a passkey prompt. Work nobody tapped for (the backend sign-in
    /// at launch) checks this, so a cold launch never asks for the passkey.
    var canSignWithoutPrompt: Bool { canSign && !(account?.method == .meraPasskey && !mera.isUnlocked) }
    /// A passkey (Mera) account: its signatures run through the session's scope check (MERA-PLAN §3).
    var isPasskeyAccount: Bool { account?.method == .meraPasskey }
    #if DEBUG && targetEnvironment(simulator)
    /// Simulator test mode: a passkey account the stub authenticator derives, confined to the local fork
    /// (`MeraSession.isStub`). Screens that can't work there (Bridge) say so instead of offering it.
    var isStubAccount: Bool { isPasskeyAccount && mera.isStub }
    #endif

    /// The signer for one action a sheet declared (`MeraSession.Action`): a passkey account's wallet bound to that
    /// action, so its intent reaches the scope check and one step-up covers the whole plan. Any other account's wallet
    /// is returned as it is.
    func wallet(for action: MeraSession.Action?) -> (any Wallet)? {
        guard let action, let passkey = wallet as? MeraWallet else { return wallet }
        return MeraWallet(address: passkey.address, session: passkey.session, action: action)
    }

    /// The signer for work nobody tapped for (the backend sign-in RootView starts): a passkey account's signs only
    /// inside its live session and never shows a prompt (`MeraBackgroundSigner`); any other account's wallet as it is.
    var backgroundWallet: (any Wallet)? {
        guard let passkey = wallet as? MeraWallet else { return wallet }
        return MeraBackgroundSigner(address: passkey.address, session: passkey.session)
    }

    init(config: AppConfig, backend: SocialSession) {
        self.config = config
        self.backend = backend
        privy = config.hasPrivy ? PrivySdk.initialize(config: PrivyConfig(appId: config.privyAppID, appClientId: config.privyClientID, loggingConfig: PrivyLoggingConfig(logLevel: .warning))) : nil
        mera = MeraSession(backend: .forThisBuild(rpcURLs: config.rpcURLs))
    }

    /// Starts following Privy's auth state. Safe to call more than once.
    func start() {
        guard !observing else { return }
        observing = true
        // An imported (local) wallet or a watch-only address take effect before Privy is even asked.
        _ = loadStoredSession()
        guard let privy else {
            if case .loading = state { state = .signedOut }
            return
        }
        Task { [weak self] in
            for await authState in privy.authStateStream {
                await self?.apply(authState)
            }
        }
    }

    private func apply(_ authState: AuthState) async {
        switch authState {
        case .notReady:
            if case .signedIn = state { return }
            state = .loading
        case .unauthenticated, .authenticatedUnverified:
            wallet = nil
            if !loadStoredSession() { state = .signedOut }
        case .authenticated(let user):
            if suppressPrivyAdoption { return } // email verification only — don't adopt the Privy wallet
            try? await adoptOnce(user) // a failure is already recorded in lastError and the Privy session ended
        }
    }

    /// Restores an imported wallet (preferred) or a watch-only address into the session. Returns whether one was
    /// found, so Privy's unauthenticated state doesn't clobber a locally-held wallet.
    @discardableResult
    private func loadStoredSession() -> Bool {
        if let address = MeraCredentialStore.address, hasMera {
            // Locked until the first signature asks for the passkey; reads work immediately.
            wallet = MeraWallet(address: address, session: mera)
            state = .signedIn(Account(address: address, method: .meraPasskey, label: "Passkey"))
            return true
        }
        if let account = ImportedWalletStore.loadAccount() {
            wallet = LocalWallet(account: account)
            if let meta = LocalWalletMeta.load(), meta.kind == .emailPassword {
                state = .signedIn(Account(address: account.address, method: .emailPassword, label: meta.email))
            } else {
                state = .signedIn(Account(address: account.address, method: .imported, label: nil))
            }
            return true
        }
        if let watched = WatchOnlyStore.load() {
            wallet = nil
            state = .signedIn(watched)
            return true
        }
        return false
    }

    /// The adoption in flight. An Apple/Google sign-in awaits its own adoption while the auth-state stream sees the same
    /// login, so both share one task: at most one wallet is created, and both callers get the same outcome.
    private var adoption: Task<Void, Error>?

    private func adoptOnce(_ user: any PrivyUser) async throws {
        if let adoption { return try await adoption.value }
        let task = Task { try await self.adopt(user) }
        adoption = task
        defer { adoption = nil }
        try await task.value
    }

    /// Makes sure the user has an embedded wallet, then exposes it as the app's signer. If that fails, the Privy session
    /// is ended too, so no half-signed-in state lingers: the user is back on onboarding with the reason, and the next
    /// attempt starts clean.
    private func adopt(_ user: any PrivyUser) async throws {
        do {
            let embedded: any EmbeddedEthereumWallet
            if let existing = user.embeddedEthereumWallets.first {
                embedded = existing
            } else {
                embedded = try await user.createEthereumWallet()
            }
            guard let address = Address(embedded.address) else { throw SessionError.invalidWalletAddress }
            await embedded.provider.switchChain(chainId: Monad.chainId, rpcUrl: config.rpcURL.absoluteString)
            let (method, label) = signInIdentity(of: user)
            wallet = PrivyWallet(address: address, provider: embedded.provider)
            WatchOnlyStore.clear()
            ImportedWalletStore.clear() // a fresh Privy sign-in supersedes any imported wallet
            mera.forget()
            lastError = nil
            state = .signedIn(Account(address: address, method: method, label: label))
        } catch {
            lastError = error.localizedDescription
            await user.logout()
            wallet = nil
            if !loadStoredSession() { state = .signedOut }
            throw error
        }
    }

    /// The most recent sign-in problem, for the onboarding screens to show.
    var lastError: String?

    /// The method the user just tapped (Apple / Google), while that sign-in is in flight.
    private var pendingMethod: Method?

    /// How the Privy user signed in, for the account rows: the method just tapped if it is linked, otherwise the most
    /// recently verified sign-in account (a user merged by email can hold several). The label is that account's email,
    /// except an Apple "Hide My Email" relay address or an empty one, which reads as nothing rather than as a name.
    private func signInIdentity(of user: any PrivyUser) -> (Method, String?) {
        var candidates: [(method: Method, label: String?, verified: Date?)] = []
        for account in user.linkedAccounts {
            switch account {
            case .apple(let apple): candidates.append((.apple, Self.displayEmail(apple.email), apple.latestVerifiedAt))
            case .google(let google): candidates.append((.google, Self.displayEmail(google.email), google.latestVerifiedAt))
            case .email(let email): candidates.append((.email, Self.displayEmail(email.email), email.latestVerifiedAt))
            case .passkey(let passkey): candidates.append((.passkey, nil, passkey.latestVerifiedAt))
            default: continue
            }
        }
        if let pendingMethod, let tapped = candidates.first(where: { $0.method == pendingMethod }) {
            return (tapped.method, tapped.label)
        }
        // Newest verification wins; ties (or no dates) keep Privy's order.
        let newest = candidates.reduce(nil as (method: Method, label: String?, verified: Date?)?) { best, next in
            guard let best else { return next }
            return (next.verified ?? .distantPast) > (best.verified ?? .distantPast) ? next : best
        }
        return newest.map { ($0.method, $0.label) } ?? (.email, nil)
    }

    private static func displayEmail(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasSuffix("@privaterelay.appleid.com") { return nil }
        return trimmed
    }

    // MARK: Sign-in methods

    var hasPrivy: Bool { privy != nil }
    /// Privy passkeys: off whenever Mera is on, since both would register under the same rpId (see `AppConfig`).
    var hasPasskeys: Bool { privy != nil && config.hasPasskeys }
    /// Apple / Google are offered only when the build enables them (and they're enabled in the Privy dashboard) —
    /// otherwise onboarding hides them so no one taps a method that returns `disallowed_login_method`.
    var hasSocialLogins: Bool { privy != nil && config.enableSocialLogins }
    /// Mera passkey accounts (`PasskeysEnabled`), offered next to the other methods. The rpId is the constant
    /// `Mera.relyingParty`.
    var hasMera: Bool { config.hasMera }

    /// One passkey ceremony creates (or signs into) a Mera account and makes it the app's signer. Supersedes any
    /// Privy, imported or watch-only session.
    ///
    /// The account is on screen the moment the ceremony returns. The backend (wallet-auth) sign-in starts right after,
    /// in the background, while the session the ceremony just opened is live, so its signature is prompt-free
    /// (`MeraBackgroundSigner`). It never happens at launch: a stored account comes back locked, and RootView won't ask
    /// for the passkey just to reach the backend. The backend is bound to this wallet in the same main-actor turn the
    /// account is published, so RootView's rebind finds it bound and joins the sign-in in flight rather than resetting
    /// it. If the session ends first (the app left the foreground), the sign-in is skipped, never prompted; a failure
    /// doesn't block the account, and RootView retries, prompt-free, the next time a session opens.
    func signInWithMera(create: Bool) async throws {
        let address = create ? try await mera.create() : try await mera.signIn()
        WatchOnlyStore.clear()
        ImportedWalletStore.clear()
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        wallet = MeraWallet(address: address, session: mera)
        lastError = nil
        state = .signedIn(Account(address: address, method: .meraPasskey, label: "Passkey"))
        backend.startSignIn(address: address, wallet: MeraBackgroundSigner(address: address, session: mera), profileInBackground: true)
    }

    func sendEmailCode(to email: String) async throws {
        try await requirePrivy().email.sendCode(to: email)
    }

    func signIn(email: String, code: String) async throws {
        _ = try await requirePrivy().email.loginWithCode(code, sentTo: email)
    }

    func signInWithApple() async throws {
        do {
            try await signInWithOAuth(.apple, as: .apple)
        } catch where authenticationServicesError(in: error).map({
            $0.domain == ASAuthorizationError.errorDomain && $0.code == ASAuthorizationError.unknown.rawValue
        }) == true {
            // Apple's "unknown" (1000) is what closing its "Sign in to your Apple Account" prompt returns on a device
            // with no Apple Account — say that instead of the raw system error.
            throw SessionError.appleSignInUnavailable
        }
    }

    func signInWithGoogle() async throws { try await signInWithOAuth(.google, as: .google) }

    /// Apple / Google through Privy (Privy drives Apple's native sheet or Google's web sheet), then the embedded wallet —
    /// awaited here so a failure reaches the button that started it. The scheme matches Info.plist's CFBundleURLTypes
    /// and the Privy app client's allowed URL schemes.
    private func signInWithOAuth(_ provider: OAuthProvider, as method: Method) async throws {
        lastError = nil
        pendingMethod = method
        defer { pendingMethod = nil }
        let user = try await requirePrivy().oAuth.login(with: provider, appUrlScheme: "dyorhq")
        try await adoptOnce(user)
    }

    func signInWithPasskey() async throws {
        guard hasPasskeys else { throw SessionError.privyPasskeysDisabled }
        _ = try await requirePrivy().passkey.login(relyingParty: relyingParty)
    }

    func createPasskey(displayName: String?) async throws {
        guard hasPasskeys else { throw SessionError.privyPasskeysDisabled }
        _ = try await requirePrivy().passkey.signup(relyingParty: relyingParty, displayName: displayName)
    }

    /// Follows an address without a key: every screen reads, nothing signs.
    func watch(_ address: Address) {
        let account = Account(address: address, method: .watchOnly, label: nil)
        WatchOnlyStore.save(account)
        wallet = nil
        lastError = nil
        state = .signedIn(account)
    }

    /// Imports the user's own wallet: the key is stored in this device's Keychain, becomes the app's signer, and
    /// supersedes any Privy or watch-only session. The raw key never leaves the device. False (with `lastError` set,
    /// and the session not switched to it) when the Keychain refused the key, so the caller keeps the user's input.
    @discardableResult
    func importWallet(_ account: Secp256k1Account) async -> Bool {
        guard ImportedWalletStore.save(privateKey: account.privateKey) else {
            lastError = "Couldn't save the key in this iPhone's Keychain. Unlock your iPhone and try again."
            return false
        }
        WatchOnlyStore.clear()
        mera.forget()
        // If a Privy session is lingering, end it so it can't override the imported wallet on the next auth event.
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        wallet = LocalWallet(account: account)
        lastError = nil
        state = .signedIn(Account(address: account.address, method: .imported, label: nil))
        return true
    }

    // MARK: Email + password (deterministic device-local wallet — see DyorKit's EmailWallet and PasswordWallet.swift)

    /// Send the sign-up OTP to `email` via Privy (used only to prove the address is real).
    func sendSignUpCode(to email: String) async throws {
        try await requirePrivy().email.sendCode(to: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What one email + password yields: the normalized email, the password seed S, and the v2 wallet.
    private struct PasswordKeys {
        let email: String
        let seed: Data
        let wallet: Secp256k1Account
    }

    /// Derive the v2 wallet (see `EmailWallet`): the slow seed and the key math run off the main actor; `pepper`
    /// fetches the server pepper for (e, t) — hashes, never the password or the seed.
    private func derivePassword(email: String, password: String,
                                pepper: (_ e: Data, _ t: Data) async throws -> Data) async throws -> PasswordKeys {
        let normalizedEmail = EmailWallet.normalize(email)
        guard let seed = await Task.detached(priority: .userInitiated, operation: {
            EmailWallet.legacySeed(email: normalizedEmail, password: password)
        }).value else { throw SessionError.passwordDerivationFailed }
        let input = EmailWallet.pepperInput(email: normalizedEmail, seed: seed)
        let p = try await pepper(input.e, input.t)
        guard let wallet = await Task.detached(priority: .userInitiated, operation: {
            EmailWallet.v2Account(seed: seed, pepper: p)
        }).value else { throw SessionError.passwordDerivationFailed }
        return PasswordKeys(email: normalizedEmail, seed: seed, wallet: wallet)
    }

    /// The legacy (pre-v2) wallet the same email + password derived, off the main actor.
    private func legacyWallet(_ keys: PasswordKeys) async throws -> Secp256k1Account {
        let seed = keys.seed
        guard let account = await Task.detached(priority: .userInitiated, operation: {
            EmailWallet.legacyAccount(seed: seed)
        }).value else { throw SessionError.passwordDerivationFailed }
        return account
    }

    /// Never strand funds: the email may leave its legacy wallet only while that wallet is empty. `holdsFunds` reads
    /// its balances; a failed read stops too, since an unknown balance is not an empty one.
    private func requireEmptyLegacy(_ legacy: Address, holdsFunds: (_ legacy: Address) async throws -> Bool) async throws {
        let funded: Bool
        do { funded = try await holdsFunds(legacy) } catch { throw SessionError.legacyBalanceUnavailable }
        if funded { throw SessionError.legacyWalletHasFunds(legacy) }
    }

    /// Store the derived key (Keychain, like an import) and make it the signer, superseding any other session.
    private func commitPasswordWallet(_ account: Secp256k1Account, email: String) async {
        ImportedWalletStore.save(privateKey: account.privateKey) // clears the local-wallet tag…
        LocalWalletMeta.setEmailPassword(email: email)           // …then tags it as an email+password wallet
        WatchOnlyStore.clear()
        mera.forget()
        if let privy, case .authenticated(let user) = await privy.getAuthState() { await user.logout() }
        wallet = LocalWallet(account: account)
        lastError = nil
        state = .signedIn(Account(address: account.address, method: .emailPassword, label: email))
    }

    /// How an email + password log-in ended.
    enum PasswordLogin: Equatable {
        /// Signed in with the email's v2 wallet.
        case signedIn
        /// The email belongs to an account created before v2 and is bound to its legacy wallet at `legacy`, which is
        /// empty. Nothing was committed: the caller has the user choose a NEW password, re-verifies the email (OTP)
        /// and moves the binding to that password's v2 wallet with `bindEmailPassword(upgradingFrom: legacy)` — an
        /// existing user is never silently landed on a different wallet. The old password can't carry over: `legacy`
        /// is public, and it lets anyone test guesses of the old password's S offline.
        case needsUpgrade(legacy: Address)
    }

    /// Log in (no OTP): derive the v2 wallet, then sign in ONLY if `verify` confirms the email is a verified account
    /// bound to exactly this derived wallet. A wrong password derives a different wallet and fails verification. The
    /// derived account is handed to `verify` so the wallet can prove itself (sign in to the backend and read its own
    /// binding) — there is no anonymous lookup that could confirm a guessed password. When the v2 wallet is not bound,
    /// the legacy wallet of the same password is checked the same way: an account created before v2 must upgrade
    /// (`.needsUpgrade`), and only while its legacy wallet is empty (`holdsFunds`) — otherwise this stops with an error.
    func logInWithPassword(email: String, password: String,
                           pepper: (_ e: Data, _ t: Data) async throws -> Data,
                           verify: (_ email: String, _ account: Secp256k1Account) async throws -> Bool,
                           holdsFunds: (_ legacy: Address) async throws -> Bool) async throws -> PasswordLogin {
        let keys = try await derivePassword(email: email, password: password, pepper: pepper)
        if try await verify(keys.email, keys.wallet) {
            await commitPasswordWallet(keys.wallet, email: keys.email)
            return .signedIn
        }
        let legacy = try await legacyWallet(keys)
        guard try await verify(keys.email, legacy) else { throw SessionError.emailNotVerified }
        try await requireEmptyLegacy(legacy.address, holdsFunds: holdsFunds)
        return .needsUpgrade(legacy: legacy.address)
    }

    // MARK: Email OTP + server-attested binding (shared by sign-up and forgot-password)

    /// Verify a fresh email OTP and RETURN the Privy access token, captured before the Privy session is dropped.
    /// Adoption stays suppressed so Privy's own wallet never becomes the signer. The token is the server's proof that
    /// the caller owns this email — the `email-rebind` function verifies it before writing the binding, so the
    /// OTP requirement is enforced on the backend, not just in this app, and `email-pepper` accepts it to pay for this
    /// email's pepper from its verified budget. Used by sign-up, forgot-password and a rate-limited log-in. The token
    /// goes to those two functions only.
    func verifyEmailCapturingToken(email: String, code: String) async throws -> String {
        let privy = try requirePrivy()
        suppressPrivyAdoption = true
        defer { suppressPrivyAdoption = false }
        _ = try await privy.email.loginWithCode(code, sentTo: email.trimmingCharacters(in: .whitespacesAndNewlines))
        let token = try await privyAccessToken()
        if case .authenticated(let user) = await privy.getAuthState() { await user.logout() }
        guard let token else { throw SessionError.emailNotVerified }
        return token
    }

    /// The canonical challenge the wallet signs to prove control of itself during a bind. The `email-rebind` function
    /// reparses these lines, so the format must stay in lock-step with it.
    static func bindChallenge(email: String, address: Address) -> String {
        let issued = ISO8601DateFormatter().string(from: Date())
        return "DyorHQ Email Rebind\n\nEmail: \(email)\nAddress: \(address.checksummed.lowercased())\nIssued At: \(issued)"
    }

    /// Bind (or re-bind) the OTP-verified email to the v2 wallet its password derives — the one write path for
    /// sign-up, forgot-password and the upgrade of an account created before v2. Derive the wallet, sign a challenge to
    /// prove control of it, and let `bind` push both proofs (the Privy `token` + the signature) to the server, which
    /// writes the binding with the service role after re-verifying them. Only on success does the wallet become the
    /// signer — nothing is committed if the server rejects the proofs, so a failed attempt leaves any existing session
    /// untouched. Sign-up and reset never derive or look up a legacy wallet: a legacy address is an offline check of
    /// the password, so a new password's must never reach anyone (the public RPCs included). Only an upgrade checks
    /// one — `upgradingFrom`, the legacy wallet log-in found bound, whose address is already public: the new password
    /// must differ from the old one (same password, same S, still guessable against that address), and that wallet
    /// must still be empty (`holdsFunds`) right before the email moves off it, so the move can never strand funds.
    func bindEmailPassword(email: String, password: String, token: String, upgradingFrom legacy: Address?,
                           pepper: (_ e: Data, _ t: Data) async throws -> Data,
                           holdsFunds: (_ legacy: Address) async throws -> Bool,
                           bind: (_ token: String, _ message: String, _ signature: String) async throws -> Void) async throws {
        let keys = try await derivePassword(email: email, password: password, pepper: pepper)
        if let legacy {
            // The new password's own legacy address is computed on-device only, for this comparison.
            if try await legacyWallet(keys).address == legacy { throw SessionError.upgradeNeedsNewPassword }
            try await requireEmptyLegacy(legacy, holdsFunds: holdsFunds)
        }
        let message = Self.bindChallenge(email: keys.email, address: keys.wallet.address)
        let signature: String
        do { signature = try keys.wallet.signMessage(Data(message.utf8)).hexString }
        catch { throw SessionError.passwordDerivationFailed }
        try await bind(token, message, signature)
        await commitPasswordWallet(keys.wallet, email: keys.email)
    }

    func signOut() async {
        WatchOnlyStore.clear()
        ImportedWalletStore.clear()
        mera.forget()
        wallet = nil
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        lastError = nil
        state = .signedOut
    }

    /// The signed-in Privy user's access token (nil for imported, passkey-derived and watch-only accounts). A
    /// server function uses it to prove the caller owns the Privy account it is asked to delete.
    func privyAccessToken() async throws -> String? {
        guard let privy, case .authenticated(let user) = await privy.getAuthState() else { return nil }
        return try await user.getAccessToken()
    }

    /// Account deletion, device side: ends the Privy session, then removes every trace of the account from this
    /// device — imported keys, the passkey account record, Perpl and backend tokens, caches,
    /// settings — and signs out. The blockchain is untouched; only the user's own backup can reach the funds again.
    func eraseLocalData() async {
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        WatchOnlyStore.clear()
        ImportedWalletStore.clear()
        mera.forget()
        wallet = nil
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        // Every Keychain item this app created (imported wallet keys, Perpl trading keys, backend session tokens).
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey] {
            SecItemDelete([kSecClass as String: itemClass] as CFDictionary)
        }
        lastError = nil
        state = .signedOut
    }

    /// Privy passkeys' relying party: DyorHQ's one passkey host. They're unreachable whenever Mera is on (`hasPasskeys`).
    private var relyingParty: String { "https://\(Mera.relyingParty)" }

    private func requirePrivy() throws -> any Privy {
        guard let privy else { throw SessionError.privyNotConfigured }
        return privy
    }
}

enum SessionError: LocalizedError {
    case privyNotConfigured
    case invalidWalletAddress
    case readOnly
    case passwordDerivationFailed
    case emailNotVerified
    case authenticationRequired
    case legacyWalletHasFunds(Address)
    case legacyBalanceUnavailable
    case upgradeNeedsNewPassword
    case appleSignInUnavailable
    case privyPasskeysDisabled

    var errorDescription: String? {
        switch self {
        case .privyPasskeysDisabled: return "Passkeys in this build open a DyorHQ passkey account, not a Privy one."
        case .appleSignInUnavailable: return "Sign in with Apple couldn’t start. Make sure this iPhone is signed in to an Apple Account in Settings, then try again."
        case .legacyWalletHasFunds(let legacy):
            return "Your account’s original wallet (\(legacy.checksummed)) still holds funds. To keep them safe, the security upgrade can’t finish until they’re moved out — send them to another wallet from a device where you’re still signed in, then log in again. Don’t reset your password before then: a reset moves your account to a new wallet and leaves those funds behind."
        case .legacyBalanceUnavailable: return "Couldn’t check your wallet’s balance. Check your connection and try again."
        case .upgradeNeedsNewPassword: return "Choose a new password for the security upgrade — your current one can’t be reused."
        case .authenticationRequired: return "Confirm with Face ID, Touch ID or your passcode to continue."
        case .privyNotConfigured: return "Sign-in is not set up in this build. Add the Privy keys to Secrets.xcconfig."
        case .invalidWalletAddress: return "The wallet address returned by Privy is not valid."
        case .readOnly: return "You are watching this address. Sign in to trade."
        case .passwordDerivationFailed: return "Couldn't create your wallet from that email and password. Please try again."
        case .emailNotVerified: return "We couldn't find a verified account for that email and password. If you're new, tap Sign Up to verify your email first."
        }
    }
}

/// Whether a sign-in error only means the person backed out — closed Apple's sheet, Google's web sheet or the passkey
/// sheet — which is not a failure to show.
func isUserCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled? = error as? PasskeyCeremony.Failure { return true }
    if let privy = error as? PrivyError, case .authenticationFailure(.passkeyUserCancelled) = privy.errorCode { return true }
    guard let system = authenticationServicesError(in: error) else { return false }
    return (system.domain == ASAuthorizationError.errorDomain && system.code == ASAuthorizationError.canceled.rawValue)
        || (system.domain == ASWebAuthenticationSessionError.errorDomain
            && system.code == ASWebAuthenticationSessionError.canceledLogin.rawValue)
}

/// The AuthenticationServices error behind a sign-in failure. PrivySDK wraps the system error in
/// `failureDuringAuthentication`, and system errors can nest under NSUnderlyingErrorKey, so this looks through both.
func authenticationServicesError(in error: Error) -> NSError? {
    if let privy = error as? PrivyError, case .authenticationFailure(.failureDuringAuthentication(let underlying)) = privy.errorCode {
        return authenticationServicesError(in: underlying)
    }
    let ns = error as NSError
    if ns.domain == ASAuthorizationError.errorDomain || ns.domain == ASWebAuthenticationSessionError.errorDomain { return ns }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return authenticationServicesError(in: underlying) }
    return nil
}

/// Remembers a watch-only address between launches.
enum WatchOnlyStore {
    private static let key = "session.watchOnly"

    static func load() -> Session.Account? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Session.Account.self, from: data)
    }

    static func save(_ account: Session.Account) {
        UserDefaults.standard.set(try? JSONEncoder().encode(account), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
