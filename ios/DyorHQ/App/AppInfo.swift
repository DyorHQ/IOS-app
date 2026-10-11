import Foundation

/// The app's version (`CFBundleShortVersionString`, e.g. "1.1") and build number (`CFBundleVersion`, e.g. "23") from its
/// Info.plist, as the side menu, Profile, the support mail and the saved screens show or key them. Each is empty when the
/// key is missing. `UpdateGate` reads the build number itself: it needs nil, not an empty string, for a missing key.
enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
}
