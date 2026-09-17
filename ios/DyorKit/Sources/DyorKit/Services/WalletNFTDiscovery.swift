import BigInt
import Foundation

/// Discovers every ERC-721 a wallet holds on Monad — Moments or any other collection — from its own transfer
/// history, with no indexer: candidates come from incoming `Transfer` logs with an indexed token id, ownership is
/// confirmed on-chain, and each token's metadata (name, image, animation) is resolved from its `tokenURI`.
public struct WalletNFTDiscovery: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall

    public init(logsRPC: RPCClient, multicall: Multicall) {
        self.logsRPC = logsRPC
        self.multicall = multicall
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// The NFTs the wallet holds now, newest first, at most `limit` resolved.
    public func heldNFTs(wallet: Address, limit: Int = 120) async -> [NFTAsset] {
        guard let anchor = try? await logsRPC.block(.latest) else { return [] }
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        let incoming = await logsRPC.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: 0, toBlock: anchor.number)

        struct Candidate: Hashable { let contract: Address; let tokenId: BigUInt }
        var seen = Set<Candidate>()
        var candidates: [Candidate] = []
        // ERC-721 indexes the token id: four topics and no data. ERC-20 transfers share the signature but not the shape.
        for log in incoming.sorted(by: { $0.blockNumber > $1.blockNumber }) where log.topics.count == 4 {
            let candidate = Candidate(contract: log.address, tokenId: BigUInt(log.topics[3]))
            if seen.insert(candidate).inserted { candidates.append(candidate) }
        }
        guard !candidates.isEmpty else { return [] }

        // Still owned by the wallet? A transferred-away or burned token reverts or names another owner.
        var owned: [Candidate] = []
        var index = 0
        while index < candidates.count, owned.count < limit {
            let batch = Array(candidates[index ..< min(index + 120, candidates.count)])
            index += batch.count
            guard let calls = try? batch.map({ try ERC721.ownerOf($0.contract, $0.tokenId) }), let results = try? await multicall.read(calls) else { continue }
            for (candidate, result) in zip(batch, results) {
                if case .success(let values) = result, let owner = values.first?.address, owner == wallet { owned.append(candidate) }
            }
        }
        guard !owned.isEmpty else { return [] }

        let slice = Array(owned.prefix(limit))
        guard let calls = try? slice.flatMap({ [try ERC721.name($0.contract), try ERC721.tokenURI($0.contract, $0.tokenId)] }),
              let results = try? await multicall.read(calls) else { return [] }
        func text(_ i: Int) -> String { if case .success(let values) = results[i] { return values.first?.stringOrNil ?? "" } else { return "" } }

        return await withTaskGroup(of: (Int, NFTAsset).self, returning: [NFTAsset].self) { group in
            for (i, candidate) in slice.enumerated() {
                let collection = text(i * 2)
                let uri = text(i * 2 + 1)
                group.addTask {
                    let metadata = uri.isEmpty ? nil : await NFTMetadata.resolve(tokenURI: uri)
                    let fallback = "\(collection.isEmpty ? candidate.contract.short : collection) #\(candidate.tokenId)"
                    return (i, NFTAsset(contract: candidate.contract, tokenId: candidate.tokenId, collection: collection,
                                        name: metadata?.name ?? fallback, imageURL: metadata?.image, animationURL: metadata?.animation))
                }
            }
            var indexed: [(Int, NFTAsset)] = []
            for await item in group { indexed.append(item) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
