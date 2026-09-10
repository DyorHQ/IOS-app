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

    /// The ERC-20 tokens the wallet currently holds (balance > 0), resolved to `Token` metadata. `window` bounds how
    /// far back the incoming-transfer scan looks; `known` addresses (already-surfaced tokens, native MON) are skipped
    /// so only NEW tokens are read.
    public func heldTokens(wallet: Address, window: UInt64 = Monad.blocksPerDay * 30, known: Set<Address> = []) async -> [Token] {
        guard let anchor = try? await logsRPC.block(.latest) else { return [] }
        let latest = anchor.number
        let from = latest > window ? latest - window : 0
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // Every ERC-20 that has sent tokens to this wallet in the window; the emitting contract IS the token.
        let incoming = await logsRPC.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest)

        var candidates: [Address] = []
        var seen = Set<Address>()
        for log in incoming where !log.address.isZero && !known.contains(log.address) && seen.insert(log.address).inserted {
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
}
