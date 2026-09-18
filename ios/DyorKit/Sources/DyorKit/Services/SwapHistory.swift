import BigInt
import Foundation

/// One swap the wallet made, reconstructed from its ERC-20 `Transfer` logs: a transaction where the wallet both
/// sent one token and received another. Amounts are raw (wei); the UI resolves symbols/decimals from its token set.
public struct SwapRecord: Identifiable, Sendable, Hashable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let soldToken: Address
    public let soldAmount: BigUInt
    public let boughtToken: Address
    public let boughtAmount: BigUInt
    public var id: String { hash.hexString }

    public init(hash: Data, block: UInt64, time: Date, soldToken: Address, soldAmount: BigUInt, boughtToken: Address, boughtAmount: BigUInt) {
        self.hash = hash
        self.block = block
        self.time = time
        self.soldToken = soldToken
        self.soldAmount = soldAmount
        self.boughtToken = boughtToken
        self.boughtAmount = boughtAmount
    }
}

/// Reconstructs a wallet's swap history from on-chain `Transfer` events, with no per-token filter: one pair of
/// `eth_getLogs` scans (out of the wallet, into the wallet) covers every token at once, then transactions that both
/// spent and received a token become swaps. This backfills history the local record store didn't capture (older
/// swaps, or ones made on another device). Uses rpc1's wide `eth_getLogs` ranges.
public struct SwapHistoryService: Sendable {
    private let rpc: RPCClient

    public init(rpc: RPCClient) { self.rpc = rpc }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// How far back a history query looks. `all` is capped so a no-address scan stays bounded on a busy chain.
    public enum Window: String, Sendable, CaseIterable, Identifiable {
        case day, week, month, all
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .day: return "24H"
            case .week: return "7D"
            case .month: return "30D"
            case .all: return "All"
            }
        }
        public var blocks: UInt64 {
            switch self {
            case .day: return Monad.blocksPerDay
            case .week: return Monad.blocksPerDay * 7
            case .month: return Monad.blocksPerDay * 30
            case .all: return Monad.blocksPerDay * 90
            }
        }
        /// The matching wall-clock cutoff for filtering recorded rows.
        public var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 86_400 * 7
            case .month: return 86_400 * 30
            case .all: return 86_400 * 90
            }
        }
    }

    /// The current chain head, for a poller to checkpoint from (so it only picks up swaps made after a trader is copied).
    public func head() async -> UInt64? { try? await rpc.block(.latest).number }

    public func swaps(wallet: Address, window: Window, decimals: [Address: Int] = [:], limit: Int = 100) async -> [SwapRecord] {
        guard let anchor = try? await rpc.block(.latest) else { return [] }
        let latest = anchor.number
        let from = latest > window.blocks ? latest - window.blocks : 0
        return await scan(wallet: wallet, from: from, to: latest, anchor: anchor, decimals: decimals, limit: limit)
    }

    /// Swaps in an explicit block range — e.g. the Portfolio's full-history scan from block 0.
    public func swaps(wallet: Address, fromBlock: UInt64, toBlock: UInt64, decimals: [Address: Int] = [:], limit: Int = 100) async -> [SwapRecord] {
        guard toBlock >= fromBlock, let anchor = try? await rpc.block(.latest) else { return [] }
        return await scan(wallet: wallet, from: fromBlock, to: toBlock, anchor: anchor, decimals: decimals, limit: limit)
    }

    private func scan(wallet: Address, from: UInt64, to latest: UInt64, anchor: BlockHeader, decimals: [Address: Int], limit: Int) async -> [SwapRecord] {
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // No address filter: one scan for everything the wallet sent, one for everything it received.
        async let outgoing = rpc.chunkedLogs(address: nil, topics: [topic, walletWord, nil], fromBlock: from, toBlock: latest)
        async let incoming = rpc.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest)
        let (outLogs, inLogs) = await (outgoing, incoming)

        // Group both directions by transaction; a swap is a tx with a spent leg and a received leg.
        struct Leg { let token: Address; let amount: BigUInt; let block: UInt64 }
        var sent: [Data: [Leg]] = [:]
        var received: [Data: [Leg]] = [:]
        // Only ERC-20 transfers: exactly three topics and a 32-byte amount. ERC-721 `Transfer` shares the topic but
        // indexes the token id (four topics, empty data), and an NFT mint in a payment transaction is not a swap leg.
        func isERC20(_ log: Log) -> Bool { log.topics.count == 3 && log.data.count == 32 }
        for log in outLogs where isERC20(log) { sent[log.transactionHash, default: []].append(Leg(token: log.address, amount: BigUInt(log.data), block: log.blockNumber)) }
        for log in inLogs where isERC20(log) { received[log.transactionHash, default: []].append(Leg(token: log.address, amount: BigUInt(log.data), block: log.blockNumber)) }

        // Compare tokens by human value (decimals-normalized), not raw wei — otherwise an 18-decimal reward/refund
        // credited in the same tx would outrank a 6-decimal output. Unknown tokens assume 18.
        func human(_ token: Address, _ raw: BigUInt) -> Double { Double(raw) / pow(10, Double(decimals[token] ?? 18)) }
        // Sum legs per token (so a split route or same-token change lands as one total), then pick the dominant token.
        func dominant(_ legs: [Leg], excluding: Address?) -> (token: Address, amount: BigUInt, block: UInt64)? {
            var sums: [Address: BigUInt] = [:]
            var blocks: [Address: UInt64] = [:]
            for leg in legs where leg.token != excluding {
                sums[leg.token, default: 0] += leg.amount
                blocks[leg.token] = max(blocks[leg.token] ?? 0, leg.block)
            }
            guard let best = sums.max(by: { human($0.key, $0.value) < human($1.key, $1.value) }) else { return nil }
            return (best.key, best.value, blocks[best.key] ?? 0)
        }

        var records: [SwapRecord] = []
        for (hash, sentLegs) in sent {
            guard let recvLegs = received[hash] else { continue }
            guard let sold = dominant(sentLegs, excluding: nil) else { continue }
            guard let bought = dominant(recvLegs, excluding: sold.token) else { continue }
            records.append(SwapRecord(hash: hash, block: sold.block, time: Self.time(anchor: anchor, block: sold.block),
                                      soldToken: sold.token, soldAmount: sold.amount, boughtToken: bought.token, boughtAmount: bought.amount))
        }

        // One-sided transactions can still be swaps whose other leg is native MON, which leaves no Transfer log:
        // MON paid in (the transaction carries value) or MON received (a router unwrapped WMON for the wallet).
        // The transaction itself tells them apart from plain transfers and deposits: value from the wallet, or a
        // call into one of the swap routers.
        let receivedOnly = received.keys.filter { sent[$0] == nil }
        let sentOnly = sent.keys.filter { received[$0] == nil }
        let oneSided = Array((receivedOnly + sentOnly).prefix(300))
        if !oneSided.isEmpty, let answers = try? await rpc.batch(oneSided.map { ("eth_getTransactionByHash", [JSON.string($0.hexString)]) }) {
            for (hash, answer) in zip(oneSided, answers) {
                guard case .success(let tx) = answer, let from = tx["from"].string.flatMap(Address.init), from == wallet else { continue }
                let to = tx["to"].string.flatMap(Address.init)
                let value = tx["value"].string.map { BigUInt($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) ?? 0 } ?? 0
                if let recvLegs = received[hash], value > 0, let bought = dominant(recvLegs, excluding: nil) {
                    records.append(SwapRecord(hash: hash, block: bought.block, time: Self.time(anchor: anchor, block: bought.block),
                                              soldToken: Monad.native, soldAmount: value, boughtToken: bought.token, boughtAmount: bought.amount))
                } else if let sentLegs = sent[hash], let to, Self.swapRouters.contains(to), let sold = dominant(sentLegs, excluding: nil) {
                    records.append(SwapRecord(hash: hash, block: sold.block, time: Self.time(anchor: anchor, block: sold.block),
                                              soldToken: sold.token, soldAmount: sold.amount, boughtToken: Monad.native, boughtAmount: 0))
                }
            }
        }
        return Array(records.sorted { $0.block > $1.block }.prefix(limit))
    }

    /// Contracts a swap for native MON is sent to: the routers DyorHQ itself routes through.
    static let swapRouters: Set<Address> = [Uniswap.universalRouter, MondayTrade.swapRouter, Kuru.entrypoint]

    private static func time(anchor: BlockHeader, block: UInt64) -> Date {
        let delta = Double(anchor.number > block ? anchor.number - block : 0) * 0.4
        return Date(timeIntervalSince1970: TimeInterval(anchor.timestamp)).addingTimeInterval(-delta)
    }
}
