import Foundation

/// Whether a wallet may buy or sell xStocks (tokenized stocks) in the app now. Eligibility is the disclosure and the
/// owner's switches only: no storefront, region or attestation check is made (owner decision).
///
/// - Buying needs all of: a build with the stock venue (`OneInch.compiledIn`); the owner's opt-in switch
///   (`RemoteFlags.xStocks`) or the wallet's beta bit from the server; the server's mode `on`; and this wallet's
///   acknowledgement of the current disclosure (`XStocksDisclosureStore`).
/// - Selling needs only the build and a server mode of `on` or `sell-only`: never the switch or the disclosure, so a
///   holder can always leave in the app unless the server is off. Sending them never depends on any of this.
///
/// Every input starts closed: the mode is `off` until the server's status is read, the switch is off until a read says
/// JSON `true`, and no wallet has acknowledged anything.
public struct XStocksAvailability: Equatable, Sendable {
    /// The server's serving mode (`ONEINCH_MODE`), unset meaning off.
    public enum Mode: String, Equatable, Sendable {
        case off
        case sellOnly = "sell-only" // not localized: the server's own value
        case on

        /// The mode a status answer names; anything else is off.
        public init(serverValue: String?) {
            self = serverValue.flatMap(Mode.init(rawValue:)) ?? .off
        }
    }

    public var compiledIn: Bool
    /// The owner's opt-in switch (`RemoteFlags.xStocks`).
    public var flag: Bool
    /// The server marks this wallet as a beta wallet: it stands in for the switch, nothing else.
    public var beta: Bool
    public var mode: Mode
    /// This wallet acknowledged the current disclosure.
    public var disclosureAcknowledged: Bool

    public init(compiledIn: Bool = OneInch.compiledIn, flag: Bool = false, beta: Bool = false, mode: Mode = .off, disclosureAcknowledged: Bool = false) {
        self.compiledIn = compiledIn
        self.flag = flag
        self.beta = beta
        self.mode = mode
        self.disclosureAcknowledged = disclosureAcknowledged
    }

    public var canBuy: Bool { compiledIn && (flag || beta) && mode == .on && disclosureAcknowledged }
    public var canSell: Bool { compiledIn && (mode == .on || mode == .sellOnly) }
}

/// Which wallets acknowledged the xStocks disclosure, and of which version: one entry per wallet in UserDefaults
/// ("xstocks.disclosure.v1", lower-case address to version), never a secret. An acknowledgement of an earlier version
/// counts as none, so raising `currentVersion` asks every wallet again.
public enum XStocksDisclosureStore {
    public static let defaultsKey = "xstocks.disclosure.v1" // not localized: a storage key
    /// The disclosure's version now. Raise it whenever its text changes in substance.
    public static let currentVersion = 1

    /// Whether `wallet` acknowledged the current version.
    public static func isAcknowledged(_ wallet: Address, defaults: UserDefaults = .standard) -> Bool {
        let versions = defaults.dictionary(forKey: defaultsKey) as? [String: Int]
        return versions?[wallet.hex.lowercased()] == currentVersion
    }

    /// Records that `wallet` acknowledged the current version.
    public static func acknowledge(_ wallet: Address, defaults: UserDefaults = .standard) {
        var versions = defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        versions[wallet.hex.lowercased()] = currentVersion
        defaults.set(versions, forKey: defaultsKey)
    }

    /// Forgets `wallet`'s acknowledgement: on sign-out, removing the wallet and deleting the account.
    public static func forget(_ wallet: Address, defaults: UserDefaults = .standard) {
        guard var versions = defaults.dictionary(forKey: defaultsKey) as? [String: Int] else { return }
        versions[wallet.hex.lowercased()] = nil
        defaults.set(versions, forKey: defaultsKey)
    }
}
