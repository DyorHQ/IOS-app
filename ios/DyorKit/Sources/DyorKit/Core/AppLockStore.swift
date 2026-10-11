import Foundation

/// App Lock's saved setting (`settings.biometrics`, the app's `AppSettings.requireBiometrics`) across an erase of this
/// device's data (R14), and the rule that tells a new install from one that ran before App Lock's default (R4), here so
/// they are tested.
public enum AppLockStore {
    /// The UserDefaults key App Lock is saved under.
    public static let key = "settings.biometrics"

    /// The prefixes of the UserDefaults keys an earlier run of the app writes. A store holding a key with one of them
    /// is an install from before App Lock's default, which keeps the OFF it has always had; a new
    /// install starts ON where the device can verify its owner (`AppSettings.appLockDefault`). So a key
    /// written on a first launch before that decision must never start with one of them (rule R4).
    public static let earlierRunPrefixes = ["settings.", "session.", "mera.", "localWallet.", "venueTokens.", "activityLog.",
                                            "notifications.", "knownTokens.", "priceAlerts.", "bridge.", "perp."]

    /// Whether a store holding `keys` is an install from before App Lock's default: one of its keys starts with one of
    /// `earlierRunPrefixes`.
    public static func isEarlierInstall(keys: some Sequence<String>) -> Bool {
        keys.contains { key in earlierRunPrefixes.contains { key.hasPrefix($0) } }
    }

    /// Erases `defaults`' `domain` (Delete Account, Forget This Device), then saves App Lock as a new install has it:
    /// ON where the device can verify its owner, OFF where it can't (App Lock fails closed there, and would block every
    /// signature). A launch decides App Lock only where nothing is saved, and takes a store holding what an earlier run
    /// writes (`session.`, `mera.`, `localWallet.`, `settings.`…: `isEarlierInstall`) for an install from before App
    /// Lock's default, which stays OFF. The next sign-in in this process writes
    /// those keys, so without this save the next launch would start App Lock OFF. Returns what was saved, for the
    /// setting in memory.
    @discardableResult
    public static func erase(_ defaults: some AppLockDefaults, domain: String, canAuthenticateOwner: Bool) -> Bool {
        defaults.removePersistentDomain(forName: domain)
        defaults.set(canAuthenticateOwner, forKey: key)
        return canAuthenticateOwner
    }
}

/// What `AppLockStore.erase` needs of the store: `UserDefaults`, or a test's in memory.
public protocol AppLockDefaults {
    func removePersistentDomain(forName domainName: String)
    func set(_ value: Bool, forKey defaultName: String)
}

extension UserDefaults: AppLockDefaults {}
