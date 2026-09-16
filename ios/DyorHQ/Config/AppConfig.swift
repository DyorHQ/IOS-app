import DyorKit
import Foundation

/// Build-time configuration, injected through Secrets.xcconfig → Info.plist. Missing values degrade features
/// (sign-in methods, launchpad) instead of crashing, and the UI says what is missing.
struct AppConfig: Sendable {
    let privyAppID: String
    let privyClientID: String
    let rpcURL: URL
    let passkeyRelyingParty: String
    let perplBuilderID: Int
    let launchpad: LaunchpadAddresses
    /// Moments (v1.1) is live on Monad mainnet; the addresses are the verified deployment, baked into DyorKit.
    let moments: MomentsAddresses
    /// DyorHQ's Supabase backend (social, alerts, copy trading, launch index). The publishable key is safe to
    /// embed — row-level security protects the data — so these have working defaults.
    let supabaseURL: URL
    let supabaseKey: String
    /// Privy-hosted key-export page (Privy React SDK) loaded in a WebView to export an embedded wallet's key — the
    /// only supported path, since Privy's iOS SDK has no native export. Its origin must be a Privy allowed origin.
    let walletExportURL: URL?

    var hasPrivy: Bool { !privyAppID.isEmpty && !privyClientID.isEmpty }
    var hasPasskeys: Bool { hasPrivy && !passkeyRelyingParty.isEmpty }
    var hasSupabase: Bool { !supabaseKey.isEmpty }

    static let current: AppConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        func string(_ key: String) -> String {
            let raw = (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Unset xcconfig variables come through as empty or as the literal "$(NAME)".
            return raw.hasPrefix("$(") ? "" : raw
        }
        func address(_ key: String) -> Address { Address(string(key)) ?? .zero }
        let rpc = URL(string: string("MonadRPCURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? Monad.defaultRPC
        let supabaseURL = URL(string: string("SupabaseURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!
        let supabaseKey = { let key = string("SupabaseKey"); return key.isEmpty ? "sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT" : key }()
        return AppConfig(
            privyAppID: string("PrivyAppID"),
            privyClientID: string("PrivyClientID"),
            rpcURL: rpc,
            passkeyRelyingParty: string("PasskeyRelyingParty"),
            perplBuilderID: Int(string("PerplBuilderID")) ?? 0,
            launchpad: LaunchpadAddresses(
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
            walletExportURL: URL(string: string("WalletExportURL")).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        )
    }()
}
