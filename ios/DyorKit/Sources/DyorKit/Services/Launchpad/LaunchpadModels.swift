import BigInt
import Foundation

/// Where the launchpad lives on chain. `monadMainnet` is the audited deployment the app ships with; a build can
/// point at another one (a fork rehearsal) through Secrets.xcconfig. Any address may be `Address.zero`, and
/// `isDeployed` is what every read checks first.
public struct LaunchpadAddresses: Sendable, Hashable {
    public var factory: Address
    public var router: Address
    public var escrow: Address
    public var holderFeeSharing: Address
    public var hook: Address
    /// Uniswap v4 PoolManager (`Uniswap.poolManager` on Monad). Graduated launches are priced from its storage.
    public var poolManager: Address

    public init(factory: Address = .zero, router: Address = .zero, escrow: Address = .zero, holderFeeSharing: Address = .zero, hook: Address = .zero, poolManager: Address = .zero) {
        self.factory = factory
        self.router = router
        self.escrow = escrow
        self.holderFeeSharing = holderFeeSharing
        self.hook = hook
        self.poolManager = poolManager
    }

    public var isDeployed: Bool { !factory.isZero }

    public static let none = LaunchpadAddresses()

    /// The launchpad on Monad mainnet (chain 143): the 2026-09-16 redeploy carrying every 2026-09-15 audit fix
    /// (the pre-audit factory 0x2F02… is retired). Mirrors `contracts/deployments/143.json`, and
    /// `LaunchpadDeploymentTests` fails whenever the two drift apart.
    public static let monadMainnet = LaunchpadAddresses(
        factory: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
        router: Address(literal: "0x3eE688C3b3aCd652914aD49d8Ee5ae1004bF3690"),
        escrow: Address(literal: "0xbc70ba9D66F761FFb7647D6B52C8Cf65a49E47fc"),
        holderFeeSharing: Address(literal: "0x70F8f64c6A4A76A507e322BCef19E6E37abe4eF6"),
        hook: Address(literal: "0x51A240c13164BcDF3FC11053FddEaC626A4160cc"),
        poolManager: Uniswap.poolManager
    )
}

/// `Types.Phase` in the contracts: NotGraduated, Swept, PoolCreated, Rescued.
public enum LaunchPhase: Int, Sendable, Hashable, CaseIterable {
    case bonding = 0
    case migrating
    case graduated
    case refund

    public var title: String {
        switch self {
        case .bonding: return "Bonding"
        case .migrating: return "Migrating"
        case .graduated: return "Graduated"
        case .refund: return "Refund mode"
        }
    }

    init(raw: BigUInt) { self = LaunchPhase(rawValue: Int(clamping: raw)) ?? .bonding }
}

/// `Types.GraduationVenue` in the contracts: where a completed curve graduates. The creator chooses at launch;
/// aBIL-quoted (and any `pairMondayOnly`) launches are forced to Monday. UniswapV4 is the default (enum value 0).
public enum GraduationVenue: UInt8, Sendable, Hashable, CaseIterable {
    case uniswapV4 = 0
    case monday = 1

    public var title: String {
        switch self {
        case .uniswapV4: return "Uniswap v4"
        case .monday: return "Monday Trade"
        }
    }

    init(raw: BigUInt) { self = GraduationVenue(rawValue: UInt8(clamping: raw)) ?? .uniswapV4 }
}

public struct Socials: Hashable, Sendable {
    public var twitter: String
    public var telegram: String
    public var discord: String
    public var website: String
    public var farcaster: String

    public init(twitter: String = "", telegram: String = "", discord: String = "", website: String = "", farcaster: String = "") {
        self.twitter = twitter
        self.telegram = telegram
        self.discord = discord
        self.website = website
        self.farcaster = farcaster
    }

    public static let none = Socials()
}

/// The asset a curve collects. Native MON is `Address.zero`.
public struct PairInfo: Hashable, Sendable {
    public let address: Address
    public let symbol: String
    public let decimals: Int
    public let isNative: Bool

    public init(address: Address, symbol: String, decimals: Int, isNative: Bool) {
        self.address = address
        self.symbol = symbol
        self.decimals = decimals
        self.isNative = isNative
    }

    public static let mon = PairInfo(address: .zero, symbol: Monad.nativeSymbol, decimals: 18, isNative: true)
}

public struct PairEconomics: Hashable, Sendable {
    public let pair: PairInfo
    public let phantomQuote: BigUInt
    public let graduationThreshold: BigUInt
    public let approved: Bool
    /// The pair can only graduate on Monday Trade (the factory's `pairMondayOnly`); the create screen then forces
    /// the Monday venue and disables the picker. aBIL is the canonical Monday-only quote asset.
    public let mondayOnly: Bool

    public init(pair: PairInfo, phantomQuote: BigUInt, graduationThreshold: BigUInt, approved: Bool, mondayOnly: Bool = false) {
        self.pair = pair
        self.phantomQuote = phantomQuote
        self.graduationThreshold = graduationThreshold
        self.approved = approved
        self.mondayOnly = mondayOnly
    }
}

/// Factory policy and the launch template the create screen offers (config 0).
public struct ProtocolInfo: Hashable, Sendable {
    public let launchFee: BigUInt
    public let configId: BigUInt
    public let supply: BigUInt
    public let curveFeeBps: Int
    public let poolFeeBps: Int
    public let snipeSchedule: [Int]
    public let configEnabled: Bool
    public let maxCreatorTaxBps: Int
    public let whitelistEnabled: Bool
    public let protocolFeeShareBps: Int
    public let launchCount: Int
    public let pairs: [PairEconomics]

    public init(launchFee: BigUInt, configId: BigUInt, supply: BigUInt, curveFeeBps: Int, poolFeeBps: Int, snipeSchedule: [Int], configEnabled: Bool, maxCreatorTaxBps: Int, whitelistEnabled: Bool, protocolFeeShareBps: Int, launchCount: Int, pairs: [PairEconomics]) {
        self.launchFee = launchFee
        self.configId = configId
        self.supply = supply
        self.curveFeeBps = curveFeeBps
        self.poolFeeBps = poolFeeBps
        self.snipeSchedule = snipeSchedule
        self.configEnabled = configEnabled
        self.maxCreatorTaxBps = maxCreatorTaxBps
        self.whitelistEnabled = whitelistEnabled
        self.protocolFeeShareBps = protocolFeeShareBps
        self.launchCount = launchCount
        self.pairs = pairs
    }

    /// The snipe-tax window in seconds: one schedule entry per second after launch.
    public var snipeWindowSeconds: Int { snipeSchedule.count }
}

/// One launch as the explore list shows it: the factory record plus the token metadata and live curve state.
public struct Launch: Identifiable, Hashable, Sendable {
    public var id: Address { token }

    public let token: Address
    public let curve: Address
    public let deployer: Address
    public let creatorFeeRecipient: Address
    public let pairToken: Address
    public let graduationThreshold: BigUInt
    public let creatorTaxBps: Int
    public let poolFeeBps: Int
    public let tickSpacing: Int
    public let holderFeeSharing: Bool
    public let graduationVenue: GraduationVenue
    public let phase: LaunchPhase
    public let sweptQuote: BigUInt
    public let sweptTokens: BigUInt
    public let sweptAt: Int
    public let poolId: Data
    public let name: String
    public let symbol: String
    public let logo: String
    public let description: String
    public let socials: Socials
    public let pair: PairInfo
    /// Quote per whole token in quote wei (18-decimal fixed point), from the curve or, once graduated, the pool.
    public let price: BigUInt
    /// Quote collected by the curve; after graduation, what was swept into the pool.
    public let realQuoteReserve: BigUInt
    public let completed: Bool
    public let rescued: Bool
    public let launchedAt: Int
    public let supply: BigUInt
    public let marketCap: BigUInt
    public let progressBps: Int

    public init(token: Address, curve: Address, deployer: Address, creatorFeeRecipient: Address, pairToken: Address, graduationThreshold: BigUInt, creatorTaxBps: Int, poolFeeBps: Int, tickSpacing: Int, holderFeeSharing: Bool, graduationVenue: GraduationVenue, phase: LaunchPhase, sweptQuote: BigUInt, sweptTokens: BigUInt, sweptAt: Int, poolId: Data, name: String, symbol: String, logo: String, description: String, socials: Socials, pair: PairInfo, price: BigUInt, realQuoteReserve: BigUInt, completed: Bool, rescued: Bool, launchedAt: Int, supply: BigUInt, marketCap: BigUInt, progressBps: Int) {
        self.token = token
        self.curve = curve
        self.deployer = deployer
        self.creatorFeeRecipient = creatorFeeRecipient
        self.pairToken = pairToken
        self.graduationThreshold = graduationThreshold
        self.creatorTaxBps = creatorTaxBps
        self.poolFeeBps = poolFeeBps
        self.tickSpacing = tickSpacing
        self.holderFeeSharing = holderFeeSharing
        self.graduationVenue = graduationVenue
        self.phase = phase
        self.sweptQuote = sweptQuote
        self.sweptTokens = sweptTokens
        self.sweptAt = sweptAt
        self.poolId = poolId
        self.name = name
        self.symbol = symbol
        self.logo = logo
        self.description = description
        self.socials = socials
        self.pair = pair
        self.price = price
        self.realQuoteReserve = realQuoteReserve
        self.completed = completed
        self.rescued = rescued
        self.launchedAt = launchedAt
        self.supply = supply
        self.marketCap = marketCap
        self.progressBps = progressBps
    }

    /// Quote raised towards graduation, capped at the threshold (what the token page shows as "Raised").
    public var raised: BigUInt { realQuoteReserve > graduationThreshold ? graduationThreshold : realQuoteReserve }

    /// Buys and sells are open on the curve.
    public var isTrading: Bool { phase == .bonding && !completed && !rescued }

    /// Sells are open in refund mode (fee-free, at the curve price).
    public var isRefunding: Bool { phase == .refund || rescued }
}

/// Everything the token page needs beyond the list row.
public struct LaunchDetail: Identifiable, Hashable, Sendable {
    public var id: Address { launch.token }

    public let launch: Launch
    public let feeBps: Int
    public let snipeSchedule: [Int]
    public let quoteReserve: BigUInt
    public let tokenReserve: BigUInt
    public let sellableTokens: BigUInt
    public let phantomQuote: BigUInt
    public let reservedTokens: BigUInt
    public let swept: Bool
    public let stuckSince: Int
    public let poolKey: PoolKey?
    public let hookPendingFees: BigUInt
    public let hookPendingTax: BigUInt
    /// Holder rewards the sharing contract has received but not yet distributed: since the audit fix for flash
    /// reward-sniping, a reward is released to the balances standing at the first touch of a LATER block.
    public let queuedRewards: BigUInt

    public init(launch: Launch, feeBps: Int, snipeSchedule: [Int], quoteReserve: BigUInt, tokenReserve: BigUInt, sellableTokens: BigUInt, phantomQuote: BigUInt, reservedTokens: BigUInt, swept: Bool, stuckSince: Int, poolKey: PoolKey?, hookPendingFees: BigUInt, hookPendingTax: BigUInt, queuedRewards: BigUInt = 0) {
        self.launch = launch
        self.feeBps = feeBps
        self.snipeSchedule = snipeSchedule
        self.quoteReserve = quoteReserve
        self.tokenReserve = tokenReserve
        self.sellableTokens = sellableTokens
        self.phantomQuote = phantomQuote
        self.reservedTokens = reservedTokens
        self.swept = swept
        self.stuckSince = stuckSince
        self.poolKey = poolKey
        self.hookPendingFees = hookPendingFees
        self.hookPendingTax = hookPendingTax
        self.queuedRewards = queuedRewards
    }

    /// Seconds of snipe tax left at `now`, clamped to the schedule so a chain clock ahead of the device never
    /// shows a longer window.
    public func snipeWindowLeft(at now: Int) -> Int {
        min(snipeSchedule.count, max(0, launch.launchedAt + snipeSchedule.count - now))
    }

    /// The snipe tax a non-exempt buyer would pay at `now`, from the schedule alone.
    public func snipeTaxBps(at now: Int) -> Int {
        guard snipeWindowLeft(at: now) > 0, !snipeSchedule.isEmpty else { return 0 }
        let index = max(0, min(snipeSchedule.count - 1, now - launch.launchedAt))
        return snipeSchedule[index]
    }
}

/// A wallet's claimable fee-escrow balances, by pair asset. `native` is MON; `tokens` maps each ERC-20 pair asset
/// (USDC, AUSD, …) to its claimable amount. This is a creator's withdrawable fees, aggregated across their launches.
public struct EscrowBalances: Hashable, Sendable {
    public let native: BigUInt
    public let tokens: [Address: BigUInt]

    public init(native: BigUInt, tokens: [Address: BigUInt]) {
        self.native = native
        self.tokens = tokens
    }

    /// The pair tokens (excluding native) that currently hold a claimable balance.
    public var claimableTokens: [Address] { tokens.filter { $0.value > 0 }.map(\.key) }
    public var hasNative: Bool { native > 0 }
    public var isEmpty: Bool { native == 0 && tokens.values.allSatisfy { $0 == 0 } }
}

/// What one wallet holds and can claim for a launch.
public struct LaunchAccountView: Hashable, Sendable {
    public let tokenBalance: BigUInt
    public let pairBalance: BigUInt
    /// Pair-token allowance granted to the curve (always 0 for a native pair).
    public let allowance: BigUInt
    public let snipeTaxBps: Int
    public let pendingRewards: BigUInt
    public let escrowBalance: BigUInt

    public init(tokenBalance: BigUInt, pairBalance: BigUInt, allowance: BigUInt, snipeTaxBps: Int, pendingRewards: BigUInt, escrowBalance: BigUInt) {
        self.tokenBalance = tokenBalance
        self.pairBalance = pairBalance
        self.allowance = allowance
        self.snipeTaxBps = snipeTaxBps
        self.pendingRewards = pendingRewards
        self.escrowBalance = escrowBalance
    }
}

/// `BondingCurve.quoteBuy`: `used == tokens' net cost + fee + tax + snipe`, and `refund` is what a completing buy
/// hands back.
public struct BuyQuote: Hashable, Sendable {
    public let tokensOut: BigUInt
    public let used: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt
    public let snipe: BigUInt
    public let refund: BigUInt

    public init(tokensOut: BigUInt, used: BigUInt, fee: BigUInt, tax: BigUInt, snipe: BigUInt, refund: BigUInt) {
        self.tokensOut = tokensOut
        self.used = used
        self.fee = fee
        self.tax = tax
        self.snipe = snipe
        self.refund = refund
    }

    /// `out × (10 000 − slippageBps) / 10 000`, the `minTokensOut` the trade panel sends.
    public func minimumOut(slippageBps: Int) -> BigUInt { LaunchpadMath.minimumOut(tokensOut, slippageBps: slippageBps) }
}

public struct SellQuote: Hashable, Sendable {
    public let quoteOut: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt

    public init(quoteOut: BigUInt, fee: BigUInt, tax: BigUInt) {
        self.quoteOut = quoteOut
        self.fee = fee
        self.tax = tax
    }

    public func minimumOut(slippageBps: Int) -> BigUInt { LaunchpadMath.minimumOut(quoteOut, slippageBps: slippageBps) }
}

/// One curve fill from a `CurveBuy` / `CurveSell` event. `quoteAmount` is the quote that moved the reserves
/// (buys: input net of fees; sells: gross before fees) so `price` is the curve price the fill happened at.
public struct CurveTrade: Identifiable, Hashable, Sendable {
    /// `txHash-logIndex`.
    public let id: String
    public let block: UInt64
    public let logIndex: Int
    /// Unix seconds, estimated from the latest block and Monad's 0.4 s block time.
    public let time: Int
    public let trader: Address
    public let isBuy: Bool
    public let quoteAmount: BigUInt
    public let tokenAmount: BigUInt
    /// Decimals of the quote asset, so volumes can be expressed in pair units.
    public let quoteDecimals: Int
    /// Pair units per whole token (the same scale as `LaunchpadService.priceNumber`).
    public let price: Double

    public init(id: String, block: UInt64, logIndex: Int, time: Int, trader: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt, quoteDecimals: Int, price: Double) {
        self.id = id
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.trader = trader
        self.isBuy = isBuy
        self.quoteAmount = quoteAmount
        self.tokenAmount = tokenAmount
        self.quoteDecimals = quoteDecimals
        self.price = price
    }

    public var transactionHash: Data? { Data(hex: String(id.prefix(66))) }
}

/// OHLC bucket for the lightweight chart. `volume` is quote traded, in pair units.
public struct Candle: Hashable, Sendable, Identifiable {
    public var id: Int { time }
    public let time: Int
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double

    public init(time: Int, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

/// What the create screen submits. Mirrors the web app's `LaunchInput`: `expectedEconomics` must be the bytes
/// `previewLaunchEconomics(configId, pairToken)` returns at submit time, which is how the contract guarantees
/// the owner cannot change the terms between the user reading them and the transaction landing.
public struct LaunchInput: Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var description: String
    public var logo: String
    public var socials: Socials
    /// Receives creator fees and any creator tax; `Address.zero` lets the contract default to the deployer.
    public var creatorFeeRecipient: Address
    public var creatorTaxBps: Int
    public var holderFeeSharing: Bool
    /// Where the curve graduates. Defaults to Uniswap v4; the create screen forces `.monday` for `pairMondayOnly`
    /// (aBIL) pairs, which the factory also enforces (`PairRequiresMonday`).
    public var graduationVenue: GraduationVenue
    public var pairToken: Address
    public var configId: BigUInt
    /// Snipe-tax exemptions (at most `LaunchpadService.maxExemptions`); the deployer and creator wallet are always exempt.
    public var exemptions: [Address]
    /// Developer buy in pair units, made in the same transaction through the router; 0 launches without one.
    public var initialBuy: BigUInt
    /// Slippage floor for the developer buy.
    public var minTokensOut: BigUInt
    /// 32 bytes from `LaunchpadService.previewLaunchEconomics`.
    public var expectedEconomics: Data
    /// 32 random bytes; the token and curve addresses derive from `keccak(deployer, salt)`.
    public var salt: Data

    public init(name: String, symbol: String, description: String = "", logo: String = "", socials: Socials = .none, creatorFeeRecipient: Address = .zero, creatorTaxBps: Int = 0, holderFeeSharing: Bool = true, graduationVenue: GraduationVenue = .uniswapV4, pairToken: Address = .zero, configId: BigUInt = 0, exemptions: [Address] = [], initialBuy: BigUInt = 0, minTokensOut: BigUInt = 0, expectedEconomics: Data = Data(repeating: 0, count: 32), salt: Data = LaunchInput.randomSalt()) {
        self.name = name
        self.symbol = symbol
        self.description = description
        self.logo = logo
        self.socials = socials
        self.creatorFeeRecipient = creatorFeeRecipient
        self.creatorTaxBps = creatorTaxBps
        self.holderFeeSharing = holderFeeSharing
        self.graduationVenue = graduationVenue
        self.pairToken = pairToken
        self.configId = configId
        self.exemptions = exemptions
        self.initialBuy = initialBuy
        self.minTokensOut = minTokensOut
        self.expectedEconomics = expectedEconomics
        self.salt = salt
    }

    public var pairIsNative: Bool { pairToken.isZero }

    public static func randomSalt() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// One row of the launchpad activity feed.
public struct ActivityItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case launch(token: Address, curve: Address, deployer: Address)
        /// `quoteAmount` is the buyer's gross input or the seller's net output, as the feed shows amounts.
        case trade(token: Address, curve: Address, trader: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt)
        case graduated(token: Address, poolId: Data)
    }

    /// `txHash-logIndex`.
    public let id: String
    public let block: UInt64
    public let logIndex: Int
    public let time: Int
    public let transactionHash: Data
    public let kind: Kind

    public init(id: String, block: UInt64, logIndex: Int, time: Int, transactionHash: Data, kind: Kind) {
        self.id = id
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.transactionHash = transactionHash
        self.kind = kind
    }

    public var token: Address {
        switch kind {
        case .launch(let token, _, _), .graduated(let token, _), .trade(let token, _, _, _, _, _): return token
        }
    }

    /// The wallet the row is about: the deployer of a launch or the trader of a trade.
    public var actor: Address? {
        switch kind {
        case .launch(_, _, let deployer): return deployer
        case .trade(_, _, let trader, _, _, _): return trader
        case .graduated: return nil
        }
    }
}

public enum LaunchpadError: Error, LocalizedError, Equatable {
    case notDeployed
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notDeployed: return "The launchpad contracts are not deployed yet."
        case .unexpectedResponse(let what): return "The launchpad returned something the app could not read (\(what))."
        }
    }
}

/// Pure arithmetic shared by the screens and the service.
public enum LaunchpadMath {
    public static let bps: BigUInt = 10_000

    public static func minimumOut(_ amount: BigUInt, slippageBps: Int) -> BigUInt {
        let keep = BigUInt(max(0, min(10_000, 10_000 - slippageBps)))
        return amount * keep / bps
    }

    public static func feeOf(_ amount: BigUInt, bps taxBps: Int) -> BigUInt {
        amount * BigUInt(max(0, taxBps)) / bps
    }

    /// Gross amount whose net after `totalBps` of fees is at least `net`, rounded up (`CurveMath.grossForNet`).
    public static func grossForNet(_ net: BigUInt, totalBps: Int) -> BigUInt {
        let keep = BigUInt(max(1, 10_000 - totalBps))
        return (net * bps + keep - 1) / keep
    }

    /// Mirrors `BondingCurve.quoteBuy` for the deployer (snipe-tax exempt) before the curve exists, which is what
    /// the create screen shows next to the developer buy.
    public static func estimateDevBuy(amount: BigUInt, pair: PairEconomics, protocol info: ProtocolInfo, creatorTaxBps: Int) -> (tokens: BigUInt, used: BigUInt, refund: BigUInt, sharePercent: Double) {
        let totalBps = info.curveFeeBps + creatorTaxBps
        func netOf(_ gross: BigUInt) -> BigUInt {
            let fees = feeOf(gross, bps: info.curveFeeBps) + feeOf(gross, bps: creatorTaxBps)
            return fees > gross ? 0 : gross - fees
        }
        var used = amount
        var net = netOf(used)
        if net > pair.graduationThreshold {
            used = grossForNet(pair.graduationThreshold, totalBps: totalBps)
            net = netOf(used)
        }
        let denominator = pair.phantomQuote + net
        let tokens = denominator == 0 ? 0 : net * info.supply / denominator
        let share = info.supply == 0 ? 0 : Double(tokens * bps / info.supply) / 100
        return (tokens, used, amount > used ? amount - used : 0, share)
    }
}
