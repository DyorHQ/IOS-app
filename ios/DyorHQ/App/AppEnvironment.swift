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
    /// The live Moments cohort (v2). Not deployed while its addresses are pending: then the board says "not live yet"
    /// and the retired cohorts below still serve their holders.
    let moments: MomentsService
    /// The retired Moments cohorts (3, 2, then 1), one service each, CLAIM-ONLY: holders claim vested coins and creators
    /// withdraw their own proceeds and pool fees; nothing else is reachable. Cohorts 1 and 2 paid the retired wallets;
    /// cohort 3 pays the current ones and is retired because v2 replaced it. They never feed the Moments board, the
    /// feeds, publishing or swap routing — those stay on `moments`.
    let retiredMoments: [RetiredMoments]
    /// Moment names → share-link slugs, across every cohort (`MomentLink`, `MomentSlug`).
    let momentDirectory: MomentDirectory
    let news: NewsService
    let activity: TokenActivityService
    let swapHistory: SwapHistoryService
    let walletDiscovery: WalletTokenDiscovery
    /// Every NFT the wallet holds on Monad, from its own transfer history (Moments and any other collection).
    let nftDiscovery: WalletNFTDiscovery
    let kuruTokens: KuruTokenListClient
    let venueTokens: VenueTokensService
    /// Whether the venue token list is still short of the chain head: read from genesis (a fresh install, or the read
    /// build 17 makes once more), or stopped short by a gap. The swap picker says so while a search may miss a token.
    private(set) var venueListCatchingUp = false
    let session: Session
    /// Aurora Intents cross-chain bridge (Home "Bridge") + the multi-chain balance reader behind it.
    let aurora: AuroraIntents
    let chainBalances = MultiChainBalances()
    /// Every bridge deposit sent, tracked until it settles — across relaunches, for the account that sent it.
    let bridgeTracker: BridgeTracker
    let settings = AppSettings()
    /// The minimum supported build: below it, "Update required" replaces the app (GP-2).
    let updateGate = UpdateGate()
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
        bridgeTracker = BridgeTracker(aurora: aurora, balances: MultiChainBalances(), monad: EVMChain.monad(rpc: config.rpcURL))
        prices = PriceService(rpc: rpc)
        // Graduated launchpad and Moment pools become swap routes on Uniswap v4: the live factory's pools (once v2 is
        // deployed) and those of the retired factories with the current record (the legacy 0xad3d… launches all
        // graduate on Monday Trade). A pending live stack adds nothing, so nothing is read from address 0.
        swap = SwapEngine(rpc: rpc, launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: config.launchpad), moments: config.moments)
        perpl = PerplService(rpc: rpc)
        launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad)
        moments = MomentsService(rpc: rpc, addresses: config.moments)
        retiredMoments = MomentsAddresses.retiredMainnet.filter { $0.factory != config.moments.factory }.map { [rpc] in RetiredMoments(rpc: rpc, addresses: $0) }
        #if DEBUG
        // A fork rehearsal (Secrets.xcconfig MOMENTS_*, Debug only): v2 links (c4) and names follow the Moments this build
        // shows. Without the override this is nil, and c4 stays MomentsAddresses.monadMainnet.
        MomentLink.Cohort.rehearse(liveFactory: config.moments.factory == MomentsAddresses.monadMainnet.factory ? nil : config.moments.factory)
        #endif
        // Every Moment's name in publish order, for share links by name (dyorhq.fun/moments/<name>): cohorts 1–3 up to
        // their pinned counts, then v2 once it is wired.
        momentDirectory = MomentDirectory(rpc: rpc)
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
        // The venue-wide pool scan (from genesis, no wallet filter) reads rpc1, which answers a range of any span up to 10K
        // logs: one range a venue for each 5M-block segment, the venues one after the other, one request at a time, a
        // throttle waited out rather than split (`VenueTokensService`). About 70 requests from genesis, so it doesn't crowd
        // out the wallet's own history scans and every other reader there; rpc3 answers 1,000 blocks a request: about
        // 330,000.
        venueTokens = VenueTokensService(logsRPC: RPCClient(url: LaunchpadService.defaultLogsRPC), multicall: multicall)
        session = Session(config: config, backend: social)
        // A passkey session's scope check trusts only the configured Moments cohorts — v2 (collects, once deployed), then
        // cohorts 3, 2 and 1 (claims and creator withdrawals) — and signs a launchpad trade only against the curve a
        // known factory recorded on-chain (MERA-PLAN §3).
        session.mera.contracts = Mera.SigningPolicy.Contracts(moments: config.moments)
        session.mera.curveVerifier = { [launchpad] token in await launchpad.knownCurve(token: token) }
        // Retired launchpads are sell-only (owner decision 2026-09-28): the wallet refuses a buy into a curve a retired
        // factory recorded, whatever the sheet declared or a Face ID approved.
        session.mera.retiredCurveLookup = { [launchpad] curves in await launchpad.retiredCurves(among: curves) }
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
    /// survives the app backgrounding; later runs resume from the checkpoint and only read the new tail. The checkpoint
    /// moves past a segment only once it was read in full; a segment read in part is read again next time
    /// (`VenueTokensService.refresh`). Each new token is enriched with its accurate Kuru logo and appended to the cache
    /// the swap picker browses. Runs after `AppSettings` has decided App Lock, so what the store writes can't turn it off.
    func refreshVenueTokens() async {
        let checkpoint = VenueTokenStore.lastBlock()
        venueListCatchingUp = checkpoint == 0
        let read = await venueTokens.refresh(tokens: VenueTokenStore.all(), checkpoint: checkpoint,
                                             logos: { [kuruTokens] in await kuruTokens.logos() }) { progress in
            VenueTokenStore.save(progress.tokens, lastBlock: progress.checkpoint)
            await MainActor.run { self.venueListCatchingUp = !progress.complete }
        }
        // Nothing read (the head couldn't be read): the list is as it was, and so is what the picker says.
        if let read { venueListCatchingUp = !read.complete }
    }
}
