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
        case apple, google, email, passkey, watchOnly

        var title: String {
            switch self {
            case .apple: return "Apple"
            case .google: return "Google"
            case .email: return "Email"
            case .passkey: return "Passkey"
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
    private var observing = false

    var account: Account? { if case .signedIn(let account) = state { return account } else { return nil } }
    var address: Address? { account?.address }
    var canSign: Bool { account?.canSign ?? false }

    init(config: AppConfig) {
        self.config = config
        privy = config.hasPrivy ? PrivySdk.initialize(config: PrivyConfig(appId: config.privyAppID, appClientId: config.privyClientID, loggingConfig: PrivyLoggingConfig(logLevel: .warning))) : nil
    }

    /// Starts following Privy's auth state. Safe to call more than once.
    func start() {
        guard !observing else { return }
        observing = true
        if let watched = WatchOnlyStore.load() {
            state = .signedIn(watched)
        }
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
            if let watched = WatchOnlyStore.load() { state = .signedIn(watched) } else { state = .signedOut }
        case .authenticated(let user):
            await adopt(user)
        }
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

    func signOut() async {
        WatchOnlyStore.clear()
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
