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
        session = Session(config: config)
    }
}
