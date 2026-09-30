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
    /// Whether a run is reading.
    public private(set) var isRefreshing = false
    /// Whether the list is still short of the chain head: read from genesis (a fresh install, or the read build 17 makes
    /// once more), or stopped short by a gap. The swap picker says so while a search may miss a token.
    public private(set) var isCatchingUp = false

    @ObservationIgnored private let service: VenueTokensService
    @ObservationIgnored private let logos: @Sendable () async -> [Address: URL]
    @ObservationIgnored private let read: @Sendable () -> Stored
    @ObservationIgnored private let write: @MainActor (Data, UInt64) -> Void
    @ObservationIgnored private var loaded = false
    /// The checkpoint the store holds.
    @ObservationIgnored private var saved: UInt64 = 0
    @ObservationIgnored private var run: Task<Void, Never>?

    /// `read` and `write` are the store: `read` runs off the main actor, once; `write` on it, with the list encoded.
    public init(service: VenueTokensService, logos: @escaping @Sendable () async -> [Address: URL], read: @escaping @Sendable () -> Stored,
                write: @escaping @MainActor (Data, UInt64) -> Void) {
        self.service = service
        self.logos = logos
        self.read = read
        self.write = write
    }

    /// Brings the list up to the chain head in the background (`VenueTokensService.refresh`), unless a run already is. The
    /// first run reads the store first. Call it once App Lock's default is decided (`AppSettings`): a save writes keys an
    /// earlier install is told apart by.
    public func refresh() {
        guard run == nil else { return }
        isRefreshing = true
        run = Task { await perform() }
    }

    /// Waits for the run under way, if any.
    public func finished() async {
        await run?.value
    }

    private func perform() async {
        if !loaded {
            let read = self.read
            let stored = await Task.detached(priority: .utility) { Self.decode(read()) }.value
            tokens = stored.tokens
            checkpoint = stored.checkpoint
            saved = stored.checkpoint
            loaded = true
        }
        isCatchingUp = checkpoint == 0
        let result = await service.refresh(tokens: tokens, checkpoint: checkpoint, logos: logos) { [weak self] progress in
            guard let self, await self.show(progress) else { return }
            let data = await Task.detached(priority: .utility) { Self.encode(progress.tokens) }.value
            if let data { await self.store(data, checkpoint: progress.checkpoint) }
        }
        // Nothing read (the head couldn't be read): the list is as it was, and so is what the picker says.
        if let result { isCatchingUp = !result.complete }
        run = nil
        isRefreshing = false
    }

    /// A run's progress, in memory at once; whether the store should follow: only once the checkpoint moved, so a segment
    /// read in part, or one to be read again for more tokens than a read keeps, costs no save.
    private func show(_ progress: VenueTokensService.Progress) -> Bool {
        tokens = progress.tokens
        checkpoint = progress.checkpoint
        isCatchingUp = !progress.complete
        return progress.checkpoint != saved
    }

    private func store(_ list: Data, checkpoint: UInt64) {
        write(list, checkpoint)
        saved = checkpoint
    }

    /// The stored list, and its checkpoint.
    nonisolated static func decode(_ stored: Stored) -> (tokens: [Token], checkpoint: UInt64) {
        guard let data = stored.list, let list = try? JSONDecoder().decode([Token].self, from: data) else { return ([], stored.checkpoint) }
        return (list, stored.checkpoint)
    }

    /// The list as build 16 stores it.
    nonisolated static func encode(_ tokens: [Token]) -> Data? {
        try? JSONEncoder().encode(tokens)
    }
}
