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
    /// The retired Moments cohorts (2, then 1), one service each, CLAIM-ONLY: holders claim vested coins and creators
    /// withdraw their own proceeds and pool fees; nothing else is reachable. They never feed the Moments board, the
    /// feeds, publishing or swap routing — those stay on `moments`.
    let retiredMoments: [RetiredMoments]
    let news: NewsService
    let activity: TokenActivityService
    let swapHistory: SwapHistoryService
    let walletDiscovery: WalletTokenDiscovery
    /// Every NFT the wallet holds on Monad, from its own transfer history (Moments and any other collection).
    let nftDiscovery: WalletNFTDiscovery
    let kuruTokens: KuruTokenListClient
    let venueTokens: VenueTokensService
    let session: Session
    /// Aurora Intents cross-chain bridge (Home "Bridge") + the multi-chain balance reader behind it.
    let aurora: AuroraIntents
    let chainBalances = MultiChainBalances()
    let settings = AppSettings()
    /// Authenticated Perpl trading. A passkey account's trading key lives and dies with its session (`session.mera`).
    let perplTrading: PerplTrading
    /// The wallet's cross-section volume / fees / P&L model, shared by Home's Total Volume and the Portfolio page.
    let portfolio = PortfolioModel()
    let alertWatcher = AlertWatcher()
    let social: SocialSession
    /// Mirrors activity, notifications, alerts and settings to Supabase, and restores them on a new device.
    let sync: BackendSync

    init(config: AppConfig) {
        self.config = config
        social = SocialSession(config: config)
        // Keyless public endpoints with failover. Batches stay under rpc.monad.xyz's 50-items-per-second budget; calls
        // it throttles are retried on rpc1, which limits requests rather than items.
        rpc = RPCClient(urls: config.rpcURLs, maxBatch: 40)
        multicall = Multicall(rpc: rpc)
        sender = TransactionSender(rpc: rpc)
        // The Aurora API key never ships in the app: bridge calls go through the aurora-proxy Edge Function, which
        // holds the key and only serves a signed-in wallet.
        let backend = social.client
        aurora = AuroraIntents(proxy: backend.functionURL("aurora-proxy"), feeRecipient: config.auroraFeeRecipient,
                               authorize: { try await backend.sessionHeaders() })
        prices = PriceService(rpc: rpc)
        // Graduated launchpad and Moment pools become swap routes on Uniswap v4: the live factory's pools and those of
        // the retired factories with the current record (the legacy 0xad3d… launches all graduate on Monday Trade).
        let retiredFactories = LaunchpadAddresses.retiredStacks.filter { !$0.legacyRecord && $0.factory != config.launchpad.factory }.map(\.factory)
        swap = SwapEngine(rpc: rpc, launchpadFactories: config.launchpad.isDeployed ? [config.launchpad.factory] + retiredFactories : [], moments: config.moments)
        perpl = PerplService(rpc: rpc)
        launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad)
        moments = MomentsService(rpc: rpc, addresses: config.moments)
        retiredMoments = MomentsAddresses.retiredMainnet.filter { $0.factory != config.moments.factory }.map { [rpc] in RetiredMoments(rpc: rpc, addresses: $0) }
        news = NewsService()
        // History reads want the larger log-chunk RPC (rpc1), like the launchpad does. A local fork keeps its own
        // logs, so a development build pointed at 127.0.0.1 scans the fork instead.
        let host = config.rpcURL.host() ?? ""
        let logsURL = host == "127.0.0.1" || host == "localhost" ? config.rpcURL : LaunchpadService.defaultLogsRPC
        activity = TokenActivityService(rpc: RPCClient(url: logsURL))
        swapHistory = SwapHistoryService(rpc: RPCClient(url: logsURL))
        // Wallet discovery scans logs on rpc1 and reads balances/metadata on the primary multicall.
        walletDiscovery = WalletTokenDiscovery(logsRPC: RPCClient(url: logsURL), multicall: multicall)
        nftDiscovery = WalletNFTDiscovery(logsRPC: RPCClient(url: logsURL), multicall: multicall)
        kuruTokens = KuruTokenListClient()
        // The venue-wide pool scan (from genesis, no wallet filter) runs on rpc3 so it never crowds out the wallet's
        // own history scans on rpc1, which answer a whole history in one call.
        venueTokens = VenueTokensService(logsRPC: RPCClient(url: URL(string: "https://rpc3.monad.xyz")!), multicall: multicall)
        session = Session(config: config, backend: social)
        // A passkey session's scope check trusts only the configured Moments cohorts, and signs a launchpad trade only
        // against the curve a known factory recorded on-chain (MERA-PLAN §3).
        session.mera.contracts = Mera.SigningPolicy.Contracts(moments: config.moments)
        session.mera.curveVerifier = { [launchpad] token in await launchpad.knownCurve(token: token) }
        perplTrading = PerplTrading(mera: session.mera)
        // The chain's word on which positions are open, which the automatic TP/SL clean-up needs besides the stream's.
        // A position the account's bitmap holds but the read left out (a failed sub-read, a market not listed) throws:
        // it is never read as closed.
        perplTrading.readPositions = { [perpl] address, markets in
            guard let account = try await perpl.account(address) else { return [] }
            let positions = try await perpl.positions(account, markets: markets)
            guard Set(positions.map(\.perpId)).isSuperset(of: account.positionPerpIds) else {
                throw PerplTradeError.unavailable("Perpl positions couldn't be read in full.")
            }
            return positions
        }
        sync = BackendSync(social: social)
        sync.install(settings: settings, address: { [weak session] in session?.address })
    }

    /// A transaction sender for `chain`: Monad reuses the app's configured endpoint (and multicall); every other
    /// source chain gets a sender bound to that chain's public RPC + id, so the same wallet key signs a valid
    /// transfer there.
    func sender(for chain: EVMChain) -> TransactionSender {
        chain.isMonad ? sender : TransactionSender(rpc: RPCClient(url: chain.rpcURL), chainId: chain.chainId)
    }

    /// The retired Moments cohort whose factory is `factory`, or nil (the live cohort, or anything else).
    func retiredMoments(for factory: Address) -> RetiredMoments? {
        retiredMoments.first { $0.factory == factory }
    }

    /// The Bridge's Monad chain descriptor, pointed at the app's configured RPC rather than the public default.
    var bridgeMonad: EVMChain { EVMChain.monad(rpc: config.rpcURL) }

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
