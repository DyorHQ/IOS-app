import Foundation
import XCTest
@testable import DyorKit

/// PriceService remembers pool lookups for a while, not for the app's lifetime (security audit 2026-09-26, RS-12).
final class PoolLookupCacheTests: XCTestCase {
    private let token = Address(literal: "0x00000000000000000000000000000000000000aa")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAMissIsLookedUpAgainAfterItsTTL() {
        var cache = PoolLookupCache<String>()
        XCTAssertTrue(cache.needsLookup(token, now: start))
        cache.noPool(token, now: start)
        XCTAssertFalse(cache.needsLookup(token, now: start.addingTimeInterval(cache.missTTL - 1)))
        XCTAssertTrue(cache.needsLookup(token, now: start.addingTimeInterval(cache.missTTL)))
    }

    func testAChosenPoolIsRecheckedAfterItsTTLAndStillPricesMeanwhile() {
        var cache = PoolLookupCache<String>()
        cache.found(token, "usdc-pool", now: start)
        XCTAssertFalse(cache.needsLookup(token, now: start.addingTimeInterval(cache.hitTTL - 1)))
        XCTAssertTrue(cache.needsLookup(token, now: start.addingTimeInterval(cache.hitTTL)))
        // Due a lookup, but until one completes the last pool keeps pricing the token.
        XCTAssertEqual(cache.source(token), "usdc-pool")
        cache.found(token, "deeper-pool", now: start.addingTimeInterval(cache.hitTTL))
        XCTAssertEqual(cache.source(token), "deeper-pool")
    }

    func testAPoolThatLostItsLiquidityStopsPricing() {
        var cache = PoolLookupCache<String>()
        cache.found(token, "thin-pool", now: start)
        cache.noPool(token, now: start.addingTimeInterval(cache.hitTTL))
        XCTAssertNil(cache.source(token))
        XCTAssertFalse(cache.needsLookup(token, now: start.addingTimeInterval(cache.hitTTL + 1)))
    }

    /// Only a lookup that completed says a token has no pool: one never looked up, or found, has one or may.
    func testATokenHasNoPoolOnlyAfterALookupFoundNone() {
        var cache = PoolLookupCache<String>()
        XCTAssertFalse(cache.hasNoPool(token), "never looked up")
        cache.noPool(token, now: start)
        XCTAssertTrue(cache.hasNoPool(token))
        XCTAssertTrue(cache.needsLookup(token, now: start.addingTimeInterval(cache.missTTL)))
        XCTAssertTrue(cache.hasNoPool(token), "due a lookup, but until one completes the last one stands")
        cache.found(token, "new-pool", now: start.addingTimeInterval(cache.missTTL))
        XCTAssertFalse(cache.hasNoPool(token))
    }

    func testFindingAPoolClearsAMiss() {
        var cache = PoolLookupCache<String>()
        cache.noPool(token, now: start)
        cache.found(token, "new-pool", now: start.addingTimeInterval(cache.missTTL))
        XCTAssertEqual(cache.source(token), "new-pool")
        XCTAssertFalse(cache.needsLookup(token, now: start.addingTimeInterval(cache.missTTL + 1)))
    }
}
