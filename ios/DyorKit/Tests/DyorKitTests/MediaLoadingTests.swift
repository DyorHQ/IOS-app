import Foundation
import XCTest
@testable import DyorKit

/// Remote images load a few at a time, and a load every viewer left is cancelled (security audit 2026-09-26, RI-5).
final class MediaLoadingTests: XCTestCase {
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private(set) var peak = 0
        func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
    }

    func testTheLimiterRunsAtMostItsLimitAtOnce() async throws {
        let limiter = AsyncLimiter(2)
        let gauge = Gauge()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await limiter.run {
                        gauge.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        gauge.leave()
                        return i
                    }
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertEqual(results.sorted(), Array(0..<10))
        XCTAssertEqual(gauge.peak, 2)
    }

    func testAWaiterThatIsCancelledLeavesTheQueue() async throws {
        let limiter = AsyncLimiter(1)
        let release = AsyncStream<Void>.makeStream()
        let holder = Task { try await limiter.run { for await _ in release.stream { break }; return 0 } }
        try await Task.sleep(for: .milliseconds(50)) // the holder has the only slot
        let waiter = Task { try await limiter.run { 1 } }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled waiter doesn't run")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        release.continuation.yield()
        _ = try await holder.value
        // The slot is free again for the next one.
        let next = try await limiter.run { 2 }
        XCTAssertEqual(next, 2)
    }

    @MainActor
    func testOneLoadIsSharedAndCancelledWhenEveryoneLeaves() async throws {
        let loads = SharedLoads<Int>()
        let starts = Gauge()
        let gate = AsyncStream<Void>.makeStream()
        let start: @Sendable () async -> Int? = {
            starts.enter()
            for await _ in gate.stream { return 7 }
            return nil // cancelled: the stream finished
        }
        // Two viewers, one load.
        let a = Task { @MainActor in await loads.value(for: "k", start: start) }
        let b = Task { @MainActor in await loads.value(for: "k", start: start) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(starts.peak, 1)
        XCTAssertEqual(loads.count, 1)
        gate.continuation.yield()
        let (va, vb) = (await a.value, await b.value)
        XCTAssertEqual(va, 7)
        XCTAssertEqual(vb, 7)
        XCTAssertEqual(loads.count, 0, "finished and forgotten")

        // Every viewer leaves: the load is cancelled and forgotten, so the next viewer starts afresh.
        let slow = SharedLoads<Int>()
        let sawCancel = Gauge()
        let blocked: @Sendable () async -> Int? = {
            do { try await Task.sleep(for: .seconds(30)) } catch { sawCancel.enter() }
            return nil
        }
        let c = Task { @MainActor in await slow.value(for: "k", start: blocked) }
        let d = Task { @MainActor in await slow.value(for: "k", start: blocked) }
        try await Task.sleep(for: .milliseconds(50))
        c.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(slow.count, 1, "one viewer is still waiting")
        XCTAssertEqual(sawCancel.peak, 0)
        d.cancel()
        _ = await c.value
        _ = await d.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sawCancel.peak, 1, "the load itself was cancelled")
        XCTAssertEqual(slow.count, 0)
    }

    // MARK: How a logo waits

    /// A logo shows its plain disc only for the grace period while it loads, then its letters; the letters at once when
    /// there is no URL or it failed (lately); the picture whenever there is one.
    func testALogoWaitsOnlyAMomentBeforeItsLetters() {
        typealias Wait = RemoteImageWait
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: false, graceOver: false), .loading)
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: false, graceOver: true), .standIn, "a slow or dead host")
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: true, failed: true, graceOver: false), .standIn, "failed, or failed lately")
        XCTAssertEqual(Wait.shown(hasImage: false, hasURL: false, failed: false, graceOver: false), .standIn, "no image")
        XCTAssertEqual(Wait.shown(hasImage: true, hasURL: true, failed: false, graceOver: true), .image, "late, but here")
        XCTAssertEqual(Wait.shown(hasImage: true, hasURL: true, failed: true, graceOver: false), .image)
        // A moment: long enough for a live host, far short of a dead one's 15 s.
        XCTAssertGreaterThanOrEqual(Wait.grace, .milliseconds(500))
        XCTAssertLessThanOrEqual(Wait.grace, .seconds(1))
    }

    func testTheGracePeriodEndsUnlessTheViewLeavesFirst() async {
        let over = await RemoteImageWait.graceElapses(.milliseconds(10))
        XCTAssertTrue(over)
        let left = Task { await RemoteImageWait.graceElapses(.seconds(30)) }
        left.cancel()
        let leftOver = await left.value
        XCTAssertFalse(leftOver, "a view that left, or changed URL, doesn't show its letters on the old wait")
    }

    /// A failed URL is remembered for its lifetime, then asked again; one that loaded is forgotten; run-out failures
    /// don't pile up.
    func testAFailedURLIsRememberedForAMinute() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var misses = RecentMisses()
        XCTAssertEqual(misses.lifetime, 60)
        XCTAssertFalse(misses.contains("a", now: start))
        misses.record("a", at: start)
        XCTAssertTrue(misses.contains("a", now: start))
        XCTAssertTrue(misses.contains("a", now: start + 59.9))
        XCTAssertFalse(misses.contains("a", now: start + 60), "asked again after a minute")
        XCTAssertFalse(misses.contains("b", now: start))
        misses.record("b", at: start + 30)
        misses.remove("b")
        XCTAssertFalse(misses.contains("b", now: start + 31), "it loaded since")
        misses.record("c", at: start + 61)
        XCTAssertEqual(misses.count, 1, "a's run-out failure is dropped when another is recorded")
        XCTAssertTrue(misses.contains("c", now: start + 61))
    }
}
