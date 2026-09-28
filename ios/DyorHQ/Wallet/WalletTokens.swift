import BigInt
import DyorKit

/// Every token the wallet holds on Monad, read one way for every list of them — the Portfolio's Assets and the Send
/// sheet — so the two can't drift: native MON, the curated list, every token acquired in the app, and every ERC-20
/// the wallet's whole transfer history shows it received (Launchpad and Moment coins, airdrops, wrapped tokens), kept
/// while its balance is above zero and ranked by `WalletHoldings.ranked`.
@MainActor
enum WalletTokens {
    struct Read {
        /// The tokens held (balance above zero), in universe order.
        let tokens: [Token]
        let balances: [Address: BigUInt]
        /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12).
        let unverified: Set<Address>
    }

    /// The tokens `address` holds, with their balances. Throws when the balances can't be read, so a failed read is
    /// never taken for an empty wallet.
    static func read(env: AppEnvironment, address: Address) async throws -> Read {
        var universe = KnownTokenStore.universe(owner: address)
        let known = Set(universe.map(\.address))
        let discovered = await env.walletDiscovery.heldTokens(wallet: address, known: known, wholeHistory: true)
        universe += discovered
        let unverified = KnownTokenStore.unverified(owner: address).union(discovered.map(\.address))
        let balances = try await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)
        return Read(tokens: WalletHoldings.held(universe, balances: balances), balances: balances, unverified: unverified)
    }

    /// `read`'s tokens valued at their pools' prices and ranked. Prices that can't be read leave tokens unpriced, never
    /// hidden.
    static func ranked(_ read: Read, env: AppEnvironment) async -> [HeldToken] {
        let prices = (try? await env.prices.prices(for: read.tokens)) ?? [:]
        return WalletHoldings.ranked(read.tokens, balances: read.balances, prices: prices.mapValues(\.usd), unverified: read.unverified)
    }
}
