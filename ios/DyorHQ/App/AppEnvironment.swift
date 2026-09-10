import DyorKit
import Foundation
import Observation

/// Long-lived services shared by every screen. Built once at launch from the app configuration.
@Observable
@MainActor
final class AppEnvironment {
    let config: AppConfig
    let rpc: RPCClient
    let multicall: Multicall
    let sender: TransactionSender
    let prices: PriceService
    let swap: SwapEngine
    let perpl: PerplService
    let launchpad: LaunchpadService
    let activity: TokenActivityService
    let swapHistory: SwapHistoryService
    let walletDiscovery: WalletTokenDiscovery
    let kuruTokens: KuruTokenListClient
    let venueTokens: VenueTokensService
    let session: Session
    let settings = AppSettings()
    let perplTrading = PerplTrading()
    let alertWatcher = AlertWatcher()
    let social: SocialSession

    init(config: AppConfig) {
        self.config = config
        social = SocialSession(config: config)
        rpc = RPCClient(url: config.rpcURL)
        multicall = Multicall(rpc: rpc)
        sender = TransactionSender(rpc: rpc)
        prices = PriceService(rpc: rpc)
        swap = SwapEngine(rpc: rpc)
        perpl = PerplService(rpc: rpc)
        launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad)
        // History reads want the larger log-chunk RPC, like the launchpad does.
        activity = TokenActivityService(rpc: RPCClient(url: LaunchpadService.defaultLogsRPC))
        swapHistory = SwapHistoryService(rpc: RPCClient(url: LaunchpadService.defaultLogsRPC))
        // Wallet discovery scans logs on rpc1 and reads balances/metadata on the primary multicall.
        walletDiscovery = WalletTokenDiscovery(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC), multicall: multicall)
        kuruTokens = KuruTokenListClient()
        venueTokens = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC), multicall: multicall)
        session = Session(config: config)
    }

    /// Refreshes the global venue token list (Uniswap + Monday Trade) at most once a day: scans the venues' pools for
    /// the tradeable set, enriches each with an accurate Kuru logo, and caches it for the swap picker's browse list.
    func refreshVenueTokens() async {
        guard VenueTokenStore.isStale() else { return }
        let tokens = await venueTokens.tokens(exclude: Set(Token.core.map(\.address)))
        guard !tokens.isEmpty else { return }
        let logos = await kuruTokens.logos()
        let enriched = tokens.map { token -> Token in
            guard token.logoURL == nil, let logo = logos[token.address] else { return token }
            return Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logo, isLaunchpad: token.isLaunchpad)
        }
        VenueTokenStore.save(enriched)
    }
}
