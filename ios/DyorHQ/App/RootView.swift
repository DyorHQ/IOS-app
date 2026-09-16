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
        // Keep the per-wallet sessions tied to the active wallet: rebind whenever the signed-in address changes, so a
        // sign-out + import of a different wallet never carries over the previous account's social profile or its
        // authenticated Perpl trading session.
        .task(id: session.address) {
            env.social.bind(address: session.address)
            env.perplTrading.refresh(address: session.address)
        }
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
    case home, trade, launch, moments, strategy
    var id: String { rawValue }
}

/// The tab bar plus everything layered over it: the side menu (the three-line button on Home) and the sections it
/// opens outside the tabs (Portfolio, News, Get Help, Profile) as full-screen covers.
struct MainTabView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: .home) { HomeView() }
            Tab("Trade", systemImage: "arrow.left.arrow.right", value: .trade) { TradeView() }
            Tab("Launch", systemImage: "flame", value: .launch) { LaunchpadView() }
            Tab("Moments", systemImage: "camera.aperture", value: .moments) { MomentsView() }
            Tab("Strategy", systemImage: "wand.and.stars", value: .strategy) { StrategyView() }
        }
        .sensoryFeedback(.selection, trigger: router.tab)
        .fullScreenCover(isPresented: $router.menuOpen) { SideMenuView() }
        .fullScreenCover(item: $router.presented) { screen in
            switch screen {
            case .portfolio: PortfolioView()
            case .news: NewsView()
            case .help: GetHelpView()
            case .profile: ProfileView(presented: true)
            }
        }
    }
}
