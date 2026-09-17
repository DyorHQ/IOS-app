import LocalAuthentication
import SwiftUI

/// User-controlled appearance and trading preferences. Persisted to `UserDefaults` so a choice survives launches,
/// and observed so the whole app restyles the moment it changes (the Appearance sheet, notifications, defaults).
@Observable
@MainActor
final class AppSettings {
    var appearance: AppearanceMode { didSet { store(appearance.rawValue, "settings.appearance") } }
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

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
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
