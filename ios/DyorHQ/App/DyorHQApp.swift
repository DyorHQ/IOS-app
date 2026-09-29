import SwiftUI
import UIKit

@main
struct DyorHQApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment(config: .current)
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.session)
                .environment(environment.settings)
                .environment(environment.perplTrading)
                .environment(environment.social)
                .environment(router)
                .tint(.brand)
        }
    }
}

/// App-wide policies only UIKit's application delegate can set.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// No third-party keyboards anywhere in the app (security audit 2026-09-26, IOSK-8). A custom keyboard given "Allow
    /// Full Access" can send whatever is typed with it — a recovery phrase or private key being imported, the password
    /// that is an Email & Password wallet — off the phone. The system keyboards stay available.
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
