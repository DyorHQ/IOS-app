import DyorKit
import Foundation
import Security

// What Perpl trading keeps on the device (forwarding memory, kill switches, census, API key and token in the Keychain).

/// Whether the last trading socket of a Perpl account reported one-click trading (order forwarding) on: a public flag,
/// never a key, in UserDefaults ("perpl.forwarding.v1.<chain>.<account>"). Written from what the socket reports, never from
/// the on-chain grant. A passkey account whose session is locked sends Close / Add Margin over the trading connection after
/// its step-up only when it was on (`PerplTrading.apiActionsAfterUnlock`).
enum PerplForwardingMemory {
    static func key(chainId: Int, accountId: Int) -> String { "perpl.forwarding.v1.\(chainId).\(accountId)" } // not localized: a storage key

    /// Nil when no socket of the account was ever signed in on this device.
    static func lastKnown(chainId: Int, accountId: Int, defaults: UserDefaults = .standard) -> Bool? {
        let key = key(chainId: chainId, accountId: accountId)
        return defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    static func record(_ forwarding: Bool, chainId: Int, accountId: Int, defaults: UserDefaults = .standard) {
        defaults.set(forwarding, forKey: key(chainId: chainId, accountId: accountId))
    }
}

/// The owner's two Perps kill switches (`RemoteFlags.perpsLiveOutcome`, `.perpsApiActions`) as the last check that read
/// `app_config` 'ios' found them: two Bools in UserDefaults ("perps.switches.v1"), never a secret. Saved each time a
/// check reads the row (`AppEnvironment.apply`); a failed check saves nothing and changes nothing (`UpdateGate` fails
/// open). Read once, when `PerplTrading` starts: before the first check of a launch the app uses the last values read,
/// so an OFF the owner engaged holds across a relaunch and an offline start until a check reads otherwise. Nothing
/// stored: both on (`RemoteFlags.on`).
enum PerpsSwitchStore {
    struct Switches: Equatable {
        let perpsLiveOutcome: Bool
        let perpsApiActions: Bool
    }

    static let key = "perps.switches.v1" // not localized: a storage key
    private static let liveOutcomeKey = "perpsLiveOutcome" // not localized: a storage key
    private static let apiActionsKey = "perpsApiActions" // not localized: a storage key

    /// The last values read on this device; nil before the first check that read the row (or for a value that isn't
    /// the two Bools).
    static var last: Switches? { read(from: .standard) }

    static func read(from defaults: UserDefaults) -> Switches? {
        guard let stored = defaults.dictionary(forKey: key), let live = stored[liveOutcomeKey] as? Bool,
              let api = stored[apiActionsKey] as? Bool else { return nil }
        return Switches(perpsLiveOutcome: live, perpsApiActions: api)
    }

    static func save(_ flags: RemoteFlags, defaults: UserDefaults = .standard) {
        defaults.set([liveOutcomeKey: flags.perpsLiveOutcome, apiActionsKey: flags.perpsApiActions], forKey: key)
    }
}

extension PerplTradeError {
    /// Refused on the device (the frame wouldn't do what the sheet says): never a reason to stop using the connection.
    var isInvalidOrder: Bool { if case .invalidOrder = self { return true }; return false }
}

/// The trading stream's census (`PerplStreamCensus`), merged across sockets and launches, in UserDefaults: counts only,
/// nothing secret and nothing that names an order or an account. The owner reads it from a TestFlight device's log to
/// judge the Perps kill switches (live outcome, API actions) on data, and turn either off.
struct PerplCensusStore {
    private static let key = "perpl.census.v1" // not localized: a storage key
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PerplStreamCensus {
        guard let data = defaults.data(forKey: Self.key), let census = try? JSONDecoder().decode(PerplStreamCensus.self, from: data) else { return PerplStreamCensus() }
        return census
    }

    func save(_ census: PerplStreamCensus) {
        guard let data = try? JSONEncoder().encode(census) else { return }
        defaults.set(data, forKey: Self.key)
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
