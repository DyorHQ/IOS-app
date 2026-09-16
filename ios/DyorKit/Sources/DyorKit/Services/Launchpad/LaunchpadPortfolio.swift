import BigInt
import Foundation

/* The wallet's own launchpad money history, for the cross-app Portfolio: every curve fill it made (with the exact
   fee and tax it paid) and every creator-fee / holder-reward claim. All of it comes from events whose wallet is an
   indexed topic, so each scan is a single filtered `eth_getLogs`. */

/// One curve fill the wallet made. Amounts are raw pair units / token wei; `fee` and `tax` are what left the trade.
public struct WalletCurveFill: Identifiable, Sendable, Hashable {
    public let hash: Data
    public let block: UInt64
    public let logIndex: Int
    public let time: Date
    /// The bonding curve the fill happened on (its token is resolved by the caller from the launch list).
    public let curve: Address
    public let isBuy: Bool
    /// Buys: gross quote paid. Sells: net quote received.
    public let quoteAmount: BigUInt
    public let tokenAmount: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt
    public var id: String { "\(hash.hexString)-\(logIndex)" }

    public init(hash: Data, block: UInt64, logIndex: Int, time: Date, curve: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt, fee: BigUInt, tax: BigUInt) {
        self.hash = hash
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.curve = curve
        self.isBuy = isBuy
        self.quoteAmount = quoteAmount
        self.tokenAmount = tokenAmount
        self.fee = fee
        self.tax = tax
    }
}

/// A fee claim the wallet made: creator fees from the escrow (`token == .zero` is native MON) or holder rewards
/// from a fee-sharing coin (`launchToken` set).
public struct WalletFeeClaim: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case creatorFees, holderRewards }
    public let hash: Data
    public let block: UInt64
    public let logIndex: Int
    public let time: Date
    public let kind: Kind
    /// Creator fees: the pair asset claimed (`.zero` = MON). Holder rewards are paid in the launch's pair asset,
    /// which the caller resolves from `launchToken` (this field is `.zero` for them).
    public let token: Address
    /// For holder rewards: the launch coin whose fees were shared.
    public let launchToken: Address?
    public let amount: BigUInt
    public var id: String { "\(hash.hexString)-\(logIndex)" }

    public init(hash: Data, block: UInt64, logIndex: Int, time: Date, kind: Kind, token: Address, launchToken: Address?, amount: BigUInt) {
        self.hash = hash
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.kind = kind
        self.token = token
        self.launchToken = launchToken
        self.amount = amount
    }
}

public struct LaunchpadWalletHistory: Sendable, Hashable {
    public let fills: [WalletCurveFill]
    public let claims: [WalletFeeClaim]
    public init(fills: [WalletCurveFill], claims: [WalletFeeClaim]) {
        self.fills = fills
        self.claims = claims
    }
    public static let empty = LaunchpadWalletHistory(fills: [], claims: [])
}

extension LaunchpadABI.Events {
    static let escrowClaimed = "Claimed(address,uint256)"
    static let escrowClaimedToken = "ClaimedToken(address,address,uint256)"
    static let sharingClaimed = "Claimed(address,address,uint256)"
    static let escrowClaimedTopic = ABI.eventTopic(escrowClaimed)
    static let escrowClaimedTokenTopic = ABI.eventTopic(escrowClaimedToken)
    static let sharingClaimedTopic = ABI.eventTopic(sharingClaimed)
}

public extension LaunchpadService {
    /// The wallet's curve fills and fee claims over the last `lookbackBlocks` blocks, newest first. Fills are
    /// matched to `curves` (curve → token) so only this factory's launches count.
    func walletHistory(wallet: Address, lookbackBlocks: UInt64, curves: Set<Address>) async -> LaunchpadWalletHistory {
        guard addresses.isDeployed, let anchor = try? await logsRPC.block(.latest) else { return .empty }
        let from = anchor.number > lookbackBlocks ? anchor.number - lookbackBlocks : 0
        let word = wallet.data.leftPadded(to: 32)
        // CurveBuy/CurveSell index the trader first; the escrow indexes the recipient; fee sharing indexes (token, account).
        async let buys = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.buyTopic, word], fromBlock: from, toBlock: anchor.number)
        async let sells = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.sellTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowNative = logsRPC.chunkedLogs(address: addresses.escrow, topics: [LaunchpadABI.Events.escrowClaimedTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowToken = logsRPC.chunkedLogs(address: addresses.escrow, topics: [LaunchpadABI.Events.escrowClaimedTokenTopic, word], fromBlock: from, toBlock: anchor.number)
        async let sharing = logsRPC.chunkedLogs(address: addresses.holderFeeSharing, topics: [LaunchpadABI.Events.sharingClaimedTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        let (buyLogs, sellLogs, escrowNativeLogs, escrowTokenLogs, sharingLogs) = await (buys, sells, escrowNative, escrowToken, sharing)
        return Self.walletHistory(buys: buyLogs, sells: sellLogs, escrowNative: escrowNativeLogs, escrowToken: escrowTokenLogs, sharing: sharingLogs, anchor: anchor, curves: curves)
    }

    /// Pure half of `walletHistory`.
    nonisolated static func walletHistory(buys: [Log], sells: [Log], escrowNative: [Log], escrowToken: [Log], sharing: [Log], anchor: BlockHeader, curves: Set<Address>) -> LaunchpadWalletHistory {
        func when(_ log: Log) -> Date { Date(timeIntervalSince1970: TimeInterval(time(anchor: anchor, block: log.blockNumber))) }
        var fills: [WalletCurveFill] = []
        for log in buys where curves.contains(log.address) {
            guard let fill = LaunchpadABI.fill(log) else { continue }
            fills.append(WalletCurveFill(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), curve: log.address, isBuy: true, quoteAmount: fill.amountIn, tokenAmount: fill.amountOut, fee: fill.fee, tax: fill.tax))
        }
        for log in sells where curves.contains(log.address) {
            guard let fill = LaunchpadABI.fill(log) else { continue }
            fills.append(WalletCurveFill(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), curve: log.address, isBuy: false, quoteAmount: fill.amountOut, tokenAmount: fill.amountIn, fee: fill.fee, tax: fill.tax))
        }
        var claims: [WalletFeeClaim] = []
        for log in escrowNative {
            guard log.topics.count == 2, let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .creatorFees, token: .zero, launchToken: nil, amount: words[0].uint))
        }
        for log in escrowToken {
            guard log.topics.count == 3, let token = log.indexedAddress(1), let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .creatorFees, token: token, launchToken: nil, amount: words[0].uint))
        }
        for log in sharing {
            // `Claimed(address indexed token, address indexed account, uint256 amount)`: `token` is the launch coin; the reward is paid in its pair asset.
            guard log.topics.count == 3, let launchToken = log.indexedAddress(0), let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .holderRewards, token: .zero, launchToken: launchToken, amount: words[0].uint))
        }
        return LaunchpadWalletHistory(
            fills: fills.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block },
            claims: claims.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block }
        )
    }
}
