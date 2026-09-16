import BigInt
import Foundation

/* Moments: a per-moment NFT edition whose collects fund a coin that graduates into a locked Uniswap v4 pool.
   The clean-room contract set lives in `contracts/src/moments`; these models are the app-facing shape of what
   the contracts expose, ported from the web app's `app/lib/moments/reads.ts` so both clients agree to the wei. */

/// Where the Moments contracts live. The v1.1 set is live on Monad mainnet; `isDeployed` is what every read checks.
public struct MomentsAddresses: Sendable, Hashable {
    public var factory: Address
    public var collect: Address
    public var vesting: Address
    public var graduation: Address
    public var locker: Address
    public var hook: Address
    public var buyback: Address
    public var usdc: Address
    public var permit2: Address
    public var poolManager: Address
    public var platform: Address
    public var treasury: Address
    /// Block the factory was deployed in: no Moment coin has a Transfer before it, so history scans start here.
    public var deployBlock: UInt64

    public init(factory: Address = .zero, collect: Address = .zero, vesting: Address = .zero, graduation: Address = .zero, locker: Address = .zero,
                hook: Address = .zero, buyback: Address = .zero, usdc: Address = Monad.usdc, permit2: Address = Uniswap.permit2,
                poolManager: Address = Uniswap.poolManager, platform: Address = .zero, treasury: Address = .zero, deployBlock: UInt64 = 0) {
        self.factory = factory
        self.collect = collect
        self.vesting = vesting
        self.graduation = graduation
        self.locker = locker
        self.hook = hook
        self.buyback = buyback
        self.usdc = usdc
        self.permit2 = permit2
        self.poolManager = poolManager
        self.platform = platform
        self.treasury = treasury
        self.deployBlock = deployBlock
    }

    public var isDeployed: Bool { !factory.isZero && !collect.isZero && !vesting.isZero && !graduation.isZero }

    public static let none = MomentsAddresses()

    /// Moments v1.1 on Monad mainnet (chain 143) — `contracts/deployments/moments-143.json`, deployed and
    /// Sourcify-verified on 2026-09-16. Governance is the DyorHQ owner wallet; platform and treasury are the
    /// beneficiaries snapshotted into every Moment at publish.
    public static let monadMainnet = MomentsAddresses(
        factory: Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020"),
        collect: Address(literal: "0xb4EE9e67d9e1772BC6949748e3755EA7C1DFE32c"),
        vesting: Address(literal: "0x360E2068eAEc5b5A9AF60A7c4059Bd4b30B7209C"),
        graduation: Address(literal: "0x307De00950F039969855eFb859A6088d695e76b1"),
        locker: Address(literal: "0x832851A42Bf1FD1aF7a19c82cF132290c605E406"),
        hook: Address(literal: "0x8Aa322471Bef2996D3B50cB12F63C6A0054460Cc"),
        buyback: Address(literal: "0x03282D5421a3bE3ff79c5962819c9a6e5E0b52d2"),
        usdc: Address(literal: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"),
        permit2: Address(literal: "0x000000000022D473030F116dDEE9F6B43aC78BA3"),
        poolManager: Address(literal: "0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e"),
        platform: Address(literal: "0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48"),
        treasury: Address(literal: "0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045"),
        deployBlock: 105_347_754
    )

    /// Protocol addresses that hold Moment coins without being "holders" (the pool, the locker, vesting, …).
    public var protocolHolders: Set<Address> { [poolManager, locker, vesting, buyback, hook, graduation] }
}

/// `MomentTypes` constants, the same numbers the contracts hard-code.
public enum MomentsConstants {
    public static let bps = 10_000
    /// Fixed coin supply per Moment: 100,000,000 coins at 18 decimals.
    public static let supply = BigUInt(100_000_000) * BigUInt(10).power(18)
    public static let coinDecimals = 18
    public static let usdcDecimals = 6
    /// A vesting "month" is a fixed 30-day cliff.
    public static let monthSeconds = 30 * 86_400
    /// A completed Moment whose graduation keeps failing can be wound down this long after the first failure.
    public static let stuckGraceSeconds = 7 * 86_400
    /// Upper bound on editions per collect.
    public static let maxBatch = 20
    public static let minCollectWindowSeconds = 3_600
    public static let maxCollectWindowSeconds = 30 * 86_400
    /// Hard cap on the creator's coin allocation, whatever the policy says.
    public static let maxCreatorAllocBps = 1_000
    /// The hook's Moments fee on every pool trade (1% of the USDC side) and how it is split.
    public static let hookFeeBps = 100
    public static let hookCreatorShareBps = 2_000
    public static let hookPlatformShareBps = 3_000
    public static let hookBuybackShareBps = 5_000
    /// The pool's LP fee in hundredths of a bip (0.5%); it accrues to the locked full-range position.
    public static let lpFee = 5_000
    public static let tickSpacing = 60
    /// Total trading fee a swapper pays on a Moment pool: LP 0.5% + hook 1%.
    public static let totalTradeFeeBps = 150
}

/// `MomentTypes.State`.
public enum MomentState: Int, Sendable, Hashable, CaseIterable {
    case collecting = 0
    case graduationPending
    case graduated
    case expired

    public var title: String {
        switch self {
        case .collecting: return "Collecting"
        case .graduationPending: return "Graduation pending"
        case .graduated: return "Graduated"
        case .expired: return "Expired"
        }
    }

    init(raw: BigUInt) { self = MomentState(rawValue: Int(clamping: raw)) ?? .collecting }
}

/// The factory policy that applies to Moments published from now on (existing Moments keep their snapshot).
public struct MomentPolicy: Sendable, Hashable {
    public let threshold: BigUInt
    public let minPrice: BigUInt
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let maxCreatorAllocBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let platform: Address
    public let treasury: Address
    public let momentCount: Int
    public let publishingPaused: Bool
    public let externalBaseURI: String

    public init(threshold: BigUInt, minPrice: BigUInt, creatorBps: Int, platformBps: Int, reserveBps: Int, maxCreatorAllocBps: Int, expiryCreatorBps: Int, royaltyBps: Int, platform: Address, treasury: Address, momentCount: Int, publishingPaused: Bool, externalBaseURI: String) {
        self.threshold = threshold
        self.minPrice = minPrice
        self.creatorBps = creatorBps
        self.platformBps = platformBps
        self.reserveBps = reserveBps
        self.maxCreatorAllocBps = maxCreatorAllocBps
        self.expiryCreatorBps = expiryCreatorBps
        self.royaltyBps = royaltyBps
        self.platform = platform
        self.treasury = treasury
        self.momentCount = momentCount
        self.publishingPaused = publishingPaused
        self.externalBaseURI = externalBaseURI
    }
}

/// `MomentTypes.Provenance`: what the NFT records about the moment itself.
public struct MomentProvenance: Sendable, Hashable {
    public let mediaURI: String
    public let mediaHash: Data
    public let place: String
    /// Unix timestamp of the moment.
    public let date: Int
    public let animationURI: String

    public init(mediaURI: String, mediaHash: Data, place: String, date: Int, animationURI: String) {
        self.mediaURI = mediaURI
        self.mediaHash = mediaHash
        self.place = place
        self.date = date
        self.animationURI = animationURI
    }

    /// The media link as a URL the app can load: `ipfs://` is served through a public gateway.
    public var mediaURL: URL? { MomentsMath.url(mediaURI) }
    public var animationURL: URL? { MomentsMath.url(animationURI) }
}

/// `MomentTypes.Moment`: everything fixed at publish. There is no setter on chain.
public struct Moment: Sendable, Hashable, Identifiable {
    public let id: BigUInt
    public let creator: Address
    public let platform: Address
    public let treasury: Address
    public let coin: Address
    public let nft: Address
    /// Collect price in USDC units (6 dp).
    public let price: BigUInt
    /// Reserve that graduates the Moment, in USDC units.
    public let threshold: BigUInt
    /// entitlement = floor(gross · rateNum / rateDen), in coin wei per USDC unit.
    public let rateNum: BigUInt
    public let rateDen: BigUInt
    public let creatorBps: Int
    public let platformBps: Int
    public let reserveBps: Int
    public let creatorAllocBps: Int
    public let expiryCreatorBps: Int
    public let royaltyBps: Int
    public let publishedAt: Int
    /// Collecting is possible strictly before this timestamp.
    public let deadline: Int

    public init(id: BigUInt, creator: Address, platform: Address, treasury: Address, coin: Address, nft: Address, price: BigUInt, threshold: BigUInt, rateNum: BigUInt, rateDen: BigUInt, creatorBps: Int, platformBps: Int, reserveBps: Int, creatorAllocBps: Int, expiryCreatorBps: Int, royaltyBps: Int, publishedAt: Int, deadline: Int) {
        self.id = id
        self.creator = creator
        self.platform = platform
        self.treasury = treasury
        self.coin = coin
        self.nft = nft
        self.price = price
        self.threshold = threshold
        self.rateNum = rateNum
        self.rateDen = rateDen
        self.creatorBps = creatorBps
        self.platformBps = platformBps
        self.reserveBps = reserveBps
        self.creatorAllocBps = creatorAllocBps
        self.expiryCreatorBps = expiryCreatorBps
        self.royaltyBps = royaltyBps
        self.publishedAt = publishedAt
        self.deadline = deadline
    }

    /// The creator's coin allocation in wei (`SUPPLY · creatorAllocBps / BPS`).
    public var creatorAllocation: BigUInt { MomentsConstants.supply * BigUInt(creatorAllocBps) / BigUInt(MomentsConstants.bps) }
}

/// `MomentCollect.Ledger`: the live money state of a Moment.
public struct MomentLedger: Sendable, Hashable {
    public let state: MomentState
    public let completedAt: Int
    public let stuckSince: Int
    public let endedAt: Int
    public let reserve: BigUInt
    public let creatorClaimable: BigUInt
    public let platformClaimable: BigUInt
    public let treasuryClaimable: BigUInt
    public let totalGross: BigUInt
    public let collects: Int

    public init(state: MomentState, completedAt: Int, stuckSince: Int, endedAt: Int, reserve: BigUInt, creatorClaimable: BigUInt, platformClaimable: BigUInt, treasuryClaimable: BigUInt, totalGross: BigUInt, collects: Int) {
        self.state = state
        self.completedAt = completedAt
        self.stuckSince = stuckSince
        self.endedAt = endedAt
        self.reserve = reserve
        self.creatorClaimable = creatorClaimable
        self.platformClaimable = platformClaimable
        self.treasuryClaimable = treasuryClaimable
        self.totalGross = totalGross
        self.collects = collects
    }
}

/// A graduated Moment's pool: the locked v4 position, its live price and the hook fees waiting to be pulled.
public struct MomentPool: Sendable, Hashable {
    public let key: PoolKey
    public let poolId: Data
    public let usdcIs0: Bool
    public let sqrtPriceX96: BigUInt
    public let openingSqrtPriceX96: BigUInt
    public let liquidity: BigUInt
    public let seedLiquidity: BigUInt
    public let reserveSeed: BigUInt
    public let poolCoins: BigUInt
    public let graduatedAt: Int
    /// Whole USDC per whole coin at the live price.
    public let usdcPerCoin: Double
    public let creatorFees: BigUInt
    public let platformFees: BigUInt
    public let buybackFees: BigUInt
    public let buybackCarry: BigUInt
    public let lastBuyback: Int
    public let buybackInterval: Int
    public let buybackMin: BigUInt

    public init(key: PoolKey, poolId: Data, usdcIs0: Bool, sqrtPriceX96: BigUInt, openingSqrtPriceX96: BigUInt, liquidity: BigUInt, seedLiquidity: BigUInt, reserveSeed: BigUInt, poolCoins: BigUInt, graduatedAt: Int, usdcPerCoin: Double, creatorFees: BigUInt, platformFees: BigUInt, buybackFees: BigUInt, buybackCarry: BigUInt, lastBuyback: Int, buybackInterval: Int, buybackMin: BigUInt) {
        self.key = key
        self.poolId = poolId
        self.usdcIs0 = usdcIs0
        self.sqrtPriceX96 = sqrtPriceX96
        self.openingSqrtPriceX96 = openingSqrtPriceX96
        self.liquidity = liquidity
        self.seedLiquidity = seedLiquidity
        self.reserveSeed = reserveSeed
        self.poolCoins = poolCoins
        self.graduatedAt = graduatedAt
        self.usdcPerCoin = usdcPerCoin
        self.creatorFees = creatorFees
        self.platformFees = platformFees
        self.buybackFees = buybackFees
        self.buybackCarry = buybackCarry
        self.lastBuyback = lastBuyback
        self.buybackInterval = buybackInterval
        self.buybackMin = buybackMin
    }

    /// Fully diluted value in USD at the live price (the whole 100M supply).
    public var fdvUSD: Double { usdcPerCoin * 1e8 }
    /// Price change since the pool opened, in percent.
    public var changeSinceOpen: Double? {
        let opening = MomentsMath.usdcPerCoin(sqrtPriceX96: openingSqrtPriceX96, usdcIs0: usdcIs0)
        guard opening > 0 else { return nil }
        return (usdcPerCoin / opening - 1) * 100
    }
    /// USDC the buyback can spend on its next round (accrued + carried), and whether a round can run now.
    public var buybackBudget: BigUInt { buybackFees + buybackCarry }
    public func buybackReady(at now: Int) -> Bool { buybackBudget >= buybackMin && now >= lastBuyback + buybackInterval }
}

/// A Moment as the board and the detail page show it.
public struct MomentInfo: Sendable, Hashable, Identifiable {
    public let moment: Moment
    public let name: String
    public let symbol: String
    public let provenance: MomentProvenance
    public let ledger: MomentLedger
    /// Editions minted so far (the NFT's `totalMinted`).
    public let editions: Int
    public let closed: Bool
    /// Σ coin entitlements promised to collectors.
    public let entitlements: BigUInt
    public let graduated: Bool
    /// Reserve progress toward the threshold, 10 000 = graduated.
    public let progressBps: Int
    public let pool: MomentPool?

    public var id: BigUInt { moment.id }
    public var state: MomentState { ledger.state }

    public init(moment: Moment, name: String, symbol: String, provenance: MomentProvenance, ledger: MomentLedger, editions: Int, closed: Bool, entitlements: BigUInt, graduated: Bool, progressBps: Int, pool: MomentPool?) {
        self.moment = moment
        self.name = name
        self.symbol = symbol
        self.provenance = provenance
        self.ledger = ledger
        self.editions = editions
        self.closed = closed
        self.entitlements = entitlements
        self.graduated = graduated
        self.progressBps = progressBps
        self.pool = pool
    }

    /// Whether a collect would be accepted right now (state and deadline), before the terminal clamp.
    public func isCollecting(at now: Int) -> Bool { ledger.state == .collecting && now < moment.deadline }
    /// Seconds until the collect window closes (0 once closed).
    public func secondsLeft(at now: Int) -> Int { max(0, moment.deadline - now) }
    /// Whether anyone may call `expire` now: collecting past the deadline, or stuck in graduation for the grace period.
    public func isExpirable(at now: Int) -> Bool {
        switch ledger.state {
        case .collecting: return now >= moment.deadline
        case .graduationPending: return now >= moment.deadline && ledger.stuckSince > 0 && now >= ledger.stuckSince + MomentsConstants.stuckGraceSeconds
        default: return false
        }
    }
    /// Whether a permissionless graduation retry makes sense.
    public var isRetriable: Bool { ledger.state == .graduationPending }
    /// USDC still needed in the reserve to graduate (0 once reached).
    public var reserveRemaining: BigUInt { ledger.reserve >= moment.threshold ? 0 : moment.threshold - ledger.reserve }
    /// How many more single-edition collects at the current price would fill the reserve (upper bound).
    public var collectsToGraduate: Int {
        guard reserveRemaining > 0, moment.price > 0, moment.reserveBps > 0 else { return 0 }
        let reservePerCollect = moment.price * BigUInt(moment.reserveBps) / BigUInt(MomentsConstants.bps)
        guard reservePerCollect > 0 else { return 0 }
        let n = (reserveRemaining + reservePerCollect - 1) / reservePerCollect
        return Int(clamping: n)
    }
    /// The coin as a swap-able token.
    public var coinToken: Token { Token(address: moment.coin, symbol: symbol, name: name, decimals: MomentsConstants.coinDecimals, logoURL: provenance.mediaURL) }
}

/// The detail page's extras: the supply identity and the coin's minted total.
public struct MomentDetail: Sendable, Hashable, Identifiable {
    public struct Supply: Sendable, Hashable {
        public let entitlements: BigUInt
        public let creatorAlloc: BigUInt
        public let remainderPool: BigUInt
        public let impliedPool: BigUInt
        public let collects: Int
        public init(entitlements: BigUInt, creatorAlloc: BigUInt, remainderPool: BigUInt, impliedPool: BigUInt, collects: Int) {
            self.entitlements = entitlements
            self.creatorAlloc = creatorAlloc
            self.remainderPool = remainderPool
            self.impliedPool = impliedPool
            self.collects = collects
        }
    }

    public let info: MomentInfo
    public let supply: Supply
    public let coinTotalSupply: BigUInt
    public let externalURL: String
    public var id: BigUInt { info.id }

    public init(info: MomentInfo, supply: Supply, coinTotalSupply: BigUInt, externalURL: String) {
        self.info = info
        self.supply = supply
        self.coinTotalSupply = coinTotalSupply
        self.externalURL = externalURL
    }
}

/// `MomentCollect.Quote`: exactly what a collect would settle.
public struct CollectQuote: Sendable, Hashable {
    /// USDC accepted (after the terminal clamp); this is all that is ever pulled.
    public let gross: BigUInt
    public let editions: BigUInt
    public let entitlement: BigUInt
    public let reserveIn: BigUInt
    public let creatorIn: BigUInt
    public let platformIn: BigUInt
    /// USDC of the request that is NOT pulled (terminal clamp only) — never a transfer.
    public let excess: BigUInt
    /// This collect completes the Moment and triggers graduation.
    public let terminal: Bool

    public init(gross: BigUInt, editions: BigUInt, entitlement: BigUInt, reserveIn: BigUInt, creatorIn: BigUInt, platformIn: BigUInt, excess: BigUInt, terminal: Bool) {
        self.gross = gross
        self.editions = editions
        self.entitlement = entitlement
        self.reserveIn = reserveIn
        self.creatorIn = creatorIn
        self.platformIn = platformIn
        self.excess = excess
        self.terminal = terminal
    }
}

/// Everything about one account's stake in one Moment.
public struct MomentAccountView: Sendable, Hashable {
    public let usdcBalance: BigUInt
    public let monBalance: BigUInt
    /// USDC → Permit2 allowance (the one-time approval behind signature collects).
    public let permit2Allowance: BigUInt
    /// USDC → collect contract allowance (the plain-approval path).
    public let collectAllowance: BigUInt
    public let entitlement: BigUInt
    public let claimed: BigUInt
    public let claimableCollector: BigUInt
    public let claimableCreator: BigUInt
    public let coinBalance: BigUInt
    public let nftBalance: Int
    public let nftIds: [BigUInt]
    /// Collect-time creator share still to pull (non-zero only for the creator).
    public let creatorProceeds: BigUInt
    /// Hook fees still to pull (non-zero only for the creator).
    public let creatorFees: BigUInt
    public let platformProceeds: BigUInt
    public let platformFees: BigUInt
    public let treasuryProceeds: BigUInt

    public init(usdcBalance: BigUInt, monBalance: BigUInt, permit2Allowance: BigUInt, collectAllowance: BigUInt, entitlement: BigUInt, claimed: BigUInt, claimableCollector: BigUInt, claimableCreator: BigUInt, coinBalance: BigUInt, nftBalance: Int, nftIds: [BigUInt], creatorProceeds: BigUInt, creatorFees: BigUInt, platformProceeds: BigUInt, platformFees: BigUInt, treasuryProceeds: BigUInt) {
        self.usdcBalance = usdcBalance
        self.monBalance = monBalance
        self.permit2Allowance = permit2Allowance
        self.collectAllowance = collectAllowance
        self.entitlement = entitlement
        self.claimed = claimed
        self.claimableCollector = claimableCollector
        self.claimableCreator = claimableCreator
        self.coinBalance = coinBalance
        self.nftBalance = nftBalance
        self.nftIds = nftIds
        self.creatorProceeds = creatorProceeds
        self.creatorFees = creatorFees
        self.platformProceeds = platformProceeds
        self.platformFees = platformFees
        self.treasuryProceeds = treasuryProceeds
    }

    public var claimable: BigUInt { claimableCollector + claimableCreator }
}

/// One Moment the account has a stake in.
public struct MomentPortfolioRow: Sendable, Hashable, Identifiable {
    public let moment: MomentInfo
    /// Everything this account will be able to claim in total: its collects plus, for the creator, the allocation.
    public let entitlement: BigUInt
    public let claimed: BigUInt
    public let claimableCollector: BigUInt
    public let claimableCreator: BigUInt
    public let nftBalance: Int
    public let coinBalance: BigUInt
    public let isCreator: Bool
    public var id: BigUInt { moment.id }
    public var claimable: BigUInt { claimableCollector + claimableCreator }
    /// Still locked behind the monthly cliffs (only meaningful once graduated).
    public var vesting: BigUInt {
        let out = claimed + claimable
        return entitlement > out ? entitlement - out : 0
    }

    public init(moment: MomentInfo, entitlement: BigUInt, claimed: BigUInt, claimableCollector: BigUInt, claimableCreator: BigUInt, nftBalance: Int, coinBalance: BigUInt, isCreator: Bool) {
        self.moment = moment
        self.entitlement = entitlement
        self.claimed = claimed
        self.claimableCollector = claimableCollector
        self.claimableCreator = claimableCreator
        self.nftBalance = nftBalance
        self.coinBalance = coinBalance
        self.isCreator = isCreator
    }
}

/// Every Moment the account has a stake in, with the coin totals: pending (not graduated), claimable now, still
/// vesting, claimed.
public struct MomentPortfolio: Sendable, Hashable {
    public let rows: [MomentPortfolioRow]
    public let pending: BigUInt
    public let claimable: BigUInt
    public let vesting: BigUInt
    public let claimed: BigUInt

    public init(rows: [MomentPortfolioRow], pending: BigUInt, claimable: BigUInt, vesting: BigUInt, claimed: BigUInt) {
        self.rows = rows
        self.pending = pending
        self.claimable = claimable
        self.vesting = vesting
        self.claimed = claimed
    }

    public static let empty = MomentPortfolio(rows: [], pending: 0, claimable: 0, vesting: 0, claimed: 0)
    /// Ids of graduated Moments with something claimable, for `claimAll`.
    public var claimableIds: [BigUInt] { rows.filter { $0.moment.graduated && $0.claimable > 0 }.map(\.id) }
}

/// What `publish` needs. Amounts are raw: `price` in USDC units, `collectWindow` in seconds.
public struct MomentPublishInput: Sendable, Hashable {
    public var name: String
    public var symbol: String
    public var mediaURI: String
    public var mediaHash: Data
    public var animationURI: String
    public var place: String
    public var date: Int
    public var price: BigUInt
    public var creatorAllocBps: Int
    public var collectWindow: Int

    public init(name: String, symbol: String, mediaURI: String, mediaHash: Data, animationURI: String = "", place: String, date: Int, price: BigUInt, creatorAllocBps: Int, collectWindow: Int) {
        self.name = name
        self.symbol = symbol
        self.mediaURI = mediaURI
        self.mediaHash = mediaHash
        self.animationURI = animationURI
        self.place = place
        self.date = date
        self.price = price
        self.creatorAllocBps = creatorAllocBps
        self.collectWindow = collectWindow
    }
}

/// The `Published` event of a publish transaction.
public struct MomentPublishResult: Sendable, Hashable {
    public let momentId: BigUInt
    public let creator: Address
    public let coin: Address
    public let nft: Address
    public init(momentId: BigUInt, creator: Address, coin: Address, nft: Address) {
        self.momentId = momentId
        self.creator = creator
        self.coin = coin
        self.nft = nft
    }
}

/// Holder statistics for a Moment coin, rebuilt from `Transfer` logs (there is no indexer). Protocol addresses
/// (the pool, the locker, vesting…) are reported apart from wallets.
public struct MomentHolderStats: Sendable, Hashable {
    /// Wallets with a non-zero balance (protocol addresses excluded).
    public let holders: Int
    public let topHolder: Address?
    /// Share of the circulating supply held by the largest wallet.
    public let topHolderBps: Int
    /// Whole coins outside the protocol addresses.
    public let circulatingCoins: Double
    /// Share of the minted supply sitting in the pool.
    public let poolBps: Int
    public let mintedCoins: Double
    public let scannedTo: UInt64

    public init(holders: Int, topHolder: Address?, topHolderBps: Int, circulatingCoins: Double, poolBps: Int, mintedCoins: Double, scannedTo: UInt64) {
        self.holders = holders
        self.topHolder = topHolder
        self.topHolderBps = topHolderBps
        self.circulatingCoins = circulatingCoins
        self.poolBps = poolBps
        self.mintedCoins = mintedCoins
        self.scannedTo = scannedTo
    }

    public static let empty = MomentHolderStats(holders: 0, topHolder: nil, topHolderBps: 0, circulatingCoins: 0, poolBps: 0, mintedCoins: 0, scannedTo: 0)
}

// MARK: - Account history (portfolio)

/// One collect the wallet made (`Collected`), with the exact USDC split the contract booked.
public struct MomentCollectRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let collector: Address
    public let gross: BigUInt
    public let editions: Int
    public let firstRank: Int
    public let entitlement: BigUInt
    public let reserveIn: BigUInt
    public let creatorIn: BigUInt
    public let platformIn: BigUInt
    public var id: String { "\(hash.hexString)-\(momentId)-\(firstRank)" }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, collector: Address, gross: BigUInt, editions: Int, firstRank: Int, entitlement: BigUInt, reserveIn: BigUInt, creatorIn: BigUInt, platformIn: BigUInt) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.collector = collector
        self.gross = gross
        self.editions = editions
        self.firstRank = firstRank
        self.entitlement = entitlement
        self.reserveIn = reserveIn
        self.creatorIn = creatorIn
        self.platformIn = platformIn
    }
}

/// A vesting claim the wallet made (`Claimed`): coins minted to it.
public struct MomentClaimRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let collectorAmount: BigUInt
    public let creatorAmount: BigUInt
    public var id: String { "\(hash.hexString)-\(momentId)-claim" }
    public var total: BigUInt { collectorAmount + creatorAmount }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, collectorAmount: BigUInt, creatorAmount: BigUInt) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.collectorAmount = collectorAmount
        self.creatorAmount = creatorAmount
    }
}

/// USDC the wallet pulled out: collect-time proceeds (`Withdrawn`) or pool fees (`FeesWithdrawn`).
public struct MomentWithdrawalRecord: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case proceeds, poolFees }
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let kind: Kind
    public let amount: BigUInt
    public var id: String { "\(hash.hexString)-\(momentId)-\(kind)" }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, kind: Kind, amount: BigUInt) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.kind = kind
        self.amount = amount
    }
}

/// A Moment the wallet published (`Published`).
public struct MomentPublishRecord: Sendable, Hashable, Identifiable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let momentId: BigUInt
    public let coin: Address
    public var id: String { "\(hash.hexString)-publish-\(momentId)" }

    public init(hash: Data, block: UInt64, time: Date, momentId: BigUInt, coin: Address) {
        self.hash = hash
        self.block = block
        self.time = time
        self.momentId = momentId
        self.coin = coin
    }
}

/// Everything a wallet did on Moments (collects, claims, withdrawals, publishes), for the portfolio.
public struct MomentsAccountHistory: Sendable, Hashable {
    public let collects: [MomentCollectRecord]
    public let claims: [MomentClaimRecord]
    public let withdrawals: [MomentWithdrawalRecord]
    public let publishes: [MomentPublishRecord]

    public init(collects: [MomentCollectRecord], claims: [MomentClaimRecord], withdrawals: [MomentWithdrawalRecord], publishes: [MomentPublishRecord]) {
        self.collects = collects
        self.claims = claims
        self.withdrawals = withdrawals
        self.publishes = publishes
    }

    public static let empty = MomentsAccountHistory(collects: [], claims: [], withdrawals: [], publishes: [])
}

// MARK: - Math

/// The derivations the contracts and the web app share; kept pure so they are unit-testable.
public enum MomentsMath {
    /// `MomentsFactory.bundleRate`: coin wei per USDC unit as an exact fraction.
    public static func bundleRate(threshold: BigUInt, reserveBps: Int, creatorAllocBps: Int) -> (num: BigUInt, den: BigUInt) {
        let bps = BigUInt(MomentsConstants.bps)
        let num = MomentsConstants.supply * (bps - BigUInt(creatorAllocBps)) * BigUInt(reserveBps)
        let den = bps * threshold * (bps + BigUInt(reserveBps))
        return (num, den)
    }

    /// Coin wei owed for `gross` USDC units at a Moment's rate (floor, like `Math.mulDiv`).
    public static func entitlement(gross: BigUInt, rateNum: BigUInt, rateDen: BigUInt) -> BigUInt {
        guard rateDen > 0 else { return 0 }
        return gross * rateNum / rateDen
    }

    /// Whole USDC per whole coin from a v4 sqrt price (USDC 6 dp, coin 18 dp).
    public static func usdcPerCoin(sqrtPriceX96: BigUInt, usdcIs0: Bool) -> Double {
        let sp = Double(sqrtPriceX96) / pow(2, 96)
        let ratio = sp * sp // currency1 units per currency0 unit
        guard ratio > 0 else { return 0 }
        return usdcIs0 ? 1e12 / ratio : ratio * 1e12
    }

    /// Vested share of a collector's entitlement, in bps: 6000 at graduation, 8000 after month 1, 10000 after month 2.
    public static func collectorVestedBps(graduatedAt: Int, now: Int) -> Int {
        guard graduatedAt > 0, now >= graduatedAt else { return 0 }
        let months = (now - graduatedAt) / MomentsConstants.monthSeconds
        if months == 0 { return 6_000 }
        if months == 1 { return 8_000 }
        return MomentsConstants.bps
    }

    /// Vested share of the creator allocation, in bps: 2000 at graduation, +1600 per month, 10000 at month 5.
    public static func creatorVestedBps(graduatedAt: Int, now: Int) -> Int {
        guard graduatedAt > 0, now >= graduatedAt else { return 0 }
        let months = min(5, (now - graduatedAt) / MomentsConstants.monthSeconds)
        return 2_000 + 1_600 * months
    }

    /// Progress toward graduation in bps (10 000 once graduated or pending).
    public static func progressBps(reserve: BigUInt, threshold: BigUInt, state: MomentState) -> Int {
        if state == .graduated || state == .graduationPending { return MomentsConstants.bps }
        guard threshold > 0 else { return 0 }
        return Int(clamping: reserve * BigUInt(MomentsConstants.bps) / threshold)
    }

    /// Whole coins as a display number.
    public static func coins(_ wei: BigUInt) -> Double { Amount.units(wei, decimals: MomentsConstants.coinDecimals) }
    /// Whole USDC as a display number.
    public static func usdc(_ units: BigUInt) -> Double { Amount.units(units, decimals: MomentsConstants.usdcDecimals) }

    /// A media link the app can load: `ipfs://` is rewritten to a public gateway; `https://` passes through.
    public static func url(_ uri: String) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("ipfs://") {
            let path = trimmed.dropFirst("ipfs://".count).replacingOccurrences(of: "ipfs/", with: "", options: [.anchored])
            return URL(string: "https://ipfs.io/ipfs/\(path)")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
