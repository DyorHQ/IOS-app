import BigInt
import DyorKit

/// Every token the wallet holds on Monad, read one way for every list of them — the Portfolio's Assets and the Send
/// sheet — so the two can't drift: native MON, the curated list, every token acquired in the app, and every ERC-20
/// the wallet's whole transfer history shows it received (Launchpad and Moment coins, airdrops, wrapped tokens), kept
/// while its balance is above zero, valued, and ranked (`WalletHoldings.ranked`): the Send list by value with unpriced
/// tokens after priced ones, the Portfolio in the order it has always used.
@MainActor
enum WalletTokens {
    struct Read {
        /// The wallet read.
        let owner: Address
        /// The tokens held (balance above zero), in universe order. Never an NFT collection.
        let tokens: [Token]
        let balances: [Address: BigUInt]
        /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12),
        /// except the DyorHQ coins that turn out to be its own (`ranked`).
        let unverified: Set<Address>
        /// False when part of the wallet's history (`WalletTokenDiscovery.Scan`) or of its balances couldn't be read: a
        /// token it holds may be missing, which a list says rather than passing `tokens` off as everything.
        let complete: Bool
    }

    /// The tokens `address` holds, with their balances (`ERC20.balanceReport`: MON on its own, the curated tokens in a read
    /// of their own, every other token in bounded reads, so no third-party contract can keep MON or a curated token from
    /// being read, nor break the whole list). Throws when no balance could be read at all, so a failed read is never
    /// taken for an empty wallet; a part that couldn't be read leaves the list incomplete (`Read.complete`), with a token
    /// whose balance read failed left out as it always was when it is one only stored here, and said when it is MON, a
    /// curated token or one the history just found.
    static func read(env: AppEnvironment, address: Address) async throws -> Read {
        var universe = KnownTokenStore.universe(owner: address)
        let known = Set(universe.map(\.address))
        let scan = await env.walletDiscovery.scan(wallet: address, known: known, wholeHistory: true)
        universe += scan.tokens
        let unverified = KnownTokenStore.unverified(owner: address).union(scan.tokens.map(\.address))
        let report = await ERC20.balanceReport(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)
        if report.balances.isEmpty, !report.unread.isEmpty || !report.failed.isEmpty { throw BalancesUnread() }
        let mustRead = Set([Monad.native] + Token.core.map(\.address) + scan.tokens.map(\.address))
        let balancesComplete = report.unread.isEmpty && report.failed.isDisjoint(with: mustRead)
        let held = WalletHoldings.held(universe, balances: report.balances)
        // Earlier builds' discovery stored NFT collections as tokens (their `balanceOf` counts editions): left out, as
        // discovery now leaves them out. An edition can't be sent as a token, and it shows under NFTs.
        let collections = await env.walletDiscovery.collections(among: held)
        return Read(owner: address, tokens: held.filter { !collections.contains($0.address) }, balances: report.balances, unverified: unverified,
                    complete: scan.complete && balancesComplete)
    }

    /// No balance could be read.
    struct BalancesUnread: Error {}

    /// `read`'s tokens, valued and ranked.
    struct Ranked {
        let tokens: [HeldToken]
        /// The price read failed: the pool finder's prices are missing (USDC and AUSD keep their $1), so most tokens are
        /// unpriced and ranked by amount rather than value — a list says so, and a send preselects nothing.
        let pricesFailed: Bool
    }

    /// `read`'s tokens valued and ranked by `order` (the Send list's unless another is given): at their pools' prices,
    /// and DyorHQ's own coins as the app values them everywhere else (`WalletHoldings.pricing`) — a launch coin at its
    /// curve's or pool's price in its pair asset, a Moment coin at its pool's USDC price — which no pool the price finder
    /// looks for gives them. Prices that can't be read leave tokens unpriced, never hidden, and say so
    /// (`Ranked.pricesFailed`). A DyorHQ coin the wallet launched, or whose Moment it collected or created, is its own,
    /// not Unverified (`WalletHoldings.unverified`).
    static func ranked(_ read: Read, env: AppEnvironment, by order: (HeldToken, HeldToken) -> Bool = WalletHoldings.precedes) async -> Ranked {
        async let coins = appCoins(read, env: env)
        // The launchpad's pair assets too (MON, USDC, AUSD, aBIL), whether held or not: a launch coin's price is in one.
        var seen = Set<Address>()
        let priced = (read.tokens + [Token.mon] + Token.core.filter { Token.launchpadPairAssets.contains($0.address) }).filter { seen.insert($0.address).inserted }
        let prices: [Address: PriceInfo]
        var failed = false
        do {
            prices = try await env.prices.prices(for: priced)
        } catch {
            prices = PriceService.definedPrices(for: priced)
            failed = true
        }
        let own = await coins
        let valued = WalletHoldings.pricing(prices.mapValues(\.usd), launches: own.launches, moments: own.moments.mapValues { $0.pool?.usdcPerCoin })
        let unverified = WalletHoldings.unverified(read.unverified, owner: read.owner, launches: own.launches, staked: own.staked)
        return Ranked(tokens: WalletHoldings.ranked(read.tokens, balances: read.balances, prices: valued, unverified: unverified, by: order), pricesFailed: failed)
    }

    /// DyorHQ's own coins among a read's tokens, as their factories record them.
    struct AppCoins {
        /// Launch coins, with their launches: any launchpad, live or retired, in any phase.
        var launches: [Address: Launch] = [:]
        /// Moment coins, with their Moments: the live cohort's or a retired one's.
        var moments: [Address: MomentInfo] = [:]
        /// The Moment coins whose Moment this wallet collected or created.
        var staked: Set<Address> = []
    }

    /// Which of `read`'s tokens DyorHQ's contracts made. MON and the curated tokens are never asked; a coin whose record
    /// or Moment couldn't be read is left out, and then valued like any other token.
    private static func appCoins(_ read: Read, env: AppEnvironment) async -> AppCoins {
        let candidates = read.tokens.filter { !$0.isNative && Token.core($0.address) == nil }
        guard !candidates.isEmpty else { return AppCoins() }
        let launchpad = env.launchpad
        async let launches = (try? await launchpad.recordedLaunches(candidates)) ?? [:]
        async let moments = momentCoins(candidates.map(\.address), owner: read.owner, env: env)
        let found = await moments
        return AppCoins(launches: await launches, moments: found.moments, staked: found.staked)
    }

    /// The Moments whose coins are among `coins`: the live cohort's, by its factory's `momentIdByCoin`, and the retired
    /// cohorts', from their fixed list (`MomentsAddresses.retiredMainnetCoins`). A Moment is kept only when it names the
    /// coin it was found for. `staked`: those whose Moment `owner` collected or created, from each cohort's vesting; a
    /// cohort whose stakes can't be read stakes nothing, and its coins stay as marked.
    private static func momentCoins(_ coins: [Address], owner: Address, env: AppEnvironment) async -> (moments: [Address: MomentInfo], staked: Set<Address>) {
        let live = env.moments
        let ids = (try? await live.momentIds(coins: coins)) ?? [:]
        var reads: [(coin: Address, read: @Sendable () async -> MomentInfo?)] = []
        for coin in coins {
            if let id = ids[coin] {
                reads.append((coin, { try? await live.info(id: id) }))
            } else if let key = MomentsAddresses.retiredMainnetCoins[coin], let cohort = env.retiredMoments(for: key.factory) {
                reads.append((coin, { try? await cohort.info(id: key.id) }))
            }
        }
        guard !reads.isEmpty else { return ([:], []) }
        let moments = await withTaskGroup(of: (Address, MomentInfo?).self) { group in
            for (coin, read) in reads { group.addTask { (coin, await read()) } }
            var out: [Address: MomentInfo] = [:]
            for await (coin, info) in group { if let info, info.moment.coin == coin { out[coin] = info } }
            return out
        }
        // Each cohort's portfolio rows, in one read per cohort: the account's collects, plus a creator's allocation.
        var rows: [MomentPortfolioRow] = []
        let infos = Array(moments.values)
        let liveInfos = infos.filter { $0.moment.factory == env.config.moments.factory }
        if !liveInfos.isEmpty, let portfolio = try? await live.portfolio(account: owner, moments: liveInfos) { rows += portfolio.rows }
        for cohort in env.retiredMoments {
            let own = infos.filter { $0.moment.factory == cohort.factory }
            if !own.isEmpty, let positions = try? await cohort.positions(account: owner, moments: own) { rows += positions.map(\.row) }
        }
        let staked = Set(rows.filter { $0.isCreator || $0.entitlement > 0 }.map(\.moment.moment.coin)).intersection(moments.keys)
        return (moments, staked)
    }
}
