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
        // The appearance lives on a View, not on the App's scene body: a scene body does not re-evaluate reliably on
        // an observable change, and the stale scheme it left on the root view controller shadowed the window.
        .preferredColorScheme(settings.appearance.colorScheme)
        // Privacy cover for the app-switcher snapshot: iOS screenshots the UI whenever the app leaves the foreground,
        // and that image is written to the app container. If a recovery phrase / private key were on screen (Import
        // Wallet), it would land in that snapshot. Covering the whole hierarchy the instant we're not active means the
        // snapshot only ever captures the cover, never a secret.
        .overlay { PrivacyCover(active: scenePhase == .active) }
        .task { session.start(); settings.appearance.apply() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { settings.appearance.apply() } }
        // Keep the per-wallet sessions tied to the active wallet: rebind whenever the signed-in address changes, so a
        // sign-out + import of a different wallet never carries over the previous account's social profile or its
        // authenticated Perpl trading session.
        .task(id: session.address) {
            env.social.bind(address: session.address)
            // A wallet that can sign connects to the backend by itself (one signature), so activity and settings are
            // recorded — and restored on a fresh device — without a separate step.
            if session.canSign, !env.social.isSignedIn { await env.social.signIn(session: session) }
            if env.social.isSignedIn, let address = session.address { await env.sync.restore(owner: address) }
            env.perplTrading.refresh(address: session.address)
            NotificationHub.shared.bind(owner: session.address)
        }
        .task { env.alertWatcher.start(env: env, settings: settings) }
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
    case home, launch, trade, moments
    var id: String { rawValue }
}

/// The tab bar plus everything layered over it: the side menu (the three-line button on Home) and the sections it
/// opens outside the tabs (Portfolio, News, Get Help, Profile) as full-screen covers.
struct MainTabView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            // Trade sits between Launch and Moments, dividing the two coin sections.
            Tab("Home", systemImage: "house", value: .home) { HomeView() }
            Tab("Launch", systemImage: "flame", value: .launch) { LaunchpadView() }
            Tab("Trade", systemImage: "arrow.left.arrow.right", value: .trade) { TradeView() }
            Tab("Moments", systemImage: "camera.aperture", value: .moments) { MomentsView() }
        }
        .sensoryFeedback(.selection, trigger: router.tab)
        .fullScreenCover(isPresented: $router.menuOpen) { SideMenuView() }
        .fullScreenCover(item: $router.presented) { screen in
            switch screen {
            case .portfolio: PortfolioView()
            case .news: NewsView()
            case .help: GetHelpView()
            case .profile: ProfileView(presented: true)
            case .notifications: NotificationCenterView()
            }
        }
    }
}
