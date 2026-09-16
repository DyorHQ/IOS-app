import Foundation

/// Perpl funding, as the exchange defines it (docs.perpl.xyz/exchange/funding): the rate is the sum over the interval
/// of the impact-price premium vs the oracle, clamped, and it settles every `blocksPerInterval` blocks — about once an
/// hour. A positive rate means long positions pay short positions; a negative one, the reverse. Positions carry it as
/// `premium` (the contract's `premiumPnlCNS`) until they settle.
public enum PerplFunding {
    /// Funding settles every 8 571 blocks ("assumes 0.42 second average consensus time").
    public static let blocksPerInterval: UInt64 = 8_571
    /// The block time the interval assumes, in seconds.
    public static let assumedBlockSeconds = 0.42
    /// Hours per interval at the assumed block time (≈ 1.0).
    public static let intervalHours = Double(blocksPerInterval) * assumedBlockSeconds / 3_600
    public static let hoursPerYear = 24.0 * 365.0

    /// `fundingRatePct100k` (contract, parts per 100 000) → fraction of notional per interval.
    public static func hourlyRate(pct100k: Int) -> Double { Double(pct100k) / 100_000 }
    /// Gateway `funding.rate` (parts per million) → fraction of notional per interval.
    public static func hourlyRate(ppm: Double) -> Double { ppm / 1_000_000 }

    /// Simple (non-compounded) annualization of an hourly rate.
    public static func annualized(hourly: Double) -> Double { hourly * hoursPerYear }
    public static func daily(hourly: Double) -> Double { hourly * 24 }

    /// Who pays whom at this rate. Zero is a wash.
    public enum Direction: Sendable, Hashable {
        case longsPayShorts, shortsPayLongs, flat
        public var summary: String {
            switch self {
            case .longsPayShorts: return "Longs pay shorts"
            case .shortsPayLongs: return "Shorts pay longs"
            case .flat: return "No funding"
            }
        }
    }

    public static func direction(hourly: Double) -> Direction {
        if hourly > 0 { return .longsPayShorts }
        if hourly < 0 { return .shortsPayLongs }
        return .flat
    }

    /// Funding earned (positive) or paid (negative) by a SHORT of `notional` over `hours` at a constant hourly rate.
    public static func shortIncome(notional: Double, hourly: Double, hours: Double) -> Double { notional * hourly * hours }

    /// The next settlement block on the market's schedule (the first boundary strictly after `head`).
    public static func nextSettlementBlock(startBlock: UInt64, head: UInt64) -> UInt64 {
        guard head >= startBlock, startBlock > 0 else { return head + blocksPerInterval }
        let elapsed = head - startBlock
        let periods = elapsed / blocksPerInterval + 1
        return startBlock + periods * blocksPerInterval
    }

    /// Seconds until the next settlement, from the head block and the chain's measured block time.
    public static func secondsToNextSettlement(startBlock: UInt64, head: UInt64, blockSeconds: Double = assumedBlockSeconds) -> Double {
        Double(nextSettlementBlock(startBlock: startBlock, head: head) - head) * blockSeconds
    }

    /// Hours a short must be held for funding to pay back `totalCost` at a constant hourly rate; nil when the rate
    /// is not positive (funding is being paid, not earned).
    public static func breakevenHours(totalCost: Double, notional: Double, hourly: Double) -> Double? {
        let perHour = notional * hourly
        guard perHour > 0, totalCost >= 0 else { return nil }
        return totalCost / perHour
    }
}
