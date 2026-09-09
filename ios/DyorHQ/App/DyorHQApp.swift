import SwiftUI

@main
struct DyorHQApp: App {
    @State private var environment = AppEnvironment(config: .current)
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.session)
                .environment(environment.settings)
                .environment(router)
                .tint(.accent)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
        }
    }
}
