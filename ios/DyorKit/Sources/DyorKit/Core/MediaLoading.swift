import Foundation

/// Runs at most `limit` operations at once; the rest wait their turn, first come first served (security audit
/// 2026-09-26, RI-5: a screen full of hostile images must not download and decode all of them at the same time). A
/// waiter whose task is cancelled leaves the queue at once and throws `CancellationError`.
public actor AsyncLimiter {
    public let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(_ limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Resumed by `release`, which handed its slot over: `running` already counts this one.
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return } // already handed a slot
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// One load per key, shared by every caller that wants it, and cancelled once every one of them has gone (security
/// audit 2026-09-26, RI-5): a view scrolled away stops its download, instead of a detached task running it to the end.
@MainActor
public final class SharedLoads<Value: Sendable> {
    private final class Load {
        let task: Task<Value?, Never>
        var waiters = 0
        init(task: Task<Value?, Never>) { self.task = task }
    }

    private final class Waiter { var left = false }

    private var loads: [String: Load] = [:]

    public init() {}

    /// Loads in flight, for tests.
    public var count: Int { loads.count }

    /// The value for `key`: from the load already running for it, or from `start`. Nil when the load produced nothing,
    /// or was cancelled because every caller left — a caller that was itself cancelled can tell by `Task.isCancelled`.
    public func value(for key: String, start: @escaping @Sendable () async -> Value?) async -> Value? {
        let load: Load
        if let running = loads[key] {
            load = running
        } else {
            load = Load(task: Task.detached(priority: .userInitiated) { await start() })
            loads[key] = load
        }
        load.waiters += 1
        let waiter = Waiter()
        let value = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.leave(key, load, waiter) }
        }
        leave(key, load, waiter)
        return value
    }

    /// Counts one caller out, once. The last one out cancels the load (a no-op once it has finished) and forgets it,
    /// so the next caller starts afresh.
    private func leave(_ key: String, _ load: Load, _ waiter: Waiter) {
        guard !waiter.left else { return }
        waiter.left = true
        load.waiters -= 1
        guard load.waiters == 0 else { return }
        load.task.cancel()
        if loads[key] === load { loads[key] = nil }
    }
}

/// How a small remote image with letters to stand in for it (a coin logo, a chain badge) waits for its picture. A plain
/// disc for a short grace period, in which a logo from a live host usually arrives, so the letters don't flash first;
/// then the letters while the load goes on, since a dead host holds a download for up to 15 s and four run at once
/// app-wide (`RemoteMedia.fetches`), so a list of them could otherwise sit empty for most of a minute; and the letters at
/// once for a URL that failed a moment ago (`RecentMisses`). The picture takes the place of either as soon as it
/// arrives.
public enum RemoteImageWait {
    /// How long the plain disc shows before the letters.
    public static let grace: Duration = .milliseconds(800)

    /// What a view waiting on a remote image shows.
    public enum Shown: Equatable, Sendable {
        /// The picture.
        case image
        /// The loading placeholder: the plain disc, or a spinner in a view with no letters (and no grace period).
        case loading
        /// The letters, or whatever else stands in for a picture there is none of.
        case standIn
    }

    /// What to show. `failed`: the load answered nothing, or the URL failed a moment ago. `graceOver`: the load has gone
    /// on for the view's grace period (never, in a view without one).
    public static func shown(hasImage: Bool, hasURL: Bool, failed: Bool, graceOver: Bool) -> Shown {
        if hasImage { return .image }
        return hasURL && !failed && !graceOver ? .loading : .standIn
    }

    /// Waits out `grace`: true once it has passed, false when the wait was cancelled first (the view left, or its URL
    /// changed).
    public static func graceElapses(_ grace: Duration = grace) async -> Bool {
        do {
            try await Task.sleep(for: grace)
            return true
        } catch {
            return false
        }
    }
}

/// The image loads that failed lately, each remembered for `lifetime` seconds: a dead host isn't asked again for every
/// row that shows its logo, and those rows show their letters at once.
public struct RecentMisses: Sendable {
    public let lifetime: TimeInterval
    private var failedAt: [String: Date] = [:]

    public init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }

    /// Whether `key` failed less than `lifetime` before `now`.
    public func contains(_ key: String, now: Date = Date()) -> Bool {
        failedAt[key].map { now.timeIntervalSince($0) < lifetime } ?? false
    }

    /// Records that `key` failed at `now`, and forgets the failures that have run out.
    public mutating func record(_ key: String, at now: Date = Date()) {
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < lifetime }
        failedAt[key] = now
    }

    /// Forgets that `key` failed: it has loaded since.
    public mutating func remove(_ key: String) { failedAt[key] = nil }

    /// The failures remembered, run out or not.
    public var count: Int { failedAt.count }
}
