import DyorKit
import Foundation
import Observation
import PrivySDK

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
        case apple, google, email, passkey, meraPasskey, imported, watchOnly

        var title: String {
            switch self {
            case .apple: return "Apple"
            case .google: return "Google"
            case .email: return "Email"
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
    private var observing = false

    var account: Account? { if case .signedIn(let account) = state { return account } else { return nil } }
    var address: Address? { account?.address }
    var canSign: Bool { account?.canSign ?? false }

    init(config: AppConfig) {
        self.config = config
        privy = config.hasPrivy ? PrivySdk.initialize(config: PrivyConfig(appId: config.privyAppID, appClientId: config.privyClientID, loggingConfig: PrivyLoggingConfig(logLevel: .warning))) : nil
        mera = MeraSession(rpId: config.passkeyRelyingParty)
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
            await adopt(user)
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
            state = .signedIn(Account(address: account.address, method: .imported, label: nil))
            return true
        }
        if let watched = WatchOnlyStore.load() {
            wallet = nil
            state = .signedIn(watched)
            return true
        }
        return false
    }

    /// Makes sure the user has an embedded wallet, then exposes it as the app's signer.
    private func adopt(_ user: any PrivyUser) async {
        do {
            let embedded: any EmbeddedEthereumWallet
            if let existing = user.embeddedEthereumWallets.first {
                embedded = existing
            } else {
                embedded = try await user.createEthereumWallet()
            }
            guard let address = Address(embedded.address) else { throw SessionError.invalidWalletAddress }
            await embedded.provider.switchChain(chainId: Monad.chainId, rpcUrl: config.rpcURL.absoluteString)
            let (method, label) = Self.describe(user)
            wallet = PrivyWallet(address: address, provider: embedded.provider)
            WatchOnlyStore.clear()
            ImportedWalletStore.clear() // a fresh Privy sign-in supersedes any imported wallet
            mera.forget()
            state = .signedIn(Account(address: address, method: method, label: label))
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
    }

    /// The most recent sign-in problem, for the onboarding screens to show.
    var lastError: String?

    private static func describe(_ user: any PrivyUser) -> (Method, String?) {
        for account in user.linkedAccounts {
            switch account {
            case .apple(let apple): return (.apple, apple.email)
            case .google(let google): return (.google, google.email)
            case .email(let email): return (.email, email.email)
            case .passkey: return (.passkey, nil)
            default: continue
            }
        }
        return (.email, nil)
    }

    // MARK: Sign-in methods

    var hasPrivy: Bool { privy != nil }
    var hasPasskeys: Bool { privy != nil && config.hasPasskeys }
    /// Mera passkey accounts need only a relying party (the domain that serves the passkey association file).
    var hasMera: Bool { !config.passkeyRelyingParty.isEmpty }

    /// One passkey ceremony creates (or signs into) a Mera account and makes it the app's signer. Supersedes any
    /// Privy, imported or watch-only session.
    func signInWithMera(create: Bool) async throws {
        let address = create ? try await mera.create(userName: "DyorHQ") : try await mera.signIn()
        WatchOnlyStore.clear()
        ImportedWalletStore.clear()
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        wallet = MeraWallet(address: address, session: mera)
        state = .signedIn(Account(address: address, method: .meraPasskey, label: "Passkey"))
    }

    func sendEmailCode(to email: String) async throws {
        try await requirePrivy().email.sendCode(to: email)
    }

    func signIn(email: String, code: String) async throws {
        _ = try await requirePrivy().email.loginWithCode(code, sentTo: email)
    }

    func signInWithApple() async throws {
        _ = try await requirePrivy().oAuth.login(with: .apple, appUrlScheme: "dyorhq")
    }

    func signInWithGoogle() async throws {
        _ = try await requirePrivy().oAuth.login(with: .google, appUrlScheme: "dyorhq")
    }

    func signInWithPasskey() async throws {
        _ = try await requirePrivy().passkey.login(relyingParty: relyingParty)
    }

    func createPasskey(displayName: String?) async throws {
        _ = try await requirePrivy().passkey.signup(relyingParty: relyingParty, displayName: displayName)
    }

    /// Follows an address without a key: every screen reads, nothing signs.
    func watch(_ address: Address) {
        let account = Account(address: address, method: .watchOnly, label: nil)
        WatchOnlyStore.save(account)
        wallet = nil
        state = .signedIn(account)
    }

    /// Imports the user's own wallet: the key is stored in this device's Keychain, becomes the app's signer, and
    /// supersedes any Privy or watch-only session. The raw key never leaves the device.
    func importWallet(_ account: Secp256k1Account) async {
        ImportedWalletStore.save(privateKey: account.privateKey)
        WatchOnlyStore.clear()
        mera.forget()
        // If a Privy session is lingering, end it so it can't override the imported wallet on the next auth event.
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        wallet = LocalWallet(account: account)
        state = .signedIn(Account(address: account.address, method: .imported, label: nil))
    }

    func signOut() async {
        WatchOnlyStore.clear()
        ImportedWalletStore.clear()
        mera.forget()
        wallet = nil
        if let privy, case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        state = .signedOut
    }

    private var relyingParty: String { "https://\(config.passkeyRelyingParty)" }

    private func requirePrivy() throws -> any Privy {
        guard let privy else { throw SessionError.privyNotConfigured }
        return privy
    }
}

enum SessionError: LocalizedError {
    case privyNotConfigured
    case invalidWalletAddress
    case readOnly

    var errorDescription: String? {
        switch self {
        case .privyNotConfigured: return "Sign-in is not set up in this build. Add the Privy keys to Secrets.xcconfig."
        case .invalidWalletAddress: return "The wallet address returned by Privy is not valid."
        case .readOnly: return "You are watching this address. Sign in to trade."
        }
    }
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
