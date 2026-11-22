import BigInt
import Foundation

/// Monad mainnet (chain id 143). Every address here was verified for bytecode on 2026-09-08 and comes from the
/// venue's own documentation; see docs/swap-spec.md and docs/app-wiring.md at the repository root.
public enum Monad {
    public static let chainId = 143
    public static let chainIdHex = "0x8f"
    public static let defaultRPC = URL(string: "https://rpc.monad.xyz")!
    /// Keyless public Monad RPC endpoints in failover order (docs.monad.xyz → Network information): QuickNode's
    /// rpc.monad.xyz (25 rps, batch ≤ 100) then Alchemy's rpc1.monad.xyz (15 rps, batch ≤ 100). Limits are per client
    /// IP, so every phone has its own budget — and no provider API key ever ships inside the app.
    public static let publicRPCs = [defaultRPC, URL(string: "https://rpc1.monad.xyz")!]
    public static let explorer = URL(string: "https://monadscan.com")!
    public static let nativeSymbol = "MON"

    public static let native = Address.zero
    public static let wmon = Address(literal: "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A")
    public static let usdc = Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603")
    public static let usdt0 = Address(literal: "0xe7cd86e13AC4309349F30B3435a9d337750fC82D")
    public static let weth = Address(literal: "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242")
    public static let ausd = Address(literal: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a")

    public static func explorerTransaction(_ hash: Data) -> URL { explorer.appending(path: "tx/\(hash.hexString)") }
    public static func explorerAddress(_ address: Address) -> URL { explorer.appending(path: "address/\(address.checksummed)") }
    public static func explorerToken(_ address: Address) -> URL { explorer.appending(path: "token/\(address.checksummed)") }
}

public enum Uniswap {
    public static let v3Factory = Address(literal: "0x204faca1764b154221e35c0d20abb3c525710498")
    public static let quoterV2 = Address(literal: "0x661e93cca42afacb172121ef892830ca3b70f08d")
    public static let swapRouter02 = Address(literal: "0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900")
    public static let poolManager = Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e")
    public static let v4Quoter = Address(literal: "0xa222dd357a9076d1091ed6aa2e16c9742dd26891")
    public static let stateView = Address(literal: "0x77395f3b2e73ae90843717371294fa97cc419d64")
    public static let universalRouter = Address(literal: "0x0d97dc33264bfc1c226207428a79b26757fb9dc3")
    public static let permit2 = Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3")
    public static let v3FeeTiers = [100, 500, 3000, 10000]
    /// Hookless v4 pools use the canonical fee / tick-spacing pairs.
    public static let v4Tiers: [(fee: Int, tickSpacing: Int)] = [(100, 1), (500, 10), (3000, 60), (10000, 200)]
}

/// Nad.fun's DEX — a Uniswap v2 fork where graduated Nad.fun memecoins (e.g. JAMES) hold their liquidity. Their
/// pairs are always against WMON, and prices come from the pair reserves rather than a v3 sqrt price.
public enum NadFun {
    public static let factory = Address(literal: "0xA25b13127e63ddae6d0b35570FF3D39dBD621001")
}

public enum MondayTrade {
    public static let factory = Address(literal: "0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21")
    public static let quoterV2 = Address(literal: "0xB97eCD41Aef0F842E773C8F9905919cDE49880C9")
    public static let swapRouter = Address(literal: "0xFE951b693A2FE54BE5148614B109E316B567632F")
    public static let feeTiers = [100, 300, 500, 3000, 10000]
}

/// 1inch on Monad: the one router the app could ever send a 1inch swap to, and the two other 1inch contracts it never
/// talks to. Nothing in this build quotes or builds a 1inch swap: `compiledIn` is false, so `ThirdPartyCalldataGuard`
/// refuses every call to the router on every signer, and the passkey policy refuses it too.
public enum OneInch {
    /// AggregationRouterV6. UNVERIFIED (research R3a): taken from Monad's protocol directory
    /// (github.com/monad-crypto/protocols, mainnet/1inch.jsonc); its code hash on Monad has not been compared with the
    /// router deployed on Ethereum yet.
    public static let router = Address(literal: "0x111111125421cA6dc452d289314280a0f8842A65")
    /// Aqua. UNVERIFIED (research R3a), same source. The app never calls it or approves it: refused outright.
    public static let aqua = Address(literal: "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a")
    /// SwapVMRouter. UNVERIFIED (research R3a), same source. The app never calls it or approves it: refused outright.
    public static let swapVMRouter = Address(literal: "0x111111338c5091E8440b67B168bAe16a668AC0De")
    /// The 1inch contracts no transaction of the app may call or name as a spender.
    public static let refusedContracts: Set<Address> = [aqua, swapVMRouter]

    /// Whether this build may send a 1inch swap at all. False in every public build until the venue is released; a
    /// DEBUG build run with `-oneInchCompiledIn YES` turns it on for internal testing. It is read once, from the build
    /// and its launch arguments only: no remote switch can change it.
    public static let compiledIn: Bool = {
        #if DEBUG
        // not localized: a launch argument's name
        return UserDefaults.standard.object(forKey: "oneInchCompiledIn") != nil && UserDefaults.standard.bool(forKey: "oneInchCompiledIn")
        #else
        return false
        #endif
    }()

    /// How long a firm quote stays fillable, counted on the device from the moment its request is sent. UNVERIFIED
    /// (research R5): xChange's RFQ window on Monad has not been measured; 20 s is a cautious guess.
    public static let firmWindow: Duration = .seconds(20)
    /// A plan whose quote has less than this left is not started at all. UNVERIFIED (research R5).
    public static let startMargin: Duration = .seconds(5)
    /// The swap is not signed with less than this left: it covers signing and the broadcast. UNVERIFIED (research R5, R9).
    public static let signMargin: Duration = .seconds(3)
    /// The most slippage a stock trade may take, in basis points (1%): the passkey policy refuses a lower minimum.
    public static let stockSlippageCapBps = 100
    /// How far a stock quote's price may be from the stock's own reference price (`XStockReference`), either way, in
    /// basis points (3%): a quote further off, better or worse, is refused (`XStockPriceBand`).
    public static let priceBandBps = 300
    /// A firm price further than this from the reference, in basis points (1%), is still traded but shown as changed.
    public static let priceWarningBps = 100
    /// A firm quote that gives more than this less than the estimate shown before Review, in basis points (0.5%), is
    /// shown as changed on the review sheet.
    public static let priceChangedBps = 50
    /// The most one stock trade may be worth, in USDC base units (6 decimals): $250. On what a buy pays and on what a
    /// sell receives; the proxy holds the same cap.
    public static let tradeCapUSDC = BigUInt(250_000_000)
}

/// Tokenized stocks (xStocks) on Monad. Every list is EMPTY in this build: no issuer address, decimals or reference feed
/// has been verified yet (research R4, R6, R11), so no token is known as an xStock and nothing here changes what the app
/// does. Detection is by these lists only: no implementation-hash check is built (research R15), so a copy deployed
/// somewhere the lists don't name is an ordinary token to the app.
///
/// The app reads the one registry it ships (`shipped`). A registry can be made only inside DyorKit (`Registry.init` is
/// internal), so tests build fixture registries with test-only addresses and hand them to `SwapEngine` and
/// `PriceService`, and no fixture address ever ships.
public enum XStocks {
    /// A curated xStock's independent on-chain reference price: a Chainlink AggregatorV3 feed, read with
    /// `latestRoundData()` (0xfeaf968c) and `decimals()` (0x313ce567) by `XStockReference`.
    public struct Feed: Hashable, Sendable {
        public let address: Address
        /// The most seconds the feed may go without an update: an answer older than this, by the chain's own clock, is
        /// stale and refused.
        public let heartbeat: Int
        /// The decimals of the feed's answer, as reviewed: a feed that reports others is refused.
        public let decimals: Int

        init(address: Address, heartbeat: Int, decimals: Int) {
            self.address = address
            self.heartbeat = heartbeat
            self.decimals = decimals
        }
    }

    /// What the app knows of xStocks: the ones it may trade, the ones it knows and never trades, each traded one's
    /// reference feed, and the assets a stock may be traded against.
    public struct Registry: Sendable {
        /// The xStocks the app may trade, each native, issuer-canonical and with a reference feed (`feeds`).
        public let curated: [Token]
        /// xStocks the app knows of but never trades: bridged copies and the like, and any curated entry that came
        /// without a feed.
        public let knownUncurated: Set<Address>
        /// Each curated xStock's reference feed, by the stock's address.
        public let feeds: [Address: Feed]
        /// What a curated xStock may be traded against: USDC only.
        public let quoteAssets: [Address]

        /// A ticker with no feed is never listed: such an entry is moved to `knownUncurated`, so it is still a known
        /// xStock, refused everywhere, rather than an ordinary token.
        init(curated: [Token], knownUncurated: Set<Address>, feeds: [Address: Feed], quoteAssets: [Address] = [Monad.usdc]) {
            self.curated = curated.filter { feeds[$0.address] != nil }
            self.knownUncurated = knownUncurated.union(curated.filter { feeds[$0.address] == nil }.map(\.address))
            self.feeds = feeds.filter { address, _ in curated.contains { $0.address == address } }
            self.quoteAssets = quoteAssets
        }

        /// The curated xStock at `address`, or nil.
        public func curatedToken(_ address: Address) -> Token? { curated.first { $0.address == address } }

        /// Whether `address` is a known xStock, curated or not.
        public func isKnown(_ address: Address) -> Bool {
            knownUncurated.contains(address) || curatedToken(address) != nil
        }

        /// The pair as a stock trade the app may offer: a curated xStock on one side and a quote asset (USDC) on the
        /// other, `isBuy` when the stock is what is received. Nil for every other pair, two stocks included.
        public func stockPair(_ tokenIn: Token, _ tokenOut: Token) -> (stock: Token, isBuy: Bool)? {
            if let stock = curatedToken(tokenOut.address), quoteAssets.contains(tokenIn.address) { return (stock, true) }
            if let stock = curatedToken(tokenIn.address), quoteAssets.contains(tokenOut.address) { return (stock, false) }
            return nil
        }

        /// Whether a known xStock is on either side.
        public func touches(_ tokenIn: Token, _ tokenOut: Token) -> Bool {
            isKnown(tokenIn.address) || isKnown(tokenOut.address)
        }
    }

    /// The registry this build ships. UNVERIFIED (research R4, R6, R11): every list is empty.
    public static let shipped = Registry(curated: [], knownUncurated: [], feeds: [:])

    /// The xStocks the app could trade (`shipped`). UNVERIFIED (research R4, R6): empty.
    public static var curated: [Token] { shipped.curated }
    /// xStocks the app knows of but never trades (`shipped`). UNVERIFIED (research R4, R6): empty.
    public static var knownUncurated: Set<Address> { shipped.knownUncurated }
    /// What a curated xStock may be traded against: USDC only.
    public static var quoteAssets: [Address] { shipped.quoteAssets }
    /// Each curated xStock's reference feed (`shipped`). UNVERIFIED (research R11): empty.
    public static var feeds: [Address: Feed] { shipped.feeds }

    /// Whether `address` is a known xStock, curated or not (`shipped`).
    public static func isKnown(_ address: Address) -> Bool { shipped.isKnown(address) }
}

public enum Kuru {
    public static let api = URL(string: "https://ws.kuru.io")!
    /// Kuru's public, unauthenticated token/market data host (distinct from the Flow quote host `api`).
    public static let dataApi = URL(string: "https://api.kuru.io")!
    public static let entrypoint = Address(literal: "0xb3e6778480b2E488385E8205eA05E20060B813cb")
}

public enum Perpl {
    public static let exchange = Address(literal: "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F")
    public static let collateral = Monad.ausd // AUSD
    public static let collateralDecimals = 6
    public static let api = URL(string: "https://app.perpl.xyz/api")!
    /// Perpl's market-data stream. It only accepts its own origin, so clients send `Origin: https://app.perpl.xyz`.
    public static let websocket = URL(string: "wss://app.perpl.xyz/ws/v1/market-data")!
    public static let websocketOrigin = "https://app.perpl.xyz"
    public static let minimumDeposit: BigUInt = 10_000_000 // 10 AUSD
}

/// A token the app knows how to show. Logos come from Monad's official token list.
public struct Token: Hashable, Sendable, Identifiable, Codable {
    public let address: Address
    public let symbol: String
    public let name: String
    public let decimals: Int
    public let logoURL: URL?
    public var isNative: Bool { address.isZero }
    public var isLaunchpad: Bool

    public var id: Address { address }

    /// The name a token the wallet holds is stored under when its symbol and name can't be read
    /// (`WalletTokenDiscovery`): English, as every earlier build stored it, so a stored list reads the same whatever
    /// language it was stored in and whichever build reads it. A screen shows `displayName`, in the app's language.
    // not localized: a stored value; `displayName` shows it in the app's language
    public static let unnamedName = "Token with no name"

    /// The name a screen shows: the token's own, or, for a token stored with no name (`unnamedName`, by this build or an
    /// earlier one), "Token with no name" in the app's language at the moment it is shown.
    public var displayName: String { name == Token.unnamedName ? L10n.tr("Token with no name") : name }

    public init(address: Address, symbol: String, name: String, decimals: Int, logoURL: URL? = nil, isLaunchpad: Bool = false) {
        self.address = address
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.logoURL = logoURL
        self.isLaunchpad = isLaunchpad
    }

    /// Native MON trades as WMON on the concentrated-liquidity venues.
    public var wrappedAddress: Address { isNative ? Monad.wmon : address }

    private static func logo(_ symbol: String, _ ext: String = "svg") -> URL? {
        URL(string: "https://raw.githubusercontent.com/monad-crypto/token-list/refs/heads/main/mainnet/\(symbol)/logo.\(ext)")
    }

    /// Curated spot assets from Monad's official token list (monad-crypto/token-list, mainnet v2.48).
    public static let core: [Token] = [
        // not localized: the tokens' own names
        Token(address: Monad.native, symbol: "MON", name: "Monad", decimals: 18, logoURL: logo("MON")),
        Token(address: Monad.wmon, symbol: "WMON", name: "Wrapped MON", decimals: 18, logoURL: logo("WMON")),
        Token(address: Monad.usdc, symbol: "USDC", name: "USDC", decimals: 6, logoURL: logo("USDC")),
        Token(address: Monad.usdt0, symbol: "USDT0", name: "USDT0", decimals: 6, logoURL: logo("USDT0")),
        Token(address: Monad.weth, symbol: "WETH", name: "Wrapped Ether", decimals: 18, logoURL: logo("WETH")),
        Token(address: Address(literal: "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"), symbol: "WBTC", name: "Wrapped BTC", decimals: 8, logoURL: logo("WBTC")),
        Token(address: Address(literal: "0xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b"), symbol: "cbBTC", name: "Coinbase Wrapped BTC", decimals: 8, logoURL: logo("cbBTC")),
        Token(address: Address(literal: "0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081"), symbol: "gMON", name: "gMON", decimals: 18, logoURL: logo("gMON")),
        Token(address: Address(literal: "0xA3227C5969757783154C60bF0bC1944180ed81B9"), symbol: "sMON", name: "Kintsu Staked Monad", decimals: 18, logoURL: logo("sMON")),
        Token(address: Address(literal: "0x0c65A0BC65a5D819235B71F554D210D3F80E0852"), symbol: "aprMON", name: "aPriori Monad LST", decimals: 18, logoURL: logo("aprMON")),
        Token(address: Address(literal: "0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c"), symbol: "shMON", name: "ShMonad", decimals: 18, logoURL: logo("shMON", "png")),
        Token(address: Monad.ausd, symbol: "AUSD", name: "AUSD", decimals: 6, logoURL: logo("AUSD")),
        // aBIL — Anchored's tokenized SPDR 1-3M T-Bill (an aStock). A transferable ERC-20 that trades in Monday's
        // spot AMM, so the app buys it like any token; it is the RWA-flavored launchpad pair without a partner key.
        Token(address: Address(literal: "0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f"), symbol: "aBIL", name: "SPDR 1-3M T-Bill aStock", decimals: 18, logoURL: nil),
        Token(address: Address(literal: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34"), symbol: "USDe", name: "USDe", decimals: 18, logoURL: logo("USDe")),
        Token(address: Address(literal: "0x111111d2bf19e43C34263401e0CAd979eD1cdb61"), symbol: "USD1", name: "World Liberty Financial USD", decimals: 6, logoURL: logo("USD1")),
        Token(address: Address(literal: "0xacA92E438df0B2401fF60dA7E4337B687a2435DA"), symbol: "mUSD", name: "MetaMask USD", decimals: 6, logoURL: logo("mUSD")),
        Token(address: Address(literal: "0xecAc9C5F704e954931349Da37F60E39f515c11c1"), symbol: "LBTC", name: "Lombard Staked Bitcoin", decimals: 8, logoURL: logo("LBTC")),
        Token(address: Address(literal: "0x2416092f143378750bb29b79eD961ab195CcEea5"), symbol: "ezETH", name: "Renzo Restaked ETH", decimals: 18, logoURL: logo("ezETH")),
        Token(address: Address(literal: "0xC50f2e735eDd9dCD8Ccd41EcFE9894E679e3195f"), symbol: "rETH", name: "Rocket Pool ETH", decimals: 18, logoURL: logo("rETH")),
    ]

    public static let mon = core[0]
    public static let wmon = core[1]
    public static let usdc = core[2]
    public static let ausd = core.first { $0.address == Monad.ausd }!
    public static let abil = core.first { $0.symbol == "aBIL" }!

    /// ERC-20s the launchpad offers as pair (quote) tokens once the owner approves them with `setPairEconomics`.
    /// Native MON (address(0)) is always offered by the factory, so it is not listed here. Order is the UI's
    /// default order after MON: a familiar USD curve, the stable that doubles as Perpl collateral, then the RWA pair.
    public static let launchpadPairAssets: [Address] = [Monad.usdc, Monad.ausd, abil.address]

    /// Intermediate tokens tried for two-hop routes on the concentrated-liquidity venues.
    public static let hopTokens: [Address] = [Monad.wmon, Monad.usdc, Monad.usdt0, Monad.weth]

    public static func core(_ address: Address) -> Token? { core.first { $0.address == address } }

    /// The tokens the app vouches for by address: the curated spot assets (`core`) and the curated xStocks
    /// (`XStocks.curated`). A look-alike of any of them is flagged (`WalletHoldings.imitated(by:)`), none shows a warning
    /// badge (`TokenBadge`), a create form refuses a name or symbol that reads as one (`SymbolSafety.createRefusal`), and
    /// none can be a launchpad coin (`SwapEngine.mayBeLaunchCoin`). The xStocks are not in `core`: they are no spot asset
    /// the wallet reads, prices from pools or offers in Swap's main list.
    public static let curatedReference: [Token] = core + XStocks.curated

    public static func curatedReference(_ address: Address) -> Token? { curatedReference.first { $0.address == address } }
}
