import Foundation
import Observation

/// The swap picker's venue token list (`VenueTokensService`) as the app holds it: read from the store once, off the main
/// actor, and kept in memory, so a search never decodes it (9,405 tokens are 1.8 MB of JSON: 0.1–0.15 s to decode, 0.7 s
/// to encode); brought up to the chain head in the background, one run at a time; and saved only once a segment is read
/// in full, off the main actor, in the format build 16 reads (a JSON array of `Token`), so a downgrade keeps the list.
@Observable
@MainActor
public final class VenueTokenList {
    /// What the store holds: the list as saved, and the last block it is read up to in full.
    public struct Stored: Sendable {
        public var list: Data?
        public var checkpoint: UInt64

        public init(list: Data?, checkpoint: UInt64) {
            self.list = list
            self.checkpoint = checkpoint
        }
    }

    /// Every token with a pool on a venue, as far as the list is read.
    public private(set) var tokens: [Token] = []
    /// The last block every venue is read up to in full.
    public private(set) var checkpoint: UInt64 = 0
    /// The chain head the last run read towards; nil until a run has read one.
    public private(set) var head: UInt64?
    /// Whether a run is reading.
    public private(set) var isRefreshing = false
    /// Runs in a row that ended short of the chain head: a gap, the head unread, an endpoint down or throttling.
    public private(set) var shortRuns = 0
    /// After `stop()` (Delete Account): nothing runs or is saved again until the app is launched anew.
    public private(set) var isStopped = false
    /// Whether the store has been read.
    public private(set) var isLoaded = false

    /// Whether a search may miss a token because the list is short of the chain: never read yet (a fresh install, or the
    /// read build 17 makes once more), or short of what the last run read towards (`VenueTokensService.target`: a refill
    /// under way, or a run that ended short, read on at the next return to the app). The swap picker says so. Before a
    /// run has read the head, only a list never read counts; after `stop()`, nothing reads on, so nothing is said.
    public var isCatchingUp: Bool {
        guard isLoaded, !isStopped else { return false }
        guard let head else { return checkpoint == 0 }
        return checkpoint < VenueTokensService.target(head: head)
    }

    @ObservationIgnored private let service: VenueTokensService
    @ObservationIgnored private let logos: @Sendable () async -> [Address: URL]
    @ObservationIgnored private let read: @Sendable () -> Stored
    @ObservationIgnored private let write: @MainActor (Data, UInt64) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    /// When `resume` may run again after a run that ended short.
    @ObservationIgnored private var retryAfter = Date.distantPast
    /// The checkpoint the store holds.
    @ObservationIgnored private var saved: UInt64 = 0
    /// Addresses a run read with no readable symbol (`VenueTokensService.Progress.dropped`), kept for the runs after it in
    /// this process: a segment a run left short is read again, and what it dropped isn't read again with it.
    @ObservationIgnored private var dropped: Set<Address> = []
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Which run may change the list and the store: `stop` moves it on, so a run it cancelled, and a save of that run
    /// already on its way, change nothing.
    @ObservationIgnored private var generation = 0

    /// `read` and `write` are the store: `read` runs off the main actor, once; `write` on it, with the list encoded.
    public init(service: VenueTokensService, logos: @escaping @Sendable () async -> [Address: URL], read: @escaping @Sendable () -> Stored,
                write: @escaping @MainActor (Data, UInt64) -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.logos = logos
        self.read = read
        self.write = write
        self.now = now
    }

    /// Brings the list up to the chain head in the background (`VenueTokensService.refresh`), unless a run already is. The
    /// first run reads the store first. Call it once App Lock's default is decided (`AppSettings`): a save writes keys an
    /// earlier install is told apart by.
    public func refresh() {
        guard !isStopped, run == nil else { return }
        isRefreshing = true
        let generation = generation
        run = Task { await perform(generation) }
    }

    /// Before this device's data is erased (Delete Account, Forget This Device): the run under way is cancelled, and
    /// nothing is read or saved again until the app is launched anew. A save after the erase would put the list's
    /// `venueTokens.` keys back in an emptied store, and App Lock's default would then take the next launch for an
    /// install from before it (`AppSettings`, R4) and start OFF. The list in memory stays for search: it is public data.
    public func stop() {
        isStopped = true
        generation += 1
        run?.cancel()
        run = nil
        isRefreshing = false
    }

    /// On a return to the app: runs again when the last run ended short of the chain head, which a cold launch alone
    /// used to retry, after a pause that doubles with each such run in a row (`retryPause`), so an endpoint that is down
    /// or throttling isn't asked again at every return. Nothing when the last run read to the head, or one is running.
    public func resume() {
        guard shortRuns > 0, now() >= retryAfter else { return }
        refresh()
    }

    /// The pause before the run after `shortRuns` runs in a row ended short: 30 s, doubling, at most 30 min.
    nonisolated static func retryPause(afterShortRuns shortRuns: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, shortRuns - 1))), 1_800)
    }

    /// Waits for the run under way, if any.
    public func finished() async {
        await run?.value
    }

    private func perform(_ generation: Int) async {
        if !isLoaded {
            let read = self.read
            let stored = await Task.detached(priority: .utility) { Self.decode(read()) }.value
            guard generation == self.generation else { return }
            tokens = stored.tokens
            checkpoint = stored.checkpoint
            saved = stored.checkpoint
            isLoaded = true
        }
        let result = await service.refresh(tokens: tokens, checkpoint: checkpoint, dropped: dropped, logos: logos) { [weak self] progress in
            guard let self, await self.show(progress, generation) else { return }
            let data = await Task.detached(priority: .utility) { Self.encode(progress.tokens) }.value
            if let data { await self.store(data, checkpoint: progress.checkpoint, generation) }
        }
        guard generation == self.generation else { return }
        // Nothing read (the head couldn't be read): the list is as it was, and so is what the picker says.
        if let result { head = result.head; dropped = result.dropped }
        if result?.complete == true {
            shortRuns = 0
        } else {
            shortRuns += 1
            retryAfter = now().addingTimeInterval(Self.retryPause(afterShortRuns: shortRuns))
        }
        run = nil
        isRefreshing = false
    }

    /// A run's progress, in memory at once; whether the store should follow: only once the checkpoint moved, so a segment
    /// read in part, or one to be read again for more tokens than a read keeps, costs no save.
    private func show(_ progress: VenueTokensService.Progress, _ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        tokens = progress.tokens
        checkpoint = progress.checkpoint
        head = progress.head
        dropped = progress.dropped
        return progress.checkpoint != saved
    }

    /// Checked here, on the main actor with the write: an erase runs there too, so it comes before this save (which then
    /// writes nothing) or after it (and erases it).
    private func store(_ list: Data, checkpoint: UInt64, _ generation: Int) {
        guard generation == self.generation else { return }
        write(list, checkpoint)
        saved = checkpoint
    }

    /// The stored list, its symbols and names capped (`VenueTokensService.capped`), and its checkpoint. A list that can't
    /// be read back is read again from genesis: its checkpoint would skip every token it held.
    nonisolated static func decode(_ stored: Stored) -> (tokens: [Token], checkpoint: UInt64) {
        guard let data = stored.list, let list = try? JSONDecoder().decode([Token].self, from: data) else { return ([], 0) }
        return (list.map(VenueTokensService.capped), stored.checkpoint)
    }

    /// The list as build 16 stores it.
    nonisolated static func encode(_ tokens: [Token]) -> Data? {
        try? JSONEncoder().encode(tokens)
    }
}
