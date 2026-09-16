import BigInt
import Foundation

/// The launchpad's ABI surface: function signatures, call builders, return decoders and event parsers. Every
/// signature here is fixed at compile time, so encoding cannot fail for well-formed values; a failure is a
/// programming error and traps instead of surfacing as a network-style error.
enum LaunchpadABI {
    // MARK: Signatures

    static let tokenParams = "(string,string,string,string,(string,string,string,string,string),address,uint16,bool,uint8,bytes32,bytes32)"
    static let launchedTokenTuple = "(address,address,address,address,address,uint256,uint16,uint16,int24,bool,uint8,uint8,uint256,uint256,uint256,bytes32,bool)"
    static let launchConfigTuple = "(uint256,uint16,uint16,int24,uint16[],bool)"
    static let poolKeyTuple = "(address,address,uint24,int24,address)"
    static let socialsTuple = "(string,string,string,string,string)"

    enum Factory {
        static let launchFee = "launchFee()"
        static let launchConfigCount = "launchConfigCount()"
        static let maxCreatorTaxBps = "maxCreatorTaxBps()"
        static let whitelistEnabled = "whitelistEnabled()"
        static let getLaunchFeePolicy = "getLaunchFeePolicy()"
        static let launchCount = "launchCount()"
        static let getLaunchConfig = "getLaunchConfig(uint256)"
        static let pairTokenEconomics = "pairTokenEconomics(address)"
        static let pairMondayOnly = "pairMondayOnly(address)"
        static let getLaunches = "getLaunches(uint256,uint256)"
        static let getLaunchedToken = "getLaunchedToken(address)"
        static let stuckSince = "stuckSince(address)"
        static let poolKeyOf = "poolKeyOf(address)"
        static let previewLaunchEconomics = "previewLaunchEconomics(uint256,address)"
        static let canLaunch = "canLaunch(address)"
        static let launchToken = "launchToken(\(tokenParams),uint256,address,address[])"
        static let graduate = "graduate(address)"
    }

    enum Router {
        static let launchAndBuy = "launchAndBuy(\(tokenParams),uint256,address,uint256,uint256,address,address[])"
    }

    enum Curve {
        static let price = "price()"
        static let realQuoteReserve = "realQuoteReserve()"
        static let completed = "completed()"
        static let rescued = "rescued()"
        static let launchedAt = "launchedAt()"
        static let feeBps = "feeBps()"
        static let snipeTaxSchedule = "snipeTaxSchedule()"
        static let getReserves = "getReserves()"
        static let sellableTokens = "sellableTokens()"
        static let phantomQuote = "phantomQuote()"
        static let reservedTokens = "reservedTokens()"
        static let swept = "swept()"
        static let currentSnipeTaxBps = "currentSnipeTaxBps(address)"
        static let quoteBuy = "quoteBuy(uint256,address)"
        static let quoteSell = "quoteSell(uint256)"
        static let buy = "buy(uint256,uint256,address)"
        static let sell = "sell(uint256,uint256,address)"
    }

    enum Token {
        static let name = "name()"
        static let symbol = "symbol()"
        static let decimals = "decimals()"
        static let totalSupply = "totalSupply()"
        static let balanceOf = "balanceOf(address)"
        static let allowance = "allowance(address,address)"
        static let getTokenInfo = "getTokenInfo()"
    }

    enum Escrow {
        static let balanceOf = "balanceOf(address)"
        static let balanceOfToken = "balanceOfToken(address,address)"
        static let claim = "claim()"
        static let claimToken = "claimToken(address)"
    }

    enum Sharing {
        static let pendingRewards = "pendingRewards(address,address)"
        static let claim = "claim(address)"
    }

    enum Hook {
        static let pendingFees = "pendingFees(bytes32,address)"
        static let pendingCreatorTax = "pendingCreatorTax(bytes32,address)"
        static let sweepPoolFees = "sweepPoolFees(bytes32,address)"
    }

    enum PoolManager {
        static let extsload = "extsload(bytes32)"
        /// Uniswap v4 keeps `pools` in storage slot 6; slot0 (sqrtPriceX96 in the low 160 bits) sits at `keccak(poolId, 6)`.
        static let poolsSlot: BigUInt = 6
    }

    enum Multicall3 {
        static let getEthBalance = "getEthBalance(address)"
    }

    // MARK: Events

    enum Events {
        static let buy = "CurveBuy(address,address,uint256,uint256,uint256,uint256)"
        static let sell = "CurveSell(address,address,uint256,uint256,uint256,uint256)"
        static let launched = "TokenLaunched(address,address,address,address,uint256,uint256)"
        static let graduated = "PoolGraduated(address,bytes32,uint128)"

        static let buyTopic = ABI.eventTopic(buy)
        static let sellTopic = ABI.eventTopic(sell)
        static let launchedTopic = ABI.eventTopic(launched)
        static let graduatedTopic = ABI.eventTopic(graduated)
    }

    struct CurveFill {
        let trader: Address
        let recipient: Address
        /// Buys: `quoteIn` (gross), sells: `tokensIn`.
        let amountIn: BigUInt
        /// Buys: `tokensOut`, sells: `quoteOut` (net).
        let amountOut: BigUInt
        let fee: BigUInt
        let tax: BigUInt
    }

    struct LaunchedEvent {
        let token: Address
        let curve: Address
        let deployer: Address
        let pairToken: Address
        let launchConfigId: BigUInt
        let graduationThreshold: BigUInt
    }

    struct GraduatedEvent {
        let token: Address
        let poolId: Data
        let liquidity: BigUInt
    }

    /// Parses `CurveBuy` or `CurveSell`; both carry two indexed addresses and four `uint256` data words.
    static func fill(_ log: Log) -> CurveFill? {
        guard log.topics.count == 3, let trader = log.indexedAddress(0), let recipient = log.indexedAddress(1),
              let words = try? ABI.decode(log.data, "uint256,uint256,uint256,uint256"), words.count == 4
        else { return nil }
        return CurveFill(trader: trader, recipient: recipient, amountIn: words[0].uint, amountOut: words[1].uint, fee: words[2].uint, tax: words[3].uint)
    }

    static func launched(_ log: Log) -> LaunchedEvent? {
        guard log.topics.count == 4, let token = log.indexedAddress(0), let curve = log.indexedAddress(1), let deployer = log.indexedAddress(2),
              let words = try? ABI.decode(log.data, "address,uint256,uint256"), words.count == 3
        else { return nil }
        return LaunchedEvent(token: token, curve: curve, deployer: deployer, pairToken: words[0].address, launchConfigId: words[1].uint, graduationThreshold: words[2].uint)
    }

    static func graduated(_ log: Log) -> GraduatedEvent? {
        guard log.topics.count == 3, let token = log.indexedAddress(0), log.topics[2].count == 32,
              let words = try? ABI.decode(log.data, "uint128"), words.count == 1
        else { return nil }
        return GraduatedEvent(token: token, poolId: log.topics[2], liquidity: words[0].uint)
    }

    // MARK: Encoding

    static func calldata(_ signature: String, _ args: [ABIValue] = []) -> Data {
        do { return try ABI.encodeCall(signature, args) } catch { preconditionFailure("Launchpad calldata for \(signature) failed to encode: \(error)") }
    }

    static func call(_ to: Address, _ signature: String, _ args: [ABIValue] = [], returns: String) -> ContractCall {
        do { return try ContractCall(to: to, signature, args, returns: returns) } catch { preconditionFailure("Launchpad call \(signature) failed to encode: \(error)") }
    }

    static func types(_ list: String) -> [ABIType] {
        do { return try ABIType.parseList(list) } catch { preconditionFailure("Invalid launchpad return types \(list): \(error)") }
    }

    /// `Types.TokenParams` as the factory and router take it.
    static func tokenParams(_ input: LaunchInput) -> ABIValue {
        .tuple([
            .string(input.name), .string(input.symbol), .string(input.logo), .string(input.description),
            .tuple([.string(input.socials.twitter), .string(input.socials.telegram), .string(input.socials.discord), .string(input.socials.website), .string(input.socials.farcaster)]),
            .address(input.creatorFeeRecipient), .uint(BigUInt(max(0, input.creatorTaxBps))), .bool(input.holderFeeSharing),
            .uint(BigUInt(input.graduationVenue.rawValue)),
            .bytes(word(input.expectedEconomics)), .bytes(word(input.salt)),
        ])
    }

    /// Coerces caller-supplied bytes to one 32-byte word (left-padded when short, truncated when long) so a
    /// stale or empty value produces an on-chain `LaunchEconomicsMismatch` revert rather than a client trap.
    static func word(_ data: Data) -> Data {
        data.count == 32 ? data : Data(data.prefix(32)).leftPadded(to: 32)
    }

    /// Storage slot of a pool's slot0 inside the PoolManager: `keccak256(abi.encode(poolId, 6))`.
    static func slot0(of poolId: Data) -> Data {
        Keccak.hash256((try? ABI.encode([.bytes(word(poolId)), .uint(PoolManager.poolsSlot)], "bytes32,uint256")) ?? Data())
    }

    // MARK: Decoding

    /// `Types.LaunchedToken`, including `exists`; the service drops records that do not exist.
    struct LaunchRecord {
        let token: Address
        let curve: Address
        let deployer: Address
        let creatorFeeRecipient: Address
        let pairToken: Address
        let graduationThreshold: BigUInt
        let creatorTaxBps: Int
        let poolFeeBps: Int
        let tickSpacing: Int
        let holderFeeSharing: Bool
        let graduationVenue: GraduationVenue
        let phase: LaunchPhase
        let sweptQuote: BigUInt
        let sweptTokens: BigUInt
        let sweptAt: Int
        let poolId: Data
        let exists: Bool

        init(_ tuple: ABIValue) {
            token = tuple[0].address
            curve = tuple[1].address
            deployer = tuple[2].address
            creatorFeeRecipient = tuple[3].address
            pairToken = tuple[4].address
            graduationThreshold = tuple[5].uint
            creatorTaxBps = int(tuple[6])
            poolFeeBps = int(tuple[7])
            tickSpacing = int(tuple[8])
            holderFeeSharing = tuple[9].bool
            graduationVenue = GraduationVenue(raw: tuple[10].uint)
            phase = LaunchPhase(raw: tuple[11].uint)
            sweptQuote = tuple[12].uint
            sweptTokens = tuple[13].uint
            sweptAt = int(tuple[14])
            poolId = tuple[15].bytes
            exists = tuple[16].bool
        }
    }

    struct LaunchConfig {
        let supply: BigUInt
        let curveFeeBps: Int
        let poolFeeBps: Int
        let tickSpacing: Int
        let snipeTaxSchedule: [Int]
        let enabled: Bool

        init(_ tuple: ABIValue) {
            supply = tuple[0].uint
            curveFeeBps = int(tuple[1])
            poolFeeBps = int(tuple[2])
            tickSpacing = int(tuple[3])
            snipeTaxSchedule = tuple[4].elements.map(int)
            enabled = tuple[5].bool
        }
    }

    struct TokenInfo {
        let deployer: Address
        let logo: String
        let description: String
        let socials: Socials

        init(_ values: [ABIValue]) {
            deployer = values[0].address
            logo = values[1].string
            description = values[2].string
            let s = values[3]
            socials = Socials(twitter: s[0].string, telegram: s[1].string, discord: s[2].string, website: s[3].string, farcaster: s[4].string)
        }
    }

    static func poolKey(_ tuple: ABIValue) -> PoolKey {
        PoolKey(currency0: tuple[0].address, currency1: tuple[1].address, fee: int(tuple[2]), tickSpacing: int(tuple[3]), hooks: tuple[4].address)
    }

    static func buyQuote(_ values: [ABIValue]) -> BuyQuote {
        BuyQuote(tokensOut: values[0].uint, used: values[1].uint, fee: values[2].uint, tax: values[3].uint, snipe: values[4].uint, refund: values[5].uint)
    }

    static func sellQuote(_ values: [ABIValue]) -> SellQuote {
        SellQuote(quoteOut: values[0].uint, fee: values[1].uint, tax: values[2].uint)
    }

    /// Clamping integer conversion for the small on-chain integers (`uint8`, `uint16`, `int24`, timestamps).
    static func int(_ value: ABIValue) -> Int {
        if case .int(let v) = value { return Int(clamping: v) }
        return Int(clamping: value.uint)
    }
}
