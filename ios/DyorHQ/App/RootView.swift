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
                // A passkey account just deleted: what's left to do about the passkey, then onboarding.
                if let done = session.passkeyDeletion {
                    AccountDeletedView(done: done) { session.passkeyDeletion = nil }
                } else {
                    OnboardingView()
                }
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
        // snapshot only ever captures the cover, never a secret. The one exception is a passkey ceremony: its system
        // sheet makes the scene .inactive, and the cover must not blank the app behind it. Only a passkey (Mera)
        // ceremony counts, so a build without passkey accounts covers exactly as before.
        .overlay { PrivacyCover(active: scenePhase == .active || (scenePhase == .inactive && session.mera.isPrompting)) }
        .task { session.start(); settings.appearance.apply(); Notifications.configure() }
        .onChange(of: scenePhase) { _, phase in
            // A passkey (Mera) signing session must not outlive the user leaving the app: whoever picks the phone up
            // next has to present the passkey again. Ending it also closes a passkey account's Perpl socket and drops
            // its trading key.
            if phase == .background { session.mera.end() }
            if phase == .active {
                settings.appearance.apply()
                // Reconnect the trading socket the instant the app returns (iOS drops it while suspended), so TP/SL is
                // ready without waiting for the keep-alive loop's next tick. Never a prompt: a passkey account's
                // socket reconnects only inside a live session, and there is none right after a return.
                Task { await env.perplTrading.ensureConnected() }
            }
        }
        // Keep the per-wallet sessions tied to the active wallet: rebind whenever the signed-in address changes, so a
        // sign-out + import of a different wallet never carries over the previous account's social profile or its
        // authenticated Perpl trading session.
        .task(id: session.address) {
            env.social.bind(address: session.address)
            // A wallet that can sign connects to the backend by itself (one signature), so activity and settings are
            // recorded — and restored on a fresh device — without a separate step. Not a passkey account restored
            // locked at launch: that signature would be a passkey prompt nobody asked for. `signInWithMera` starts its
            // sign-in while its session is live (this joins it), and the background signer never prompts.
            if session.canSignWithoutPrompt, !env.social.isSignedIn, let address = session.address, let wallet = session.backgroundWallet {
                await env.social.signIn(address: address, wallet: wallet)
            }
            env.perplTrading.refresh(account: session.account)
            NotificationHub.shared.bind(owner: session.address)
            // Ask for notification permission once the user is signed in and can act (so the swaps, fills and price
            // alerts the app notices while it runs can show). notificationsEnabled defaults on, but the Settings toggle
            // only requests when flipped — so a user who never opened Settings was never prompted.
            if session.canSign, settings.notificationsEnabled { await Notifications.requestAuthorizationIfUndetermined() }
        }
        // Whenever the account's backend session opens — whoever signed in (the rebind above, the reconnect below,
        // Bridge, a screen that uploads) or a stored token was restored — pull what other devices recorded. Idempotent:
        // activity merges without doubling, the other stores fill only while empty.
        .task(id: "\(env.social.isSignedIn)-\(session.address?.hex ?? "")") {
            guard env.social.isSignedIn, let address = session.address, env.social.isBound(to: address) else { return }
            await env.sync.restore(owner: address)
        }
        // An account that isn't connected to the backend (a passkey account restored locked, a sign-in skipped because
        // the app left the foreground, or a token that just expired after 12 h) reconnects as soon as it can sign
        // without a prompt: at once for a key or Privy wallet, when its session opens for a passkey account. Only once
        // the rebind above has bound this account, and never while a sign-in runs. It can't loop: a failed sign-in
        // leaves isSignedIn false throughout, so the id doesn't change; a success changes it once, then the guard stops.
        .task(id: "\(session.mera.isUnlocked)-\(env.social.isSignedIn)") {
            guard !env.social.isSignedIn, env.social.state == .signedOut, session.canSignWithoutPrompt,
                  let address = session.address, env.social.isBound(to: address), let wallet = session.backgroundWallet else { return }
            await env.social.signIn(address: address, wallet: wallet)
        }
        .task { env.alertWatcher.start(env: env, settings: settings, owner: { session.address }) }
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
