import BigInt
import XCTest
@testable import DyorKit

/// The delta-neutral arithmetic against hand-computed numbers and Perpl's documented funding/fee facts.
final class DeltaNeutralTests: XCTestCase {
    func testFundingScaleAndDirection() {
        // BTC on 2026-09-16: contract fundingRatePct100k = 4, gateway rate = 40 ppm, both = 0.004%/h.
        XCTAssertEqual(PerplFunding.hourlyRate(pct100k: 4), 0.00004, accuracy: 1e-12)
        XCTAssertEqual(PerplFunding.hourlyRate(ppm: 40), 0.00004, accuracy: 1e-12)
        XCTAssertEqual(PerplFunding.annualized(hourly: 0.00004) * 100, 35.04, accuracy: 0.001)
        XCTAssertEqual(PerplFunding.direction(hourly: 0.00004), .longsPayShorts)
        XCTAssertEqual(PerplFunding.direction(hourly: -0.00001), .shortsPayLongs)
        XCTAssertEqual(PerplFunding.direction(hourly: 0), .flat)
        XCTAssertEqual(PerplFunding.intervalHours, 1.0, accuracy: 0.001)
        // A $10,000 short at 0.004%/h earns $0.40 an hour.
        XCTAssertEqual(PerplFunding.shortIncome(notional: 10_000, hourly: 0.00004, hours: 1), 0.4, accuracy: 1e-9)
    }

    func testNextSettlement() {
        let start: UInt64 = 55_077_246
        let head = start + PerplFunding.blocksPerInterval * 3 + 10
        XCTAssertEqual(PerplFunding.nextSettlementBlock(startBlock: start, head: head), start + PerplFunding.blocksPerInterval * 4)
        XCTAssertEqual(PerplFunding.nextSettlementBlock(startBlock: start, head: start), start + PerplFunding.blocksPerInterval)
        let seconds = PerplFunding.secondsToNextSettlement(startBlock: start, head: head, blockSeconds: 0.4)
        XCTAssertEqual(seconds, Double(PerplFunding.blocksPerInterval - 10) * 0.4, accuracy: 1e-9)
    }

    func testSizingFundsTheLegsSeparatelyAndRoundsToLot() {
        // 1,000 USDC on spot at 2×: 1000 / 75,878.6 = 0.013178… BTC, rounded down to 5 decimals; margin in AUSD.
        let p = DeltaNeutral.Parameters(spotCapitalUSD: 1_000, perpLeverage: 2, marginBufferFraction: 0.02)
        let s = DeltaNeutral.sizing(parameters: p, price: 75_878.6, lotDecimals: 5)
        XCTAssertEqual(s.perpSize, 0.01317, accuracy: 1e-12)
        XCTAssertEqual(s.notional, 0.01317 * 75_878.6, accuracy: 1e-6)
        XCTAssertEqual(s.spotBudget, s.notional, accuracy: 1e-9)
        XCTAssertEqual(s.spotLeftover, 1_000 - s.notional, accuracy: 1e-9)
        XCTAssertEqual(s.perpMargin, s.notional / 2, accuracy: 1e-9)
        XCTAssertEqual(s.marginBuffer, s.perpMargin * 0.02, accuracy: 1e-9)
        XCTAssertEqual(s.requiredAUSD, s.perpMargin * 1.02, accuracy: 1e-9)
        XCTAssertTrue(s.isViable)
        // 1× leverage: equal collateral on both sides (USDC on spot, AUSD on Perpl).
        let one = DeltaNeutral.sizing(parameters: DeltaNeutral.Parameters(spotCapitalUSD: 100, perpLeverage: 1, marginBufferFraction: 0), price: 2_400, lotDecimals: 3)
        XCTAssertEqual(one.perpSize, 0.041, accuracy: 1e-12) // 100 / 2400 = 0.04166 → 0.041
        XCTAssertEqual(one.perpMargin, one.notional, accuracy: 1e-9)
        XCTAssertEqual(one.requiredAUSD, one.notional, accuracy: 1e-9)
        // Too small for one lot → not viable.
        XCTAssertFalse(DeltaNeutral.sizing(parameters: DeltaNeutral.Parameters(spotCapitalUSD: 0.5, perpLeverage: 1), price: 75_000, lotDecimals: 5).isViable)
    }

    func testCostsAndProjection() {
        let costs = DeltaNeutral.costs(notional: 660, spotImpactBpsPerSlice: 20, perpFeeBps: 6.9, gasUSD: 0.05)
        XCTAssertEqual(costs.spotEntry, 1.32, accuracy: 1e-9)
        XCTAssertEqual(costs.spotExit, 1.32, accuracy: 1e-9)
        XCTAssertEqual(costs.perpEntry, 0.4554, accuracy: 1e-9)
        XCTAssertEqual(costs.perpExit, 0)
        XCTAssertEqual(costs.total, 3.1454, accuracy: 1e-9)
        XCTAssertEqual(costs.bps(of: 660), 47.657, accuracy: 0.001)
        let projection = DeltaNeutral.projection(notional: 660, hourlyRate: 0.00004, costs: costs)
        XCTAssertEqual(projection.perHour, 0.0264, accuracy: 1e-9)
        XCTAssertEqual(projection.perDay, 0.6336, accuracy: 1e-9)
        XCTAssertEqual(projection.annualPct, 35.04, accuracy: 0.001)
        XCTAssertEqual(projection.breakevenHours!, 3.1454 / 0.0264, accuracy: 1e-6)
        XCTAssertTrue(projection.earning)
        XCTAssertNil(DeltaNeutral.projection(notional: 660, hourlyRate: -0.00001, costs: costs).breakevenHours)
    }

    func testHealthOfAShortHedge() {
        // Short 0.01 BTC from 75,000 with $375 margin (2×), maintenance 4%: liquidation ≈ 75,000 + (30 − 375)/0.01 … below entry?
        // For a short: P_liq = entry − (MMR − margin − premium)/size = 75,000 − (30 − 375)/0.01 = 75,000 + 34,500 = 109,500.
        let position = PerpPosition(perpId: 1, symbol: "BTC", side: .short, size: 0.01, entry: 75_000, mark: 76_000, margin: 375, unrealized: -10, premium: 0, leverage: 2, liquidation: nil, notional: 760)
        let health = DeltaNeutral.health(spotUnits: 0.01, spotPrice: 76_000, position: position, mark: 76_000, maintenanceFraction: 0.04)
        XCTAssertEqual(health.liquidationPrice!, 109_500, accuracy: 1e-6)
        XCTAssertEqual(health.liquidationDistancePct!, (109_500 - 76_000) / 76_000 * 100, accuracy: 1e-9)
        XCTAssertEqual(health.netDelta, 0, accuracy: 1e-9)
        XCTAssertEqual(health.driftPct, 0, accuracy: 1e-9)
        XCTAssertEqual(health.marginRatio, 375 / 760, accuracy: 1e-9)
        // Spot dust above the hedge shows as a small net long.
        let drift = DeltaNeutral.health(spotUnits: 0.0102, spotPrice: 76_000, position: position, mark: 76_000, maintenanceFraction: 0.04)
        XCTAssertEqual(drift.netDelta, 15.2, accuracy: 1e-9)
        XCTAssertEqual(drift.driftPct, 2, accuracy: 1e-9)
        // No perp yet: fully unhedged.
        XCTAssertEqual(DeltaNeutral.health(spotUnits: 0.01, spotPrice: 76_000, position: nil, mark: 76_000, maintenanceFraction: 0.04).driftPct, 100)
    }

    func testTWAPScheduleAndHedgeSize() {
        let start = Date(timeIntervalSince1970: 1_000)
        let slices = DeltaNeutral.twapSchedule(totalIn: 1_000_001, slices: 4, interval: 45, start: start)
        XCTAssertEqual(slices.map(\.amountIn), [250_000, 250_000, 250_000, 250_001])
        XCTAssertEqual(slices[3].notBefore.timeIntervalSince1970, 1_135)
        XCTAssertEqual(DeltaNeutral.twapSchedule(totalIn: 0, slices: 4, interval: 45, start: start).count, 0)
        // Acquired 0.002637 ETH, none shorted yet, target 0.01 → short 0.002 (lot 0.001).
        XCTAssertEqual(DeltaNeutral.hedgeSize(acquiredUnits: 0.002637, alreadyShort: 0, targetSize: 0.01, lotDecimals: 3), 0.002, accuracy: 1e-12)
        // Already short 0.002 of 0.005 acquired → 0.003 more; never above the target.
        XCTAssertEqual(DeltaNeutral.hedgeSize(acquiredUnits: 0.0052, alreadyShort: 0.002, targetSize: 0.004, lotDecimals: 3), 0.002, accuracy: 1e-12)
    }

    func testParameterBounds() {
        XCTAssertTrue(DeltaNeutral.Parameters.default.problems(marketMaxLeverage: 15).isEmpty)
        let bad = DeltaNeutral.Parameters(spotCapitalUSD: 5, perpLeverage: 20, twapSlices: 0, twapIntervalSeconds: 1)
        let problems = bad.problems(marketMaxLeverage: 15)
        XCTAssertTrue(problems.contains { $0.contains("at least 20 USDC") })
        XCTAssertTrue(problems.contains { $0.contains("at most 15×") })
        XCTAssertTrue(problems.contains { $0.contains("TWAP slices") })
    }

    func testAutoSlicesAndEntryLength() {
        XCTAssertEqual(DeltaNeutral.autoSlices(spotBudget: 50), 1)
        XCTAssertEqual(DeltaNeutral.autoSlices(spotBudget: 200), 2)
        XCTAssertEqual(DeltaNeutral.autoSlices(spotBudget: 250), 3)
        XCTAssertEqual(DeltaNeutral.autoSlices(spotBudget: 5_000), 8)
        XCTAssertEqual(DeltaNeutral.autoSlices(spotBudget: 0), 1)
        XCTAssertEqual(DeltaNeutral.entryMinutes(slices: 4, intervalSeconds: 45), 2.25, accuracy: 1e-9)
        XCTAssertEqual(DeltaNeutral.entryMinutes(slices: 1, intervalSeconds: 45), 0, accuracy: 1e-9)
    }

    func testParametersDecodeOlderRecords() throws {
        let json = Data(#"{"spotCapitalUSD":150,"perpLeverage":1}"#.utf8)
        let p = try JSONDecoder().decode(DeltaNeutral.Parameters.self, from: json)
        XCTAssertEqual(p.spotCapitalUSD, 150)
        XCTAssertEqual(p.perpLeverage, 1)
        XCTAssertEqual(p.twapSlices, DeltaNeutral.Parameters.default.twapSlices)
        XCTAssertTrue(p.autoExitOnFundingFlip)
        XCTAssertFalse(p.topUpAUSDFromUSDC)
        let encoded = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(DeltaNeutral.Parameters.self, from: encoded), p)
    }

    func testSpotOptionsCoverHedgeableMarkets() {
        for id in DeltaNeutral.hedgeableMarketIds {
            let options = DeltaNeutral.spotOptions(for: id)
            XCTAssertFalse(options.isEmpty, "market \(id)")
            XCTAssertFalse(options[0].isDerivative, "the default spot for market \(id) must be the plain asset")
        }
        XCTAssertTrue(DeltaNeutral.spotOptions(for: 31).isEmpty) // SOL has no Monad spot
    }
}
