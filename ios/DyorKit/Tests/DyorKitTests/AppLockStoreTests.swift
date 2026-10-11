import XCTest
@testable import DyorKit

/// App Lock across an erase of this device's data (`AppLockStore`). The re-review's finding, from before build 17: the
/// erase removed App Lock's saved setting with everything else, and signing back in without a relaunch wrote `session.`,
/// `mera.`, `localWallet.` and `settings.` keys, so the next launch took the device for an install from before App
/// Lock's default and started it OFF.
final class AppLockStoreTests: XCTestCase {
    /// A store in memory, as `UserDefaults` keeps one domain.
    private final class Store: AppLockDefaults {
        var values: [String: Any] = [:]
        func removePersistentDomain(forName domainName: String) { values = [:] }
        func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    }

    func testAnEraseSavesAppLockAsANewInstallHasIt() {
        for canAuthenticateOwner in [true, false] {
            let store = Store()
            store.values = [AppLockStore.key: !canAuthenticateOwner, "venueTokens.v1": Data([1]), "session.account": "0x7777777777777777777777777777777777777777"]
            XCTAssertEqual(AppLockStore.erase(store, domain: "fun.dyorhq.app", canAuthenticateOwner: canAuthenticateOwner), canAuthenticateOwner)
            XCTAssertEqual(store.values.keys.sorted(), [AppLockStore.key], "everything else erased")
            XCTAssertEqual(store.values[AppLockStore.key] as? Bool, canAuthenticateOwner,
                           "ON where the device can verify its owner, OFF where it can't, whatever was saved before")
            // A sign-in in the same process writes keys that tell an earlier install apart: App Lock stays saved, so the
            // next launch reads it rather than deciding it.
            store.values["session.watchOnly"] = true
            store.values["mera.sessionLength"] = 900
            XCTAssertEqual(store.values[AppLockStore.key] as? Bool, canAuthenticateOwner)
        }
    }

    /// The rule a launch decides App Lock's default by (R4): a store holding a key that starts with a prefix an earlier
    /// run writes is an install from before the default, which stays OFF; one holding none is a new install.
    func testAnEarlierRunsKeysMarkAnEarlierInstall() {
        // The key every install has saved App Lock under. Under another one, an install that had it ON would find nothing
        // saved, be taken for an install from before the default (it holds `settings.` and `session.` keys) and start OFF.
        XCTAssertEqual(AppLockStore.key, "settings.biometrics", "the key every install saved App Lock under")
        XCTAssertEqual(AppLockStore.earlierRunPrefixes, ["settings.", "session.", "mera.", "localWallet.", "venueTokens.", "activityLog.",
                                                         "notifications.", "knownTokens.", "priceAlerts.", "bridge.", "perp."])
        XCTAssertFalse(AppLockStore.isEarlierInstall(keys: []), "an empty store: a new install")
        XCTAssertFalse(AppLockStore.isEarlierInstall(keys: ["AppleLanguages", "AppleLocale", LanguageResolution.initializedKey]),
                       "the system's keys and the language's: a new install")
        for prefix in AppLockStore.earlierRunPrefixes {
            XCTAssertTrue(AppLockStore.isEarlierInstall(keys: ["AppleLanguages", prefix + "v1"]), prefix)
            XCTAssertTrue(AppLockStore.isEarlierInstall(keys: [prefix]), "the prefix alone: \(prefix)")
            XCTAssertFalse(AppLockStore.isEarlierInstall(keys: [String(prefix.dropLast())]), "without its dot: \(prefix)")
            XCTAssertFalse(AppLockStore.isEarlierInstall(keys: ["x" + prefix + "v1"]), "only at the start of a key: \(prefix)")
            XCTAssertFalse(AppLockStore.isEarlierInstall(keys: [prefix.uppercased() + "v1"]), "case counts: \(prefix)")
        }
        XCTAssertTrue(AppLockStore.isEarlierInstall(keys: [AppLockStore.key]), "App Lock's own key is a setting")
        // Any sequence of keys, as `UserDefaults.dictionaryRepresentation().keys` gives them.
        let store: [String: Any] = ["AppleLanguages": ["en"], LanguageResolution.initializedKey: true]
        XCTAssertFalse(AppLockStore.isEarlierInstall(keys: store.keys))
        XCTAssertTrue(AppLockStore.isEarlierInstall(keys: store.merging(["session.account": "0x7777777777777777777777777777777777777777"]) { $1 }.keys))
    }

    /// The app erases this device's data through `AppLockStore` only, with the fresh-install rule, and sets the setting in
    /// memory to match; the setting it saves is the one `AppSettings` reads at launch.
    func testTheAppErasesThroughIt() throws {
        let session = AppSource.squeezed(try AppSource.app("Wallet/Session.swift"))
        let erase = try XCTUnwrap(session.range(of: "func eraseLocalData() async {")).upperBound
        let body = session[erase...]
        let saved = try XCTUnwrap(body.range(of: "let appLock = AppLockStore.erase(UserDefaults.standard, domain: bundle, canAuthenticateOwner: BiometricGate.canAuthenticateOwner)"))
        let inMemory = try XCTUnwrap(body.range(of: "settings?.requireBiometrics = appLock"))
        XCTAssertLessThan(saved.upperBound, inMemory.lowerBound)
        XCTAssertLessThan(inMemory.upperBound, try XCTUnwrap(body.range(of: "state = .signedOut")).lowerBound, "before the sign-out")
        XCTAssertTrue(AppSource.squeezed(try AppSource.app("App/AppEnvironment.swift")).contains("session.settings = settings"))

        // Nothing else in the app erases the store.
        for (path, text) in try AppSource.allAppFiles() {
            XCTAssertFalse(text.contains("removePersistentDomain"), (path as NSString).lastPathComponent)
        }

        // `AppSettings` reads and saves App Lock under the same key, and a change of it isn't reported to the backend
        // mirror (`onChange` marks the settings changed, which would keep the next sign-in's restore out).
        let appSettings = AppSource.squeezed(try AppSource.declaration(of: "AppSettings").text)
        XCTAssertTrue(appSettings.contains("var requireBiometrics: Bool { didSet { defaults.set(requireBiometrics, forKey: AppLockStore.key) } }"))
        XCTAssertTrue(appSettings.contains("requireBiometrics = defaults.object(forKey: AppLockStore.key) as? Bool ?? Self.appLockDefault(defaults)"))
        // The default is decided by the rule above (`isEarlierInstall`), over every key the store holds, and saved.
        XCTAssertTrue(appSettings.contains("let isEarlierInstall = AppLockStore.isEarlierInstall(keys: defaults.dictionaryRepresentation().keys)"))
        XCTAssertTrue(appSettings.contains("let on = !isEarlierInstall && BiometricGate.canAuthenticateOwner"), "the fresh-install rule the erase uses")
        XCTAssertTrue(appSettings.contains("defaults.set(on, forKey: AppLockStore.key) return on"))
    }
}
