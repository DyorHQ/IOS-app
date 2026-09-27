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
