import Foundation

/// Where `DyorCoinRegistry` keeps what it has read: a JSON file in Application Support (`dyor-coins-143.json`), excluded
/// from backup. It holds public chain facts only — every DyorHQ coin found, and how far each factory's list has been
/// read — nothing about the wallet, so it is shared by every account on the device, and a build that doesn't know the file
/// ignores it. It is not UserDefaults on purpose: a key there with an earlier-install prefix turns App Lock off on a new
/// install (`AppSettings`), and a growing list doesn't belong in preferences. Account deletion removes it (`erase`).
public struct DyorCoinStore: Sendable {
    /// What the file holds.
    public struct Snapshot: Codable, Hashable, Sendable {
        /// The file format; a file of another version is ignored and read again from the chain.
        public static let currentVersion = 1

        public var version: Int
        /// Every coin found, sorted by address so the same set always writes the same bytes.
        public var coins: [DyorCoin]
        /// How many of each factory's launches or Moments have been read, in the order the factory lists them.
        public var checkpoints: [Checkpoint]

        public init(coins: [DyorCoin], checkpoints: [Checkpoint]) {
            version = Self.currentVersion
            self.coins = coins.sorted { $0.address.hex < $1.address.hex }
            self.checkpoints = checkpoints.sorted { $0.factory.hex < $1.factory.hex }
        }
    }

    /// A launchpad's first `count` launches, or a cohort's Moments 1…`count`, have been read.
    public struct Checkpoint: Codable, Hashable, Sendable {
        public let factory: Address
        public let count: Int

        public init(factory: Address, count: Int) {
            self.factory = factory
            self.count = count
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `dyor-coins-<chain>.json`; a Debug build pointed at a local fork uses its own file (`-fork`), so a fork's coins
    /// and counts never reach the mainnet one, which shares the chain id.
    public static func fileName(chainId: Int = Monad.chainId, fork: Bool = false) -> String {
        "dyor-coins-\(chainId)\(fork ? "-fork" : "").json"
    }

    /// The store in the app's Application Support folder (created when missing); nil when there is none.
    public static func applicationSupport(chainId: Int = Monad.chainId, fork: Bool = false) -> DyorCoinStore? {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return DyorCoinStore(url: folder.appending(path: fileName(chainId: chainId, fork: fork)))
    }

    /// What the file holds; nil when there is no file, or it can't be read or is of another version.
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Snapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Replaces the file with `snapshot` in one atomic write, and keeps it out of backups.
    public func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }

    /// Deletes the file (account deletion). Nothing to do when there is none.
    public func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}
