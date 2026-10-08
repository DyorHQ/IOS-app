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

    /// A sale into native MON whose MON couldn't be read (`SwapHistoryService.nativeReceived`): its amount is unknown, not
    /// zero. Shown without an amount, and left out of P&L.
    public var boughtNativeUnknown: Bool { boughtToken == Monad.native && boughtAmount == 0 }

    public init(hash: Data, block: UInt64, time: Date, soldToken: Address, soldAmount: BigUInt, boughtToken: Address, boughtAmount: BigUInt) {
        self.hash = hash
        self.block = block
        self.time = time
        self.soldToken = soldToken
        self.soldAmount = soldAmount
        self.boughtToken = boughtToken
        self.boughtAmount = boughtAmount
    }

    /// The same swap, its time estimated again from a newer head.
    public func timed(anchor: BlockHeader, secondsPerBlock: Double) -> SwapRecord {
        SwapRecord(hash: hash, block: block, time: BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock),
                   soldToken: soldToken, soldAmount: soldAmount, boughtToken: boughtToken, boughtAmount: boughtAmount)
    }
}

/// Reconstructs a wallet's swap history from on-chain `Transfer` events, with no per-token filter: one pair of
/// `eth_getLogs` scans (out of the wallet, into the wallet) covers every token at once, then transactions that both
/// spent and received a token become swaps. This backfills history the local record store didn't capture (older
/// swaps, or ones made on another device). Uses rpc1's wide `eth_getLogs` ranges.
public struct SwapHistoryService: Sendable {
    private let rpc: RPCClient
    /// Turns the 24H, 7D and 30D filters into blocks, and block numbers into the times a swap shows.
    public let clock: BlockClock

    public init(rpc: RPCClient, clock: BlockClock? = nil) {
        self.rpc = rpc
        self.clock = clock ?? BlockClock(rpc: rpc)
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// How far back a history query looks. `all` is capped so a no-address scan stays bounded on a busy chain.
    public enum Window: String, Sendable, CaseIterable, Identifiable {
        case day, week, month, all
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .day: return L10n.string(LocalizedStringResource("24H", bundle: L10n.kit, comment: "[tight] A history window: the last 24 hours."))
            case .week: return L10n.string(LocalizedStringResource("7D", bundle: L10n.kit, comment: "[tight] A history window: the last 7 days."))
            case .month: return L10n.string(LocalizedStringResource("30D", bundle: L10n.kit, comment: "[tight] A history window: the last 30 days."))
            case .all: return L10n.string(LocalizedStringResource("All", bundle: L10n.kit, comment: "[tight] A history window: every swap, as far back as the app reads."))
            }
        }
        /// The blocks a scan of this window reads at `secondsPerBlock`: the day, the week and the month their true length
        /// (`seconds`); "All" the fixed budget `allBlocks`, whatever the pace.
        public func blocks(secondsPerBlock: Double) -> UInt64 {
            self == .all ? Self.allBlocks : BlockClock.blocks(in: seconds, secondsPerBlock: secondsPerBlock)
        }
        /// `blocks(secondsPerBlock:)` at `BlockClock.fallbackSecondsPerBlock`, for a reader with no clock: an estimate.
        /// `swaps(wallet:window:)` uses the session's measured pace.
        public var blocks: UInt64 { blocks(secondsPerBlock: BlockClock.fallbackSecondsPerBlock) }
        /// What an "All" scan reads: a block budget, 19,440,000 blocks (about 68 days at Monad's pace), kept as it was
        /// when it was called 90 days so a scan with no address filter stays bounded on a busy chain.
        public static let allBlocks: UInt64 = 19_440_000
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
        let secondsPerBlock = await clock.secondsPerBlock()
        let latest = anchor.number
        let blocks = window.blocks(secondsPerBlock: secondsPerBlock)
        let from = latest > blocks ? latest - blocks : 0
        return await scan(wallet: wallet, from: from, to: latest, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit)
    }

    /// Swaps in an explicit block range — e.g. the Portfolio's full-history scan from block 0.
    public func swaps(wallet: Address, fromBlock: UInt64, toBlock: UInt64, decimals: [Address: Int] = [:], limit: Int = 100) async -> [SwapRecord] {
        guard toBlock >= fromBlock, let anchor = try? await rpc.block(.latest) else { return [] }
        return await scan(wallet: wallet, from: fromBlock, to: toBlock, anchor: anchor, secondsPerBlock: await clock.secondsPerBlock(), decimals: decimals, limit: limit)
    }

    private func scan(wallet: Address, from: UInt64, to latest: UInt64, anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int], limit: Int) async -> [SwapRecord] {
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // No address filter: one scan for everything the wallet sent, one for everything it received.
        async let outgoing = rpc.chunkedLogs(address: nil, topics: [topic, walletWord, nil], fromBlock: from, toBlock: latest)
        async let incoming = rpc.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest)
        let (outLogs, inLogs) = await (outgoing, incoming)
        return await reconstruct(wallet: wallet, outgoing: outLogs, incoming: inLogs, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit)
    }

    /// The wallet's swaps from its `Transfer` logs — those it sent (`outgoing`) and received (`incoming`), as the history
    /// store keeps them — newest first, at most `limit`: a transaction with a spent leg and a received leg is a swap, and a
    /// one-sided one whose other leg is native MON is read from the transaction itself (`rpc`).
    public func reconstruct(wallet: Address, outgoing outLogs: [Log], incoming inLogs: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int],
                            limit: Int) async -> [SwapRecord] {
        await reconstruct(wallet: wallet, outgoing: outLogs, incoming: inLogs, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit, facts: [:]).records
    }

    /// What a transaction's own record says (`eth_getTransactionByHash`) and what a sale into native MON paid the wallet
    /// (`withNativeReceived`), kept by the caller between reconstructions: once mined, neither changes, so a round that
    /// added a few logs looks up the new transactions only.
    public struct TransactionFacts: Sendable, Hashable {
        public var from: Address?
        public var to: Address?
        public var value: BigUInt
        public var nativeReceived: BigUInt?
    }

    /// `reconstruct`, with what was looked up per transaction before (`facts`) used again, and returned with the new.
    public func reconstruct(wallet: Address, outgoing outLogs: [Log], incoming inLogs: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int],
                            limit: Int, facts known: [Data: TransactionFacts]) async -> (records: [SwapRecord], facts: [Data: TransactionFacts]) {
        var facts = known
        func time(_ block: UInt64) -> Date { BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock) }

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
            records.append(SwapRecord(hash: hash, block: sold.block, time: time(sold.block),
                                      soldToken: sold.token, soldAmount: sold.amount, boughtToken: bought.token, boughtAmount: bought.amount))
        }

        // One-sided transactions can still be swaps whose other leg is native MON, which leaves no Transfer log:
        // MON paid in (the transaction carries value) or MON received (a router unwrapped WMON for the wallet).
        // The transaction itself tells them apart from plain transfers and deposits: value from the wallet, or a
        // call into one of the swap routers.
        let receivedOnly = received.keys.filter { sent[$0] == nil }
        let sentOnly = sent.keys.filter { received[$0] == nil }
        // Looked up for the ones not known yet, up to 300 a build; the rest at the next.
        let oneSided = receivedOnly + sentOnly
        let unknown = Array(oneSided.filter { facts[$0] == nil }.prefix(300))
        if !unknown.isEmpty, let answers = try? await rpc.batch(unknown.map { ("eth_getTransactionByHash", [JSON.string($0.hexString)]) }) {
            for (hash, answer) in zip(unknown, answers) {
                // A node behind the one the logs came from answers null: not a fact, asked again next time.
                guard case .success(let tx) = answer, let from = tx["from"].string.flatMap(Address.init) else { continue }
                let value = tx["value"].string.map { BigUInt($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) ?? 0 } ?? 0
                facts[hash] = TransactionFacts(from: from, to: tx["to"].string.flatMap(Address.init), value: value, nativeReceived: nil)
            }
        }
        for hash in oneSided {
            guard let fact = facts[hash], fact.from == wallet else { continue }
            if let recvLegs = received[hash], fact.value > 0, let bought = dominant(recvLegs, excluding: nil) {
                records.append(SwapRecord(hash: hash, block: bought.block, time: time(bought.block),
                                          soldToken: Monad.native, soldAmount: fact.value, boughtToken: bought.token, boughtAmount: bought.amount))
            } else if let sentLegs = sent[hash], let to = fact.to, Self.swapRouters.contains(to), let sold = dominant(sentLegs, excluding: nil) {
                records.append(SwapRecord(hash: hash, block: sold.block, time: time(sold.block),
                                          soldToken: sold.token, soldAmount: sold.amount, boughtToken: Monad.native, boughtAmount: 0))
            }
        }
        return await withNativeReceived(records.sorted { $0.block > $1.block }.prefix(limit), wallet: wallet, facts: facts)
    }

    /// How many sales into native MON, newest first, a scan reads the MON of (`withNativeReceived`): five reads each.
    static let nativeReadLimit = 50

    /// `records` with the MON each sale into native MON paid the wallet, which no Transfer log carries: the wallet's
    /// balance after the sale's block less its balance before it, plus the gas the sale cost (`nativeReceived`). A sale
    /// whose MON can't be read keeps 0, which the app shows as unknown ("→ MON"), never as "0 MON". Read for the newest
    /// `nativeReadLimit` such sales, in one batch.
    private func withNativeReceived(_ records: ArraySlice<SwapRecord>, wallet: Address, facts known: [Data: TransactionFacts]) async -> (records: [SwapRecord], facts: [Data: TransactionFacts]) {
        var records = Array(records)
        var facts = known
        func apply(_ i: Int, _ received: BigUInt) {
            let swap = records[i]
            records[i] = SwapRecord(hash: swap.hash, block: swap.block, time: swap.time, soldToken: swap.soldToken, soldAmount: swap.soldAmount,
                                    boughtToken: swap.boughtToken, boughtAmount: received)
        }
        // What was read before is applied; the rest is read now, the newest `nativeReadLimit` of them.
        var unread: [Int] = []
        for i in records.indices where records[i].boughtToken == Monad.native && records[i].boughtAmount == 0 && records[i].block > 0 {
            if let read = facts[records[i].hash]?.nativeReceived { apply(i, read) } else if unread.count < Self.nativeReadLimit { unread.append(i) }
        }
        guard !unread.isEmpty else { return (records, facts) }
        var calls: [(method: String, params: [JSON])] = []
        for i in unread {
            let block = records[i].block
            calls += [("eth_getTransactionReceipt", [.string(records[i].hash.hexString)]),
                      ("eth_getBalance", [.string(wallet.hex), BlockTag.number(block - 1).json]),
                      ("eth_getBalance", [.string(wallet.hex), BlockTag.number(block).json]),
                      ("eth_getTransactionCount", [.string(wallet.hex), BlockTag.number(block - 1).json]),
                      ("eth_getTransactionCount", [.string(wallet.hex), BlockTag.number(block).json])]
        }
        guard let answers = try? await rpc.batch(calls), answers.count == calls.count else { return (records, facts) }
        func quantity(_ answer: Result<JSON, RPCError>, _ key: String? = nil) -> BigUInt? {
            guard case .success(let json) = answer else { return nil }
            return (key.map { json[$0] } ?? json).string.flatMap { BigUInt(hexQuantity: $0) }
        }
        for (k, i) in unread.enumerated() {
            let answer = Array(answers[(k * 5)..<(k * 5 + 5)])
            guard case .success(let receipt) = answer[0], receipt["status"].string == "0x1",
                  receipt["blockNumber"].string.flatMap({ BigUInt(hexQuantity: $0) }) == BigUInt(records[i].block),
                  let gasUsed = quantity(answer[0], "gasUsed"), let gasPrice = quantity(answer[0], "effectiveGasPrice"),
                  let before = quantity(answer[1]), let after = quantity(answer[2]),
                  let nonceBefore = quantity(answer[3]), let nonceAfter = quantity(answer[4]),
                  let received = Self.nativeReceived(balanceBefore: before, balanceAfter: after, gasFee: gasUsed * gasPrice,
                                                     noncesBefore: nonceBefore, noncesAfter: nonceAfter) else { continue }
            apply(i, received)
            facts[records[i].hash, default: TransactionFacts(from: nil, to: nil, value: 0, nativeReceived: nil)].nativeReceived = received
        }
        return (records, facts)
    }

    /// The MON a sale into native MON paid the wallet, from its balance on each side of the sale's block and the gas the
    /// sale cost (Monad's receipt reports what was charged): `after + gasFee − before`. Only when the sale is the wallet's
    /// one transaction in that block (its count of sent transactions moved by exactly one), so nothing else it sent moved
    /// its balance; nil otherwise, or when that comes to nothing.
    static func nativeReceived(balanceBefore: BigUInt, balanceAfter: BigUInt, gasFee: BigUInt, noncesBefore: BigUInt, noncesAfter: BigUInt) -> BigUInt? {
        guard noncesAfter == noncesBefore + 1, balanceAfter + gasFee > balanceBefore else { return nil }
        return balanceAfter + gasFee - balanceBefore
    }

    /// Contracts a swap for native MON is sent to: the routers DyorHQ itself routes through.
    static let swapRouters: Set<Address> = [Uniswap.universalRouter, MondayTrade.swapRouter, Kuru.entrypoint]
}
