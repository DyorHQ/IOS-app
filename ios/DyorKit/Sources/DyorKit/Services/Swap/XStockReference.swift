import BigInt
import Foundation

/// A curated xStock's reference price, read on chain from its own feed (`XStocks.Feed`, a Chainlink AggregatorV3): the
/// one price the app values a curated xStock at (`PriceService`), and the bound a stock quote is checked against. It is
/// a trust root apart from 1inch and the proxy, trusted as far as the Monad RPC is honest.
///
/// Every check fails closed: a stock with no feed, a read that failed or doesn't decode, an answer of zero or less, a
/// round that is incomplete or answered by an earlier one, a feed or token whose decimals are not the reviewed ones, an
/// update stamped after the block it was read at, and an answer older than the feed's heartbeat by the chain's own clock
/// (the block's timestamp, read in the same aggregate, never the device's) each give no price.
public struct XStockReference: Sendable {
    /// One feed's answer as read, checked.
    public struct Snapshot: Equatable, Sendable {
        /// The stock it prices.
        public let stock: Address
        /// The feed's answer, in units of 10^-`decimals` dollars.
        public let answer: BigUInt
        public let decimals: Int
        /// The stock token's own decimals, as the registry has them and the chain confirmed in the same read.
        public let stockDecimals: Int
        /// When the feed last updated, by the chain's clock (seconds since 1970).
        public let updatedAt: UInt64
        /// The timestamp of the block it was read at.
        public let readAt: UInt64

        /// The price in dollars.
        public var usd: Double { Amount.units(answer, decimals: decimals) }
        /// Seconds between the feed's last update and the read.
        public var age: UInt64 { readAt - updatedAt }
    }

    /// Why a stock has no reference price now.
    public enum Failure: Error, LocalizedError, Equatable {
        /// Not a curated xStock, or one with no feed: never priced, never traded.
        case notListed(Address)
        /// The read failed, or what came back doesn't decode.
        case unreadable
        /// An answer of zero or less, an incomplete round, or an update stamped in the future.
        case badAnswer
        /// The feed reports other decimals than the reviewed ones.
        case feedDecimals(expected: Int, found: BigUInt)
        /// The token reports other decimals than the registry's.
        case tokenDecimals(expected: Int, found: BigUInt)
        /// The answer is older than the feed's heartbeat.
        case stale(age: UInt64, heartbeat: Int)

        public var errorDescription: String? {
            switch self {
            case .stale:
                return L10n.tr("This xStock's reference price is out of date, so DyorHQ doesn't price or trade it right now. Try again later.")
            case .notListed, .unreadable, .badAnswer, .feedDecimals, .tokenDecimals:
                return L10n.tr("DyorHQ couldn't check this xStock's reference price, so it doesn't price or trade it right now.")
            }
        }
    }

    /// `PriceInfo.source` for a price read here: an identifier, never shown.
    // not localized: an identifier
    public static let sourceLabel = "xStock reference"

    // not localized: ABI signatures
    static let latestRoundData = "latestRoundData()"
    static let decimals = "decimals()"
    static let blockTimestamp = "getCurrentBlockTimestamp()"

    /// Runs a batch of reads in one aggregate (`Multicall.read`): one block, so the timestamp read with them is theirs.
    typealias Reader = @Sendable ([ContractCall]) async throws -> [Result<[ABIValue], Error>]

    private let read: Reader
    let stocks: XStocks.Registry

    /// Reads through `multicall` (the swap engine's or the price service's RPC), for the xStocks this build ships.
    public init(multicall: Multicall) {
        self.init(stocks: XStocks.shipped) { try await multicall.read($0) }
    }

    /// Reads with `read`, for `stocks`: a test's fixture registry and answers.
    init(stocks: XStocks.Registry, read: @escaping Reader) {
        self.stocks = stocks
        self.read = read
    }

    /// `stock`'s reference price now. Throws `Failure` when there is none.
    public func snapshot(for stock: Address) async throws -> Snapshot {
        guard let result = try await snapshots(for: [stock])[stock] else { throw Failure.notListed(stock) }
        return try result.get()
    }

    /// Each of `stocks`' reference price now, or why it has none, in one aggregate: the block's timestamp, then each
    /// listed stock's `latestRoundData()`, its feed's `decimals()` and its own `decimals()`. A stock not listed gets
    /// `notListed` and asks nothing; with none listed nothing is read. Throws only when the aggregate itself fails.
    public func snapshots(for stocks: [Address]) async throws -> [Address: Result<Snapshot, Failure>] {
        var out: [Address: Result<Snapshot, Failure>] = [:]
        var listed: [(token: Token, feed: XStocks.Feed)] = []
        for stock in stocks where out[stock] == nil && !listed.contains(where: { $0.token.address == stock }) {
            if let token = self.stocks.curatedToken(stock), let feed = self.stocks.feeds[stock] {
                listed.append((token, feed))
            } else {
                out[stock] = .failure(.notListed(stock))
            }
        }
        guard !listed.isEmpty else { return out }
        var calls = [ContractCall.fixed(to: Multicall.address, Self.blockTimestamp, [], returns: "uint256", context: "XStockReference")]
        for (token, feed) in listed {
            calls.append(.fixed(to: feed.address, Self.latestRoundData, [], returns: "uint80,int256,uint256,uint256,uint80", context: "XStockReference"))
            calls.append(.fixed(to: feed.address, Self.decimals, [], returns: "uint8", context: "XStockReference"))
            calls.append(.fixed(to: token.address, Self.decimals, [], returns: "uint8", context: "XStockReference"))
        }
        let results = try await read(calls)
        guard results.count == calls.count, case .success(let time) = results[0], case .uint(let now)? = time.first,
              let readAt = UInt64(exactly: now) else {
            for (token, _) in listed { out[token.address] = .failure(.unreadable) }
            return out
        }
        for (index, (token, feed)) in listed.enumerated() {
            let base = 1 + index * 3
            out[token.address] = Self.check(round: results[base], feedDecimals: results[base + 1], tokenDecimals: results[base + 2],
                                            readAt: readAt, token: token, feed: feed)
        }
        return out
    }

    /// One stock's reads, checked (see the type's comment): its snapshot, or the first check it fails.
    static func check(round: Result<[ABIValue], Error>, feedDecimals: Result<[ABIValue], Error>, tokenDecimals: Result<[ABIValue], Error>,
                      readAt: UInt64, token: Token, feed: XStocks.Feed) -> Result<Snapshot, Failure> {
        guard case .success(let round) = round, round.count == 5, case .uint(let roundId) = round[0], case .int(let answer) = round[1],
              case .uint(let updated) = round[3], case .uint(let answeredInRound) = round[4],
              case .success(let feedWords) = feedDecimals, case .uint(let feedUnits)? = feedWords.first,
              case .success(let tokenWords) = tokenDecimals, case .uint(let tokenUnits)? = tokenWords.first else {
            return .failure(.unreadable)
        }
        guard feedUnits == BigUInt(feed.decimals) else { return .failure(.feedDecimals(expected: feed.decimals, found: feedUnits)) }
        guard tokenUnits == BigUInt(token.decimals) else { return .failure(.tokenDecimals(expected: token.decimals, found: tokenUnits)) }
        guard answer.sign == .plus, answer > 0, let updatedAt = UInt64(exactly: updated), updatedAt > 0, updatedAt <= readAt,
              answeredInRound >= roundId else {
            return .failure(.badAnswer)
        }
        let age = readAt - updatedAt
        guard age <= UInt64(max(0, feed.heartbeat)) else { return .failure(.stale(age: age, heartbeat: feed.heartbeat)) }
        return .success(Snapshot(stock: token.address, answer: answer.magnitude, decimals: feed.decimals, stockDecimals: token.decimals,
                                 updatedAt: updatedAt, readAt: readAt))
    }
}
