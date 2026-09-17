import LocalAuthentication
import SwiftUI
import UIKit

/// User-controlled appearance and trading preferences. Persisted to `UserDefaults` so a choice survives launches,
/// and observed so the whole app restyles the moment it changes (the Appearance sheet, notifications, defaults).
@Observable
@MainActor
final class AppSettings {
    var appearance: AppearanceMode { didSet { store(appearance.rawValue, "settings.appearance"); appearance.apply() } }
    var notificationsEnabled: Bool { didSet { store(notificationsEnabled, "settings.notifications") } }
    /// Notify on fills and liquidations (a preference; delivery needs the system permission).
    var notifyFills: Bool { didSet { store(notifyFills, "settings.notifyFills") } }
    var notifyPriceAlerts: Bool { didSet { store(notifyPriceAlerts, "settings.notifyPrice") } }
    /// Notify when a copied trader makes a trade, so the user can confirm or decline copying it.
    var notifyCopyTrades: Bool { didSet { store(notifyCopyTrades, "settings.notifyCopy") } }
    /// Notify on strategy events: funding flips, liquidation warnings, TWAP progress, exits.
    var notifyStrategy: Bool { didSet { store(notifyStrategy, "settings.notifyStrategy") } }
    /// Strategy screens show every parameter and table (Pro) instead of the one-glance Simple layout.
    var proStrategies: Bool { didSet { store(proStrategies, "settings.proStrategies") } }
    /// The Delta Neutral "how it works" cards have been shown once.
    var dnIntroSeen: Bool { didSet { store(dnIntroSeen, "settings.dnIntroSeen") } }
    /// Require Face ID / Touch ID before signing a transaction — a device-side second factor for a self-custodial
    /// wallet, enforced in the confirmation sheet.
    var requireBiometrics: Bool { didSet { store(requireBiometrics, "settings.biometrics") } }
    /// Default leverage the perps ticket opens on.
    var defaultLeverage: Double { didSet { store(defaultLeverage, "settings.leverage") } }
    /// Max slippage for market orders and swaps, in basis points.
    var slippageBps: Int { didSet { store(slippageBps, "settings.slippageBps") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "settings.appearance") ?? "") ?? .system
        notificationsEnabled = defaults.object(forKey: "settings.notifications") as? Bool ?? true
        notifyFills = defaults.object(forKey: "settings.notifyFills") as? Bool ?? true
        notifyPriceAlerts = defaults.object(forKey: "settings.notifyPrice") as? Bool ?? false
        notifyCopyTrades = defaults.object(forKey: "settings.notifyCopy") as? Bool ?? true
        notifyStrategy = defaults.object(forKey: "settings.notifyStrategy") as? Bool ?? true
        proStrategies = defaults.object(forKey: "settings.proStrategies") as? Bool ?? false
        dnIntroSeen = defaults.object(forKey: "settings.dnIntroSeen") as? Bool ?? false
        requireBiometrics = defaults.object(forKey: "settings.biometrics") as? Bool ?? false
        defaultLeverage = defaults.object(forKey: "settings.leverage") as? Double ?? 2
        slippageBps = defaults.object(forKey: "settings.slippageBps") as? Int ?? 50
    }

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key); AppSettings.onChange?() }

    /// Mirrors settings to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (() -> Void)?

    /// The settings as a JSON object, for the backend copy (no keys, no addresses).
    var snapshot: [String: Any] {
        ["appearance": appearance.rawValue, "notificationsEnabled": notificationsEnabled, "notifyFills": notifyFills,
         "notifyPriceAlerts": notifyPriceAlerts, "notifyCopyTrades": notifyCopyTrades, "notifyStrategy": notifyStrategy,
         "proStrategies": proStrategies, "dnIntroSeen": dnIntroSeen, "defaultLeverage": defaultLeverage, "slippageBps": slippageBps]
    }

    /// Applies a backend copy of the settings (a fresh device after sign-in). Unknown keys are ignored.
    func apply(snapshot: [String: Any]) {
        if let raw = snapshot["appearance"] as? String, let mode = AppearanceMode(rawValue: raw) { appearance = mode }
        if let v = snapshot["notificationsEnabled"] as? Bool { notificationsEnabled = v }
        if let v = snapshot["notifyFills"] as? Bool { notifyFills = v }
        if let v = snapshot["notifyPriceAlerts"] as? Bool { notifyPriceAlerts = v }
        if let v = snapshot["notifyCopyTrades"] as? Bool { notifyCopyTrades = v }
        if let v = snapshot["notifyStrategy"] as? Bool { notifyStrategy = v }
        if let v = snapshot["proStrategies"] as? Bool { proStrategies = v }
        if let v = snapshot["dnIntroSeen"] as? Bool { dnIntroSeen = v }
        if let v = snapshot["defaultLeverage"] as? Double { defaultLeverage = v }
        if let v = snapshot["slippageBps"] as? Int { slippageBps = v }
    }
}

/// Face ID / Touch ID gate used before signing when the user turns on the app lock.
enum BiometricGate {
    /// Whether the device can do biometric auth at all (so we don't offer a toggle that can never work).
    static var isAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    /// "Face ID", "Touch ID", or a generic name for the copy in Security.
    static var typeName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// Prompts for biometrics; returns true to proceed. If the device has no biometrics enrolled, it does not block.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Light / Dark / System, the same three choices Apple's own apps offer.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The scheme this mode actually renders as right now: the choice itself, or what the system is currently set to.
    /// A sheet keeps the scheme it was presented with, so the Appearance sheet styles itself from this.
    @MainActor
    var resolved: ColorScheme {
        if let colorScheme { return colorScheme }
        // The scene's own traits, not a window's: a window carries the override we just set, and its trait collection
        // only catches up on the next layout pass, so reading it here would hand back the scheme we are leaving.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Restyles every window right now. `preferredColorScheme` on the root view only reaches the window itself, so a
    /// sheet or full-screen cover that is already on screen — Profile, and the Appearance sheet above it — keeps the
    /// old scheme until it is dismissed. Setting the window's own style restyles the presented hierarchy with it, so
    /// the switch is visible the instant it is tapped.
    @MainActor
    func apply() {
        let style = interfaceStyle
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
                // A presented sheet or full-screen cover carries its own override once SwiftUI has set one, which
                // would shadow the window; clear it down the chain so the whole stack follows.
                var presented = window.rootViewController
                while let controller = presented {
                    controller.overrideUserInterfaceStyle = style
                    presented = controller.presentedViewController
                }
            }
        }
    }

    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

extension Color {
    /// A dynamic color that resolves per the active interface style, so a hue can be tuned separately for
    /// light and dark without an asset-catalog entry.
    init(light: Color, dark: Color) {
        self = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    // Allocation ring hues — three restrained, distinguishable tones that hold up on paper and ink grounds.
    // They are identity, not status: never reused for up/down, which stay Positive/Negative.
    static let allocationSpot = Color(light: Color(red: 0.12, green: 0.51, blue: 0.60), dark: Color(red: 0.42, green: 0.79, blue: 0.86))
    static let allocationPerps = Color(light: Color(red: 0.36, green: 0.33, blue: 0.66), dark: Color(red: 0.62, green: 0.58, blue: 0.95))
    static let allocationLaunchpad = Color(light: Color(red: 0.72, green: 0.48, blue: 0.14), dark: Color(red: 0.93, green: 0.71, blue: 0.36))
    static let allocationMoments = Color(light: Color(red: 0.70, green: 0.30, blue: 0.42), dark: Color(red: 0.94, green: 0.56, blue: 0.68))
}
