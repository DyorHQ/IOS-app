import CryptoKit
import DyorKit
import Foundation
import Observation

/// The only things the app remembers about a passkey account, both public: which credential backs it (so a
/// sign-in can be pinned to it) and the address it derives to (so the app can show the account while locked).
/// Neither is a secret; a fresh device reconstructs everything from the passkey alone.
enum MeraCredentialStore {
    private static let credentialKey = "mera.credential.v1"
    private static let addressKey = "mera.address.v1"

    static var credentialID: Data? { UserDefaults.standard.string(forKey: credentialKey).flatMap(Mera.Base64URL.decode) }
    static var address: Address? { UserDefaults.standard.string(forKey: addressKey).flatMap(Address.init) }

    static func save(credentialID: Data, address: Address) {
        UserDefaults.standard.set(Mera.Base64URL.encode(credentialID), forKey: credentialKey)
        UserDefaults.standard.set(address.checksummed, forKey: addressKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: credentialKey)
        UserDefaults.standard.removeObject(forKey: addressKey)
    }
}

/// A Mera passkey account and its signing session. One passkey ceremony (Face ID) yields the wallet key and
/// DyorHQ's utility namespace; both live in memory until the session ends — by time, by the app leaving, or by
/// the user locking it. Anything that signs while the session is live is prompt-free; anything after it re-runs
/// the ceremony, pinned to the same credential and checked to derive the same address.
@Observable
@MainActor
final class MeraSession {
    struct Unlocked {
        let credentialID: Data
        let account: Secp256k1Account
        /// PRF output of DyorHQ's utility namespace; nil when the authenticator evaluated only the first salt.
        let utility: Data?
        let unlockedAt: Date
    }

    enum Failure: LocalizedError {
        case notConfigured, differentPasskey(expected: Address, got: Address), noUtilityNamespace
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Passkeys are not set up in this build (no relying party)."
            case .differentPasskey(let expected, let got): return "That passkey belongs to \(got.short), not to this account (\(expected.short)). Sign out to switch accounts."
            case .noUtilityNamespace: return "This passkey provider evaluates one PRF salt only; capability keys are unavailable."
            }
        }
    }

    let rpId: String
    /// How long a session stays prompt-free after the last ceremony.
    var sessionLength: TimeInterval {
        didSet { UserDefaults.standard.set(sessionLength, forKey: "mera.sessionLength") }
    }
    private(set) var unlocked: Unlocked?
    private let ceremony = PasskeyCeremony()
    private var salts: (Data, Data) { (Mera.accountSalt, Mera.utilitySalt) }

    init(rpId: String) {
        self.rpId = rpId
        let stored = UserDefaults.standard.double(forKey: "mera.sessionLength")
        sessionLength = stored > 0 ? stored : 15 * 60
    }

    var address: Address? { unlocked?.account.address ?? MeraCredentialStore.address }
    var expiresAt: Date? { unlocked.map { $0.unlockedAt.addingTimeInterval(sessionLength) } }
    var isUnlocked: Bool { expiresAt.map { $0 > Date() } ?? false }

    // MARK: Ceremonies

    /// New account: one passkey ceremony, address on screen before the sheet closes. Nothing is stored but the
    /// credential id and the address.
    func create(userName: String) async throws -> Address {
        guard !rpId.isEmpty else { throw Failure.notConfigured }
        return try adopt(try await ceremony.create(rpId: rpId, userName: userName, salts: salts), expecting: nil)
    }

    /// Returning user, or a fresh device: any discoverable passkey for the relying party reconstructs the account.
    func signIn() async throws -> Address {
        guard !rpId.isEmpty else { throw Failure.notConfigured }
        return try adopt(try await ceremony.assert(rpId: rpId, salts: salts, credentialID: MeraCredentialStore.credentialID), expecting: MeraCredentialStore.address)
    }

    /// The live session, re-prompting when it is locked or expired. The re-prompt is pinned to the stored
    /// credential and must derive the stored address.
    func requireUnlocked() async throws -> Unlocked {
        if isUnlocked, let unlocked { return unlocked }
        guard !rpId.isEmpty else { throw Failure.notConfigured }
        let result = try await ceremony.assert(rpId: rpId, salts: salts, credentialID: MeraCredentialStore.credentialID)
        _ = try adopt(result, expecting: MeraCredentialStore.address)
        return unlocked!
    }

    /// A per-purpose key from the utility namespace (Perpl trading key, state encryption, social identity).
    func derivedKey(_ purpose: String) async throws -> Data {
        let session = try await requireUnlocked()
        guard let utility = session.utility else { throw Failure.noUtilityNamespace }
        return Mera.derivedKey(prf: utility, purpose: purpose)
    }

    /// Ends the session: the key material is dropped. The next signature runs a new ceremony.
    func lock() { unlocked = nil }

    /// Signs out: forgets which passkey backs the account. The passkey itself stays in the user's iCloud Keychain.
    func forget() {
        lock()
        MeraCredentialStore.clear()
    }

    private func adopt(_ result: PasskeyCeremony.Result, expecting: Address?) throws -> Address {
        guard let account = Mera.evmAccount(prf: result.account) else { throw PasskeyCeremony.Failure.prfUnavailable }
        if let expecting, expecting != account.address { throw Failure.differentPasskey(expected: expecting, got: account.address) }
        unlocked = Unlocked(credentialID: result.credentialID, account: account, utility: result.utility, unlockedAt: Date())
        MeraCredentialStore.save(credentialID: result.credentialID, address: account.address)
        return account.address
    }
}

/// The app's signer for a Mera account. Signing goes through the session, so a locked or expired session shows
/// the passkey prompt right where the signature is needed and never stores a key.
struct MeraWallet: Wallet, DigestSigner {
    let address: Address
    let session: MeraSession

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        try await session.requireUnlocked().account.sign(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data {
        try await session.requireUnlocked().account.signMessage(message)
    }

    func signDigest(_ digest: Data) async throws -> String {
        try await session.requireUnlocked().account.sign(hash32: digest).hexString
    }
}
