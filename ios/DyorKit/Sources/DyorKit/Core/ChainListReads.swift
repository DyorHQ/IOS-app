import Foundation

/// Text on chain that its creator chose — a launch's name, symbol, logo, description and links, a Moment's coin name,
/// symbol and provenance — as the app reads it into a list.
public enum ChainText {
    /// What a name or symbol shows when its read failed: the same U+FFFD that stands for bytes that aren't text.
    public static let unreadable = "\u{FFFD}"
}

/// A list read that did not answer for every item: a protocol value (a price, a supply, a ledger, a record) that must
/// be there wasn't, as when the read reached a node a block behind the one that listed the item. Shown as the error it
/// is, with Retry, never as a shorter list or a missing item.
public struct ChainListUnread: Error, LocalizedError, Equatable, Sendable {
    /// What wasn't read, for the message ("A launch", "A Moment").
    public let what: String

    public init(_ what: String) { self.what = what }

    public var errorDescription: String? { "\(what) couldn't be read from the chain just now. Try again." }
}

public extension Multicall {
    /// The reads of a list, item by item: `items` holds each item's calls, all in the same layout, and `text` the
    /// positions in that layout that read text the item's creator chose. Every other call reads a protocol value, which
    /// the item can't be shown without: if one fails, the read didn't happen as a whole and this throws
    /// (`ChainListUnread`, `what` naming the item). A failed text call is returned as its failure, for the caller to show
    /// a stand-in (`ChainText.unreadable`): the item and its numbers, claims and routing stay. Each item's results come
    /// back in its own layout.
    func readItems(_ items: [[ContractCall]], text: Set<Int>, what: String) async throws -> [[Result<[ABIValue], Error>]] {
        guard !items.isEmpty else { return [] }
        let results = try await read(items.flatMap { $0 })
        var out: [[Result<[ABIValue], Error>]] = []
        var start = 0
        for item in items {
            let slice = Array(results[start ..< start + item.count])
            start += item.count
            for (i, result) in slice.enumerated() where !text.contains(i) {
                if case .failure = result { throw ChainListUnread(what) }
            }
            out.append(slice)
        }
        return out
    }
}
