import BigInt
import Foundation

/* Delta-neutral funding capture on DyorHQ: long the asset on a Monad spot venue, short the same notional on Perpl,
   and collect funding while longs pay shorts. Everything here is pure arithmetic over verified Perpl facts (see
   `PerplFunding` and ios/docs/delta-neutral/PARAMETERS.md) so the app, the tests and the docs agree to the number. */

public enum DeltaNeutral {
    // MARK: Instruments

    /// A spot token that tracks a Perpl market's asset. Wrapped or staked derivatives (cbBTC, rETH, gMON …) hedge the
    /// same price but carry their own peg / yield basis, which the strategy flags.
    public struct SpotOption: Sendable, Hashable, Identifiable {
        public let token: Token
        public let marketId: Int
        public let isDerivative: Bool
        public let note: String
        public var id: Address { token.address }
        public init(token: Token, marketId: Int, isDerivative: Bool, note: String) {
            self.token = token; self.marketId = marketId; self.isDerivative = isDerivative; self.note = note
        }
    }

    /// Perpl markets with a spot leg on Monad, in display order: BTC (1), ETH (20), MON (10). SOL, HYPE and ZEC have no
    /// spot token on Monad and cannot be hedged here.
    public static let hedgeableMarketIds = [1, 20, 10]

    public static func spotOptions(for marketId: Int) -> [SpotOption] {
        func core(_ symbol: String) -> Token? { Token.core.first { $0.symbol == symbol } }
        switch marketId {
        case 1:
            return [
                core("WBTC").map { SpotOption(token: $0, marketId: 1, isDerivative: false, note: "Wrapped BTC, the deepest BTC spot on Monad.") },
                core("cbBTC").map { SpotOption(token: $0, marketId: 1, isDerivative: true, note: "Coinbase-wrapped BTC; its peg to BTC is the extra risk.") },
                core("LBTC").map { SpotOption(token: $0, marketId: 1, isDerivative: true, note: "Lombard staked BTC; earns staking yield, trades with a peg basis.") },
            ].compactMap { $0 }
        case 20:
            return [
                core("WETH").map { SpotOption(token: $0, marketId: 20, isDerivative: false, note: "Wrapped ETH, the reference ETH spot on Monad.") },
                core("rETH").map { SpotOption(token: $0, marketId: 20, isDerivative: true, note: "Rocket Pool staked ETH; accrues staking yield, trades at its own rate vs ETH.") },
                core("ezETH").map { SpotOption(token: $0, marketId: 20, isDerivative: true, note: "Renzo restaked ETH; yield plus restaking and peg risk.") },
            ].compactMap { $0 }
        case 10:
            return [
                SpotOption(token: .mon, marketId: 10, isDerivative: false, note: "Native MON. The swap keeps ~0.02 MON aside for gas."),
                core("gMON").map { SpotOption(token: $0, marketId: 10, isDerivative: true, note: "Liquid-staked MON; earns staking yield, trades with a peg basis.") },
                core("sMON").map { SpotOption(token: $0, marketId: 10, isDerivative: true, note: "Kintsu staked MON; yield plus peg risk.") },
                core("aprMON").map { SpotOption(token: $0, marketId: 10, isDerivative: true, note: "aPriori staked MON; yield plus peg risk.") },
                core("shMON").map { SpotOption(token: $0, marketId: 10, isDerivative: true, note: "ShMonad staked MON; yield plus peg risk.") },
            ].compactMap { $0 }
        default:
            return []
        }
    }

    // MARK: Parameters

    /// Everything the user (or a preset) chooses. Defaults are the conservative launch values from PARAMETERS.md.
    /// The two legs are funded separately: the spot buy is paid in USDC; the perp margin is posted in AUSD, the only
    /// collateral (and quote asset) Perpl accepts.
    public struct Parameters: Sendable, Hashable, Codable {
        /// USDC to spend on the spot leg. The perp notional matches it, so the AUSD margin follows from the leverage.
        public var spotCapitalUSD: Double
        /// Perp leverage: margin = notional / leverage. 1× is the safest (equal collateral on both sides).
        public var perpLeverage: Double
        /// Time-weighted entry: the spot buy is split into `twapSlices` swaps `twapIntervalSeconds` apart, and the
        /// short is added after each slice so the book is never more than one slice away from neutral.
        public var twapSlices: Int
        public var twapIntervalSeconds: Int
        /// Minimum-received bound on each spot slice, in basis points.
        public var spotSlippageBps: Int
        /// A slice whose quoted price impact exceeds this is skipped and retried next interval (or the run pauses).
        public var maxSpotImpactBps: Int
        /// Marketable-limit bound on each perp short, in basis points from the mark.
        public var perpSlippageBps: Int
        /// The hourly funding rate (fraction) below which the position is no longer earning enough; 0 = any negative rate.
        public var exitFundingHourly: Double
        /// Consecutive settlement intervals at or below `exitFundingHourly` before an exit is recommended (or, with
        /// `autoExitOnFundingFlip`, started).
        public var exitAfterIntervals: Int
        /// Alert when the mark is within this percentage of the short's liquidation price.
        public var liquidationBufferPct: Double
        /// Alert when the spot and perp legs differ by more than this share of the notional.
        public var maxDeltaDriftPct: Double
        /// Perpl fee schedule for the perp leg (tier 1 unless the user knows better): taker for market entries,
        /// maker for post-only entries. Closing is free on Perpl.
        public var takerFeeBps: Double
        public var makerFeeBps: Double
        /// Extra AUSD deposited on top of the margin, as a share of the margin: it pays the open fee and absorbs the
        /// first adverse funding intervals so fees alone can never push the short toward liquidation.
        public var marginBufferFraction: Double
        /// When the wallet's AUSD plus the free Perpl balance do not cover the margin, swap USDC → AUSD for the
        /// shortfall before depositing. Off by default: the perp leg is meant to be funded in AUSD.
        public var topUpAUSDFromUSDC: Bool
        /// Exit on its own (close the short, sell the spot) once funding has sat at or below `exitFundingHourly` for
        /// `exitAfterIntervals` consecutive settlements. Only while the app is open — nothing runs otherwise.
        public var autoExitOnFundingFlip: Bool

        public init(spotCapitalUSD: Double = 200, perpLeverage: Double = 2, twapSlices: Int = 4, twapIntervalSeconds: Int = 45,
                    spotSlippageBps: Int = 50, maxSpotImpactBps: Int = 30, perpSlippageBps: Int = 50,
                    exitFundingHourly: Double = 0, exitAfterIntervals: Int = 3, liquidationBufferPct: Double = 15,
                    maxDeltaDriftPct: Double = 2, takerFeeBps: Double = 6.9, makerFeeBps: Double = 0.9,
                    marginBufferFraction: Double = 0.02, topUpAUSDFromUSDC: Bool = false, autoExitOnFundingFlip: Bool = true) {
            self.spotCapitalUSD = spotCapitalUSD; self.perpLeverage = perpLeverage; self.twapSlices = twapSlices
            self.twapIntervalSeconds = twapIntervalSeconds; self.spotSlippageBps = spotSlippageBps
            self.maxSpotImpactBps = maxSpotImpactBps; self.perpSlippageBps = perpSlippageBps
            self.exitFundingHourly = exitFundingHourly; self.exitAfterIntervals = exitAfterIntervals
            self.liquidationBufferPct = liquidationBufferPct; self.maxDeltaDriftPct = maxDeltaDriftPct
            self.takerFeeBps = takerFeeBps; self.makerFeeBps = makerFeeBps
            self.marginBufferFraction = marginBufferFraction; self.topUpAUSDFromUSDC = topUpAUSDFromUSDC
            self.autoExitOnFundingFlip = autoExitOnFundingFlip
        }

        public static let `default` = Parameters()

        /// Records written by older builds may lack newer keys; every field falls back to its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Parameters()
            spotCapitalUSD = try c.decodeIfPresent(Double.self, forKey: .spotCapitalUSD) ?? d.spotCapitalUSD
            perpLeverage = try c.decodeIfPresent(Double.self, forKey: .perpLeverage) ?? d.perpLeverage
            twapSlices = try c.decodeIfPresent(Int.self, forKey: .twapSlices) ?? d.twapSlices
            twapIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .twapIntervalSeconds) ?? d.twapIntervalSeconds
            spotSlippageBps = try c.decodeIfPresent(Int.self, forKey: .spotSlippageBps) ?? d.spotSlippageBps
            maxSpotImpactBps = try c.decodeIfPresent(Int.self, forKey: .maxSpotImpactBps) ?? d.maxSpotImpactBps
            perpSlippageBps = try c.decodeIfPresent(Int.self, forKey: .perpSlippageBps) ?? d.perpSlippageBps
            exitFundingHourly = try c.decodeIfPresent(Double.self, forKey: .exitFundingHourly) ?? d.exitFundingHourly
            exitAfterIntervals = try c.decodeIfPresent(Int.self, forKey: .exitAfterIntervals) ?? d.exitAfterIntervals
            liquidationBufferPct = try c.decodeIfPresent(Double.self, forKey: .liquidationBufferPct) ?? d.liquidationBufferPct
            maxDeltaDriftPct = try c.decodeIfPresent(Double.self, forKey: .maxDeltaDriftPct) ?? d.maxDeltaDriftPct
            takerFeeBps = try c.decodeIfPresent(Double.self, forKey: .takerFeeBps) ?? d.takerFeeBps
            makerFeeBps = try c.decodeIfPresent(Double.self, forKey: .makerFeeBps) ?? d.makerFeeBps
            marginBufferFraction = try c.decodeIfPresent(Double.self, forKey: .marginBufferFraction) ?? d.marginBufferFraction
            topUpAUSDFromUSDC = try c.decodeIfPresent(Bool.self, forKey: .topUpAUSDFromUSDC) ?? d.topUpAUSDFromUSDC
            autoExitOnFundingFlip = try c.decodeIfPresent(Bool.self, forKey: .autoExitOnFundingFlip) ?? d.autoExitOnFundingFlip
        }

        /// Hard bounds a launch must satisfy; each string is a user-facing problem.
        public func problems(marketMaxLeverage: Double) -> [String] {
            var out: [String] = []
            if spotCapitalUSD < 20 { out.append("Put at least 20 USDC into the spot leg so both legs clear Perpl's minimum order sizes.") }
            if marginBufferFraction < 0 || marginBufferFraction > 0.5 { out.append("The margin buffer must be 0–50% of the margin.") }
            if perpLeverage < 1 { out.append("Perp leverage must be at least 1×.") }
            if perpLeverage > marketMaxLeverage { out.append("This market allows at most \(Int(marketMaxLeverage))× leverage.") }
            if perpLeverage > 3 { out.append("Above 3× the short can be liquidated on a rally the spot leg cannot offset in time.") }
            if twapSlices < 1 || twapSlices > 20 { out.append("Use 1 to 20 TWAP slices.") }
            if twapIntervalSeconds < 10 || twapIntervalSeconds > 900 { out.append("Slice interval must be 10 s to 15 min.") }
            if spotSlippageBps < 5 || spotSlippageBps > 500 { out.append("Spot slippage must be 5–500 bp.") }
            if maxSpotImpactBps < 5 || maxSpotImpactBps > 500 { out.append("Max spot impact must be 5–500 bp.") }
            if perpSlippageBps < 5 || perpSlippageBps > 500 { out.append("Perp slippage must be 5–500 bp.") }
            if exitAfterIntervals < 1 || exitAfterIntervals > 48 { out.append("Exit after 1–48 funding intervals.") }
            if liquidationBufferPct < 2 || liquidationBufferPct > 50 { out.append("Liquidation buffer must be 2–50%.") }
            if maxDeltaDriftPct < 0.5 || maxDeltaDriftPct > 20 { out.append("Delta drift tolerance must be 0.5–20%.") }
            return out
        }
    }

    // MARK: TWAP defaults

    /// Slice count for the Simple setup: one slice per $100 of spot, between 1 and 8. The setup doubles it (up to 20)
    /// while a slice's quoted impact still exceeds the cap.
    public static func autoSlices(spotBudget: Double) -> Int {
        guard spotBudget.isFinite, spotBudget > 0 else { return 1 }
        return max(1, min(8, Int((spotBudget / 100).rounded(.up))))
    }

    /// Wall-clock length of a sliced entry or exit; the first slice is immediate.
    public static func entryMinutes(slices: Int, intervalSeconds: Int) -> Double {
        Double(max(0, slices - 1)) * Double(intervalSeconds) / 60
    }

    // MARK: Sizing

    /// The two legs: the spot leg spends `spotBudget` USDC on `notional` of the asset; the perp leg posts
    /// `perpMargin` = notional / leverage in AUSD plus `marginBuffer` for fees (`requiredAUSD` in total). The perp
    /// size is rounded DOWN to the market's lot so the short can always be placed; the notional is then recomputed
    /// from that size so both legs match exactly, and the USDC the rounding leaves over stays in the wallet.
    public struct Sizing: Sendable, Hashable {
        public let notional: Double
        public let perpSize: Double
        public let perpMargin: Double
        public let marginBuffer: Double
        public let spotBudget: Double
        public let spotLeftover: Double
        public let price: Double
        public var spotUnits: Double { perpSize }
        /// AUSD that must be on Perpl (or in the wallet, to deposit) before the first short.
        public var requiredAUSD: Double { perpMargin + marginBuffer }
        public var isViable: Bool { perpSize > 0 && notional > 0 }
    }

    public static func sizing(parameters p: Parameters, price: Double, lotDecimals: Int) -> Sizing {
        let leverage = max(1, p.perpLeverage)
        let lot = pow(10, -Double(lotDecimals))
        let rawSize = price > 0 ? max(0, p.spotCapitalUSD) / price : 0
        let size = (rawSize / lot).rounded(.down) * lot
        let notional = size * price
        let margin = notional / leverage
        return Sizing(notional: notional, perpSize: size, perpMargin: margin, marginBuffer: margin * max(0, p.marginBufferFraction),
                      spotBudget: notional, spotLeftover: max(0, p.spotCapitalUSD - notional), price: price)
    }

    // MARK: Costs

    /// What the round trip costs, before any funding is earned. Spot costs are measured from live quotes (impact and
    /// venue fee are inside the quoted output); the perp entry pays Perpl's open fee; closing the perp is free.
    public struct CostEstimate: Sendable, Hashable {
        public let spotEntry: Double
        public let spotExit: Double
        public let perpEntry: Double
        public let perpExit: Double
        public let gas: Double
        public var total: Double { spotEntry + spotExit + perpEntry + perpExit + gas }
        public func bps(of notional: Double) -> Double { notional > 0 ? total / notional * 10_000 : 0 }
    }

    /// `spotImpactBpsPerSlice` is the quoted shortfall of ONE slice vs the reference price (impact + venue fee); with
    /// equal slices the whole entry loses the same share of the notional. Exit is assumed symmetric.
    public static func costs(notional: Double, spotImpactBpsPerSlice: Double, perpFeeBps: Double, gasUSD: Double) -> CostEstimate {
        let spot = notional * max(0, spotImpactBpsPerSlice) / 10_000
        return CostEstimate(spotEntry: spot, spotExit: spot, perpEntry: notional * perpFeeBps / 10_000, perpExit: 0, gas: gasUSD)
    }

    // MARK: Projection

    public struct Projection: Sendable, Hashable {
        public let hourlyRate: Double
        public let perHour: Double
        public let perDay: Double
        public let per30Days: Double
        public let annualPct: Double
        /// Hours of the current rate needed to earn the round-trip costs back; nil when funding is not being earned.
        public let breakevenHours: Double?
        public let direction: PerplFunding.Direction
        /// A short EARNS while longs pay shorts.
        public var earning: Bool { direction == .longsPayShorts }
    }

    public static func projection(notional: Double, hourlyRate: Double, costs: CostEstimate) -> Projection {
        let perHour = notional * hourlyRate
        return Projection(
            hourlyRate: hourlyRate, perHour: perHour, perDay: perHour * 24, per30Days: perHour * 24 * 30,
            annualPct: PerplFunding.annualized(hourly: hourlyRate) * 100,
            breakevenHours: PerplFunding.breakevenHours(totalCost: costs.total, notional: notional, hourly: hourlyRate),
            direction: PerplFunding.direction(hourly: hourlyRate)
        )
    }

    // MARK: Health

    /// The live state of a running hedge.
    public struct Health: Sendable, Hashable {
        public let spotValue: Double
        public let perpNotional: Double
        /// Spot value minus perp notional (USD): positive = net long.
        public let netDelta: Double
        /// |netDelta| as a share of the perp notional, in percent.
        public let driftPct: Double
        public let liquidationPrice: Double?
        /// How far the mark is from liquidation, in percent of the mark (positive = safe distance).
        public let liquidationDistancePct: Double?
        /// Margin (plus funding premium) over notional.
        public let marginRatio: Double
    }

    public static func health(spotUnits: Double, spotPrice: Double, position: PerpPosition?, mark: Double, maintenanceFraction: Double) -> Health {
        let spotValue = spotUnits * spotPrice
        guard let position else {
            return Health(spotValue: spotValue, perpNotional: 0, netDelta: spotValue, driftPct: spotValue > 0 ? 100 : 0, liquidationPrice: nil, liquidationDistancePct: nil, marginRatio: 0)
        }
        let notional = position.size * mark
        let net = spotValue - notional
        let liq = PerplExchange.liquidationPrice(side: position.side, entry: position.entry, size: position.size, margin: position.margin, premium: position.premium, maintenanceFraction: maintenanceFraction)
        let distance: Double? = liq.flatMap { price in
            guard mark > 0 else { return nil }
            return position.side == .short ? (price - mark) / mark * 100 : (mark - price) / mark * 100
        }
        return Health(
            spotValue: spotValue, perpNotional: notional, netDelta: net,
            driftPct: notional > 0 ? abs(net) / notional * 100 : (spotValue > 0 ? 100 : 0),
            liquidationPrice: liq, liquidationDistancePct: distance,
            marginRatio: notional > 0 ? (position.margin + position.premium) / notional : 0
        )
    }

    // MARK: TWAP

    public struct TWAPSlice: Sendable, Hashable, Identifiable {
        public let index: Int
        public let amountIn: BigUInt
        public let notBefore: Date
        public var id: Int { index }
    }

    /// Equal slices (the last one absorbs the rounding remainder) spaced `interval` apart from `start`.
    public static func twapSchedule(totalIn: BigUInt, slices: Int, interval: TimeInterval, start: Date) -> [TWAPSlice] {
        let n = max(1, slices)
        guard totalIn > 0 else { return [] }
        let base = totalIn / BigUInt(n)
        return (0..<n).map { i in
            let amount = i == n - 1 ? totalIn - base * BigUInt(n - 1) : base
            return TWAPSlice(index: i, amountIn: amount, notBefore: start.addingTimeInterval(interval * Double(i)))
        }
    }

    /// The short to add after a spot slice: the acquired units rounded DOWN to the lot, never more than what is
    /// still unhedged.
    public static func hedgeSize(acquiredUnits: Double, alreadyShort: Double, targetSize: Double, lotDecimals: Int) -> Double {
        let lot = pow(10, -Double(lotDecimals))
        let unhedged = max(0, min(acquiredUnits, targetSize) - alreadyShort)
        return (unhedged / lot).rounded(.down) * lot
    }
}
