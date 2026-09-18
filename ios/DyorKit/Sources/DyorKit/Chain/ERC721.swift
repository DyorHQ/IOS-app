import BigInt
import Foundation

/// ERC-721 reads used by wallet asset discovery.
public enum ERC721 {
    public static func ownerOf(_ nft: Address, _ tokenId: BigUInt) throws -> ContractCall {
        try ContractCall(to: nft, "ownerOf(uint256)", [.uint(tokenId)], returns: "address")
    }

    public static func tokenURI(_ nft: Address, _ tokenId: BigUInt) throws -> ContractCall {
        try ContractCall(to: nft, "tokenURI(uint256)", [.uint(tokenId)], returns: "string")
    }

    public static func name(_ nft: Address) throws -> ContractCall { try ContractCall(to: nft, "name()", returns: "string") }
}

/// OpenSea pages for Monad. Item pages are addressed by contract and token id; a collection's own page uses a slug
/// OpenSea assigns, so the collection is reached through its first edition.
public enum OpenSea {
    public static func item(contract: Address, tokenId: BigUInt) -> URL {
        URL(string: "https://opensea.io/item/monad/\(contract.checksummed)/\(tokenId)")!
    }

    public static func collection(contract: Address) -> URL { item(contract: contract, tokenId: 1) }
}

/// One NFT a wallet holds, with what its metadata says about it.
public struct NFTAsset: Identifiable, Hashable, Sendable {
    public let contract: Address
    public let tokenId: BigUInt
    public let collection: String
    public let name: String
    public let imageURL: URL?
    public let animationURL: URL?

    public init(contract: Address, tokenId: BigUInt, collection: String, name: String, imageURL: URL?, animationURL: URL?) {
        self.contract = contract
        self.tokenId = tokenId
        self.collection = collection
        self.name = name
        self.imageURL = imageURL
        self.animationURL = animationURL
    }

    public var id: String { "\(contract.hex)-\(tokenId)" }
    public var openSeaURL: URL { OpenSea.item(contract: contract, tokenId: tokenId) }
}

/// ERC-721 metadata (an on-chain `data:` document or a fetched https / ipfs one), reduced to what the app shows.
public struct NFTMetadata: Sendable {
    public var name: String?
    public var image: URL?
    public var animation: URL?

    public init(name: String? = nil, image: URL? = nil, animation: URL? = nil) {
        self.name = name
        self.image = image
        self.animation = animation
    }

    public static func resolve(tokenURI: String, session: URLSession = .shared) async -> NFTMetadata? {
        let uri = tokenURI.trimmingCharacters(in: .whitespacesAndNewlines)
        var document: Data?
        if uri.lowercased().hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
            let payload = String(uri[uri.index(after: comma)...])
            document = uri[..<comma].lowercased().contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        } else if let url = gatewayURL(uri) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            if let (body, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, body.count <= 512 * 1024 {
                document = body
            }
        }
        guard let document, let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any] else { return nil }
        let image = (object["image"] as? String) ?? (object["image_url"] as? String)
        return NFTMetadata(name: object["name"] as? String, image: image.flatMap(gatewayURL), animation: (object["animation_url"] as? String).flatMap(gatewayURL))
    }

    /// `ipfs://` and `ar://` through public gateways; `https://` as is.
    public static func gatewayURL(_ uri: String) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ipfs://") {
            let path = trimmed.dropFirst("ipfs://".count).replacingOccurrences(of: "ipfs/", with: "", options: [.anchored])
            return URL(string: "https://ipfs.io/ipfs/\(path)")
        }
        if lower.hasPrefix("ar://") { return URL(string: "https://arweave.net/\(trimmed.dropFirst(5))") }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
