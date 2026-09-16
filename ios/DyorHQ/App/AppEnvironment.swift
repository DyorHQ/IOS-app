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
    let moments: MomentsService
    let news: NewsService
    let activity: TokenActivityService
    let swapHistory: SwapHistoryService
    let walletDiscovery: WalletTokenDiscovery
    let kuruTokens: KuruTokenListClient
    let venueTokens: VenueTokensService
    let session: Session
    let settings = AppSettings()
    let perplTrading = PerplTrading()
    /// The wallet's cross-section volume / fees / P&L model, shared by Home's Total Volume and the Portfolio page.
    let portfolio = PortfolioModel()
    let alertWatcher = AlertWatcher()
    let copyWatcher = CopyTradeWatcher()
    let mmWatcher = MMWatcher()
    let social: SocialSession

    init(config: AppConfig) {
        self.config = config
        social = SocialSession(config: config)
        rpc = RPCClient(url: config.rpcURL)
        multicall = Multicall(rpc: rpc)
        sender = TransactionSender(rpc: rpc)
        prices = PriceService(rpc: rpc)
        // Graduated launchpad and Moment pools become swap routes on Uniswap v4.
        swap = SwapEngine(rpc: rpc, launchpadFactory: config.launchpad.isDeployed ? config.launchpad.factory : nil, moments: config.moments)
        perpl = PerplService(rpc: rpc)
        launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad)
        moments = MomentsService(rpc: rpc, addresses: config.moments)
        news = NewsService()
        // History reads want the larger log-chunk RPC (rpc1), like the launchpad does. A local fork keeps its own
        // logs, so a development build pointed at 127.0.0.1 scans the fork instead.
        let host = config.rpcURL.host() ?? ""
        let logsURL = host == "127.0.0.1" || host == "localhost" ? config.rpcURL : LaunchpadService.defaultLogsRPC
        activity = TokenActivityService(rpc: RPCClient(url: logsURL))
        swapHistory = SwapHistoryService(rpc: RPCClient(url: logsURL))
        // Wallet discovery scans logs on rpc1 and reads balances/metadata on the primary multicall.
        walletDiscovery = WalletTokenDiscovery(logsRPC: RPCClient(url: logsURL), multicall: multicall)
        kuruTokens = KuruTokenListClient()
        venueTokens = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC), multicall: multicall)
        session = Session(config: config)
    }

    /// Builds/refreshes the global venue token list (Uniswap + Monday Trade). The first run scans the FULL history
    /// from genesis in checkpointed segments (rpc1 serves old logs even though it prunes old state), so progress
    /// survives the app backgrounding; later runs resume from the checkpoint and only read the new tail. Each new
    /// token is enriched with its accurate Kuru logo and appended to the cache the swap picker browses.
    func refreshVenueTokens() async {
        let head = await venueTokens.head()
        let start = VenueTokenStore.lastBlock()
        guard head > 0, start < head else { return }
        let logos = await kuruTokens.logos()
        let segment: UInt64 = 5_000_000
        var from = start
        while from <= head, !Task.isCancelled {
            let to = min(from + segment, head)
            let existing = VenueTokenStore.all()
            let exclude = Set(Token.core.map(\.address)).union(existing.map(\.address))
            let found = await venueTokens.tokens(fromBlock: from, toBlock: to, exclude: exclude)
            let enriched = found.map { token -> Token in
                guard token.logoURL == nil, let logo = logos[token.address] else { return token }
                return Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logo, isLaunchpad: token.isLaunchpad)
            }
            // Advance the checkpoint every segment — even an empty one — so an interruption never re-scans it.
            VenueTokenStore.save(existing + enriched, lastBlock: to)
            if to >= head { break }
            from = to + 1
        }
    }
}
