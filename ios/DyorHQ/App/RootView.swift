import SwiftUI

/// Chooses between onboarding and the app, following the session state.
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

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
        // Privacy cover for the app-switcher snapshot: iOS screenshots the UI whenever the app leaves the foreground,
        // and that image is written to the app container. If a recovery phrase / private key were on screen (Import
        // Wallet), it would land in that snapshot. Covering the whole hierarchy the instant we're not active means the
        // snapshot only ever captures the cover, never a secret.
        .overlay { PrivacyCover(active: scenePhase == .active) }
        .task { session.start() }
        .task { env.alertWatcher.start(env: env, settings: settings) }
        .task { env.copyWatcher.start(env: env, settings: settings) }
        .task { env.mmWatcher.start(env: env) }
        .task { await env.refreshVenueTokens() }
    }
}

/// An opaque cover shown whenever the app is not foreground-active, so the OS snapshot can't capture on-screen secrets.
private struct PrivacyCover: View {
    let active: Bool
    var body: some View {
        if !active {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            .transition(.opacity)
        }
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
