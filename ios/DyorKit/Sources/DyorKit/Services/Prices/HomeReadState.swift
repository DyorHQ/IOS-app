import Foundation

/// How far Home has read each part of the wallet signed in, and so which of its figures it may show. Home reads four parts
/// of a wallet (`Part`), each its own read; a figure built from a part no read of which has answered for this wallet yet
/// is unread: a placeholder on screen, never "$0.00", and the part's tab says "none" only once the part was read.
///
/// A part is read once a read of it answered, and stays read for the wallet: a later read that fails keeps what the last
/// good one showed, and the screen says so. A read that fails before any answered marks the part `failed`, which its tab
/// says, with Retry, until one answers. Another wallet starts again from `init()`.
public struct HomeReadState: Equatable, Sendable {
    /// One part of the wallet, as Home's split and its holdings tabs name them.
    public enum Part: CaseIterable, Hashable, Sendable {
        /// The wallet's tokens: their balances and prices.
        case spot
        /// Its Perpl account: equity and open positions (none, and $0, without an account).
        case perps
        /// The launch coins it holds or created.
        case launch
        /// Its Moments stakes.
        case moments
    }

    public enum Status: Equatable, Sendable {
        /// No read of the part has answered for the wallet yet, and none has failed.
        case reading
        /// The last read of the part failed, and none has answered for the wallet yet.
        case failed
        /// A read of the part answered for the wallet.
        case read
    }

    private var statuses: [Part: Status] = [:]

    /// A wallet nothing has been read for yet.
    public init() {}

    public func status(_ part: Part) -> Status { statuses[part] ?? .reading }

    public func isRead(_ part: Part) -> Bool { status(part) == .read }

    /// The parts whose last read failed before any answered for the wallet, in `Part` order.
    public var failed: [Part] { Part.allCases.filter { status($0) == .failed } }

    /// One read of `part` answered (`answered`), or failed. An answer marks the part read for good; a failure marks it
    /// failed only while it was never read, so a part once read keeps its last good figures.
    public mutating func record(_ part: Part, answered: Bool) {
        if answered {
            statuses[part] = .read
        } else if !isRead(part) {
            statuses[part] = .failed
        }
    }

    /// Whether the figure of `part` may be shown. Spot's is what neither the Launch nor the Moments tab counts
    /// (`HomeTotals`), so it waits for both of them as well: until they are read, a DyorHQ coin one of them will count
    /// would still be in it.
    public func showsValue(of part: Part) -> Bool {
        switch part {
        case .spot: return isRead(.spot) && isRead(.launch) && isRead(.moments)
        case .perps, .launch, .moments: return isRead(part)
        }
    }
}
