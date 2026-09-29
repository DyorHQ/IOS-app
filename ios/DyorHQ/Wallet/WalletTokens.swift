import BigInt
import DyorKit

/// Every token the wallet holds on Monad, read one way for every list of them — the Portfolio's Assets and the Send
/// sheet — so the two can't drift: native MON, the curated list, every token acquired in the app, and every ERC-20
/// the wallet's whole transfer history shows it received (Launchpad and Moment coins, airdrops, wrapped tokens), kept
/// while its balance is above zero and ranked by `WalletHoldings.ranked`.
@MainActor
enum WalletTokens {
    struct Read {
        /// The tokens held (balance above zero), in universe order. Never an NFT collection.
        let tokens: [Token]
        let balances: [Address: BigUInt]
        /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12).
        let unverified: Set<Address>
        /// False when part of the wallet's history couldn't be read (`WalletTokenDiscovery.Scan`): a token it received
        /// outside the app may be missing, which a list says rather than passing `tokens` off as everything.
        let complete: Bool
    }

    /// The tokens `address` holds, with their balances. Throws when the balances can't be read, so a failed read is
    /// never taken for an empty wallet.
    static func read(env: AppEnvironment, address: Address) async throws -> Read {
        var universe = KnownTokenStore.universe(owner: address)
        let known = Set(universe.map(\.address))
        let scan = await env.walletDiscovery.scan(wallet: address, known: known, wholeHistory: true)
        universe += scan.tokens
        let unverified = KnownTokenStore.unverified(owner: address).union(scan.tokens.map(\.address))
        let balances = try await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)
        let held = WalletHoldings.held(universe, balances: balances)
        // Earlier builds' discovery stored NFT collections as tokens (their `balanceOf` counts editions): left out, as
        // discovery now leaves them out. An edition can't be sent as a token, and it shows under NFTs.
        let collections = await env.walletDiscovery.collections(among: held)
        return Read(tokens: held.filter { !collections.contains($0.address) }, balances: balances, unverified: unverified, complete: scan.complete)
    }

    /// `read`'s tokens, valued and ranked.
    struct Ranked {
        let tokens: [HeldToken]
        /// The price read failed: only the tokens priced by definition (USDC, AUSD at $1) have a value, the rest are
        /// unpriced, and the order is by amount rather than value — a list says so, and a send preselects nothing.
        let pricesFailed: Bool
    }

    /// `read`'s tokens valued at their pools' prices and ranked. Prices that can't be read leave tokens unpriced, never
    /// hidden, and say so (`Ranked.pricesFailed`).
    static func ranked(_ read: Read, env: AppEnvironment) async -> Ranked {
        let prices: [Address: PriceInfo]
        var failed = false
        do {
            prices = try await env.prices.prices(for: read.tokens)
        } catch {
            prices = PriceService.definedPrices(for: read.tokens)
            failed = true
        }
        return Ranked(tokens: WalletHoldings.ranked(read.tokens, balances: read.balances, prices: prices.mapValues(\.usd), unverified: read.unverified), pricesFailed: failed)
    }
}
