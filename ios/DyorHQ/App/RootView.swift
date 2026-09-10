import SwiftUI

/// Chooses between onboarding and the app, following the session state.
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
            case .signedOut:
                OnboardingView()
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.default, value: session.state)
        .task { session.start() }
        .task { env.alertWatcher.start(env: env, settings: settings) }
        .task { env.copyWatcher.start(env: env, settings: settings) }
        .task { env.mmWatcher.start(env: env) }
        .task { await env.refreshVenueTokens() }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, launch, trade, strategy, profile
    var id: String { rawValue }
}

struct MainTabView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: .home) { HomeView() }
            Tab("Launch", systemImage: "flame", value: .launch) { LaunchpadView() }
            Tab("Trade", systemImage: "arrow.left.arrow.right", value: .trade) { TradeView() }
            Tab("Strategy", systemImage: "wand.and.stars", value: .strategy) { StrategyView() }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) { ProfileView() }
        }
        .sensoryFeedback(.selection, trigger: router.tab)
    }
}
