import DyorKit
import Foundation

/// Build-time configuration, injected through Secrets.xcconfig → Info.plist. Missing values degrade features
/// (sign-in methods) instead of crashing, and the UI says what is missing; on-chain addresses have baked defaults.
struct AppConfig: Sendable {
    let privyAppID: String
    let privyClientID: String
    /// Monad RPC endpoints in failover order: the keyless public endpoints (`Monad.publicRPCs`). A Debug build may point
    /// at one override (a local fork); a Release build never reads an override, so no keyed provider URL can ship.
    let rpcURLs: [URL]
    /// The primary endpoint (Settings display, Privy's embedded-wallet chain).
    var rpcURL: URL { rpcURLs[0] }
    let passkeyRelyingParty: String
    /// Apple / Google sign-in through Privy. Off unless `SocialLoginsEnabled=YES` in Secrets.xcconfig; the methods must
    /// also be enabled in the Privy dashboard. When off, onboarding hides them so no one taps a disallowed method.
    let enableSocialLogins: Bool
    /// Passkey sign-in (Mera + Privy). Off unless `PasskeysEnabled=YES` in Secrets.xcconfig — passkeys need the
    /// associated-domains entitlement, the App ID capability, and a hosted AASA (owner steps), none live yet, so the
    /// UI hides passkey options until then rather than offering a flow that can't complete.
    let enablePasskeys: Bool
    let perplBuilderID: Int
    let launchpad: LaunchpadAddresses
    /// Moments (v1.1) is live on Monad mainnet; the addresses are the verified deployment, baked into DyorKit.
    let moments: MomentsAddresses
    /// DyorHQ's Supabase backend (social, alerts, launch index). The publishable key is safe to
    /// embed — row-level security protects the data — so these have working defaults.
    let supabaseURL: URL
    let supabaseKey: String
    /// Privy-hosted key-export page (Privy React SDK) loaded in a WebView to export an embedded wallet's key — the
    /// only supported path, since Privy's iOS SDK has no native export. Its origin must be a Privy allowed origin.
    let walletExportURL: URL?
    /// Optional NEAR account to receive the Bridge's integrator fee. The Aurora API key itself is NOT in the app: it
    /// lives server-side in the `aurora-proxy` Edge Function (Supabase secret AURORA_API_KEY).
    let auroraFeeRecipient: String?

    var hasPrivy: Bool { !privyAppID.isEmpty && !privyClientID.isEmpty }
    var hasBridge: Bool { hasSupabase }
    var hasPasskeys: Bool { hasPrivy && enablePasskeys && !passkeyRelyingParty.isEmpty }
    var hasSupabase: Bool { !supabaseKey.isEmpty }

    static let current: AppConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        func string(_ key: String) -> String {
            let raw = (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Unset xcconfig variables come through as empty or as the literal "$(NAME)".
            return raw.hasPrefix("$(") ? "" : raw
        }
        func bool(_ key: String) -> Bool { ["yes", "true", "1"].contains(string(key).lowercased()) }
        func address(_ key: String) -> Address { Address(string(key)) ?? .zero }
        #if DEBUG
        // Development only (e.g. an anvil fork at 127.0.0.1). project.yml empties MonadRPCURL for Release as well.
        let rpcOverride = URL(string: string("MonadRPCURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        #else
        let rpcOverride: URL? = nil
        #endif
        let rpcURLs = rpcOverride.map { [$0] } ?? Monad.publicRPCs
        let supabaseURL = URL(string: string("SupabaseURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!
        let supabaseKey = { let key = string("SupabaseKey"); return key.isEmpty ? "sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT" : key }()
        return AppConfig(
            privyAppID: string("PrivyAppID"),
            privyClientID: string("PrivyClientID"),
            rpcURLs: rpcURLs,
            passkeyRelyingParty: string("PasskeyRelyingParty"),
            enableSocialLogins: bool("SocialLoginsEnabled"),
            enablePasskeys: bool("PasskeysEnabled"),
            perplBuilderID: Int(string("PerplBuilderID")) ?? 0,
            // The audited mainnet launchpad is baked into DyorKit (checked against contracts/deployments/143.json by
            // its tests). Setting LAUNCHPAD_FACTORY in Secrets.xcconfig points a build at another deployment — a fork
            // rehearsal — and then all five module addresses come from the xcconfig.
            launchpad: string("LaunchpadFactory").isEmpty ? .monadMainnet : LaunchpadAddresses(
                factory: address("LaunchpadFactory"),
                router: address("LaunchRouter"),
                escrow: address("FeeEscrow"),
                holderFeeSharing: address("HolderFeeSharing"),
                hook: address("MemeHook"),
                poolManager: Uniswap.poolManager
            ),
            moments: .monadMainnet,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            walletExportURL: URL(string: string("WalletExportURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil },
            auroraFeeRecipient: { let r = string("AuroraFeeRecipient"); return r.isEmpty ? nil : r }()
        )
    }()
}
