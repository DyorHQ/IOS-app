import BigInt
import Foundation

/// Discovers every ERC-20 a wallet actually holds by scanning its incoming `Transfer` logs — no indexer and no
/// curated list needed. This is what surfaces a token received on-chain (a swap on another app, an airdrop, a plain
/// transfer) that was never added by hand, so it shows in holdings and the swap picker like any curated asset.
///
/// The scan is address-filter-free — the wallet is a log topic — so ONE pass over the window finds every token that
/// has paid into the wallet; a `balanceOf` sweep then keeps only what is still held, and metadata resolves each.
public struct WalletTokenDiscovery: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall

    public init(logsRPC: RPCClient, multicall: Multicall) {
        self.logsRPC = logsRPC
        self.multicall = multicall
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// The tokens to show as Unverified once, after an upgrade from builds that stored every token found in the
    /// wallet's history as if the user had chosen it (security audit 2026-09-26, IOST-12) — discovery skips a token
    /// already stored, so it would never be marked otherwise. That is all of `stored` except native MON and the curated
    /// list, plus those already marked: nothing recorded which of them the user bought in the app, so each is marked,
    /// and a later swap into it clears the mark.
    public static func unverifiedAfterUpgrade(stored: [Token], alreadyUnverified: Set<Address>) -> Set<Address> {
        alreadyUnverified.union(stored.filter { !$0.isNative && Token.core($0.address) == nil }.map(\.address))
    }

    /// The ERC-20 tokens the wallet currently holds (balance > 0), resolved to `Token` metadata. `window` bounds how
    /// far back the incoming-transfer scan looks; `known` addresses (already-surfaced tokens, native MON) are skipped
    /// so only NEW tokens are read.
    public func heldTokens(wallet: Address, window: UInt64 = Monad.blocksPerDay * 30, known: Set<Address> = [], wholeHistory: Bool = false) async -> [Token] {
        guard let anchor = try? await logsRPC.block(.latest) else { return [] }
        let latest = anchor.number
        let from = wholeHistory ? 0 : (latest > window ? latest - window : 0)
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // Every ERC-20 that has sent tokens to this wallet in the window; the emitting contract IS the token.
        let incoming = await logsRPC.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest)

        var candidates: [Address] = []
        var seen = Set<Address>()
        for log in incoming where Self.isERC20Transfer(log) && !log.address.isZero && !known.contains(log.address) && seen.insert(log.address).inserted {
            candidates.append(log.address)
        }
        guard !candidates.isEmpty else { return [] }

        // Keep only currently-held tokens, reading balanceOf in batches so one multicall response stays bounded.
        var held: [Address] = []
        var index = 0
        while index < candidates.count {
            let batch = Array(candidates[index ..< min(index + 150, candidates.count)])
            index += batch.count
            guard let calls = try? batch.map({ try ERC20.balanceOf($0, wallet) }),
                  let results = try? await multicall.read(calls) else { continue }
            for (token, result) in zip(batch, results) {
                if case .success(let values) = result, let balance = values.first.flatMap(\.uintOrNil), balance > 0 { held.append(token) }
            }
        }
        guard !held.isEmpty else { return [] }

        // Resolve metadata for the survivors; drop only those with no readable symbol.
        var out: [Token] = []
        for token in held {
            if let resolved = try? await ERC20.metadata(token, multicall: multicall) { out.append(resolved) }
        }
        return out
    }

    /// An ERC-20 `Transfer`: three topics (the signature, `from`, `to`) and the amount as 32 bytes of data. An ERC-721
    /// `Transfer` has the same signature but indexes the token id (four topics, no data), as `SwapHistory` tells them
    /// apart: its contract is a collection, whose `balanceOf` counts editions, not a token a send can move.
    static func isERC20Transfer(_ log: Log) -> Bool { log.topics.count == 3 && log.data.count == 32 }

    /// ERC-165 ids: ERC-721's, and the one every ERC-165 contract must answer false for.
    static let erc721Interface = Data([0x80, 0xac, 0x58, 0xcd])
    static let invalidInterface = Data([0xff, 0xff, 0xff, 0xff])

    /// Which of `tokens` are NFT collections (ERC-721, by ERC-165), so a list of tokens leaves them out: earlier builds'
    /// discovery stored collections the wallet received as if they were tokens, and a Moment edition is one too. A
    /// collection answers true for ERC-721's id and false for the invalid one; a contract answering true to both answers
    /// everything and proves nothing. MON and the curated tokens are never asked, and a contract that doesn't answer, or
    /// a read that fails, stays a token: a collection left in a list can't be sent (the review's simulation refuses it),
    /// while a real token left out couldn't be sent from the app at all.
    public func collections(among tokens: [Token]) async -> Set<Address> {
        var seen = Set<Address>()
        let candidates = tokens.filter { !$0.isNative && Token.core($0.address) == nil && seen.insert($0.address).inserted }.map(\.address)
        var out = Set<Address>()
        var index = 0
        while index < candidates.count {
            let batch = Array(candidates[index ..< min(index + 100, candidates.count)])
            index += batch.count
            guard let calls = try? batch.flatMap({ [try Self.supportsInterface($0, Self.erc721Interface), try Self.supportsInterface($0, Self.invalidInterface)] }),
                  let results = try? await multicall.read(calls), results.count == calls.count else { continue }
            for (i, token) in batch.enumerated() where Self.answersTrue(results[2 * i]) && !Self.answersTrue(results[2 * i + 1]) {
                out.insert(token)
            }
        }
        return out
    }

    static func supportsInterface(_ contract: Address, _ id: Data) throws -> ContractCall {
        try ContractCall(to: contract, "supportsInterface(bytes4)", [.bytes(id)], returns: "bool")
    }

    private static func answersTrue(_ result: Result<[ABIValue], Error>) -> Bool {
        if case .success(let values) = result, case .bool(true)? = values.first { return true }
        return false
    }
}
