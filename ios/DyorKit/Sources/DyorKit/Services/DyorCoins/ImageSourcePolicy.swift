import Foundation

/// One place to look for an image. `keccak`, when set, is what the downloaded bytes must hash to (a Moment photo's
/// on-chain provenance hash): a source whose bytes don't match is skipped like a failed one.
public struct RemoteImageSource: Hashable, Sendable {
    public let url: URL
    public let keccak: Data?

    public init(url: URL, keccak: Data? = nil) {
        self.url = url
        self.keccak = keccak
    }
}

/// Which hosts a coin's picture may be loaded from (security audit 2026-09-26, RI-5 area; pick 6, decision 10). Loading
/// an image tells its host the viewer's IP address and when they looked, so a coin's picture never loads from a host its
/// creator chose. A picture written on chain by whoever made a coin — a launch token's logo, a Moment's media — is loaded
/// only from infrastructure DyorHQ runs or content-addressed storage:
///
/// - DyorHQ's write-once `launch-media` bucket (`https://<project>.supabase.co/storage/v1/object/public/launch-media/…`),
///   where the app uploads every launch image and Moment mirror, as it is;
/// - IPFS, in any form (`IPFS.path`) — `ipfs://<cid>[/…]`, `https://<any host>/ipfs/<cid>[/…]`,
///   `https://<cid>.ipfs.<host>/[…]` — with a real CID (`IPFS.isCID`), always rewritten onto the app's fixed gateways
///   (`MomentsMath.ipfsGateways`, DyorHQ's dedicated one first), never the host the creator named.
///
/// Anything else — another https host, `http:`, `ar:`, `data:`, `javascript:`, a link over `maxURLBytes` — gives no
/// source, and the coin shows its letters. All seven launches on chain today use `launch-media`, so no picture users see
/// goes away. A logo a token list supplies for a coin that isn't DyorHQ's (`listSources`) loads only from the hosts the
/// app's lists really use (`listHosts`), or else by the rules above. The byte, pixel and decode caps (`RemoteMedia`)
/// apply to every source.
public struct ImageSourcePolicy: Hashable, Sendable {
    /// `https://<project>.supabase.co`: the Supabase project whose `launch-media` bucket is DyorHQ's.
    public let supabaseURL: URL
    /// IPFS gateways, in the order they are tried, each ending in `/ipfs/`.
    public let ipfsGateways: [String]

    public init(supabaseURL: URL, ipfsGateways: [String] = MomentsMath.ipfsGateways) {
        self.supabaseURL = supabaseURL
        self.ipfsGateways = ipfsGateways
    }

    /// DyorHQ's production project, whose bucket every launch and Moment on chain uses (the app's `SupabaseURL`
    /// default), for a picture chosen where no app configuration is at hand (`MomentInfo.coinToken`).
    public static let dyorhq = ImageSourcePolicy(supabaseURL: URL(string: "https://fmnjqrguvopusfufmirs.supabase.co")!)

    /// The longest link any source may be, in UTF-8 bytes: a picture's address is never longer, and a creator's
    /// 100 KB "URL" costs every screen that parses it.
    public static let maxURLBytes = 2_048

    /// The hosts a token list's logo may load from, as the app's lists use them (2026-09-30): Kuru's CDN (almost every
    /// logo in its directory and markets), the logo bucket some of Kuru's rows point at, and nad.fun's storage for its
    /// coins; and the Monad token list's repository (`Token.core`'s logos). Anything else a list or a stored snapshot
    /// holds — a build-16 snapshot of a Moment coin carries its creator's link — is held to the creator rules.
    public static let listHosts: [(host: String, pathPrefix: String)] = [
        ("dsvxs4ecepqgj.cloudfront.net", "/"),
        ("crypto-token-logos-production.s3.us-west-2.amazonaws.com", "/"),
        ("storage.nadapp.net", "/"),
        ("raw.githubusercontent.com", "/monad-crypto/token-list/"),
    ]

    /// The object path every `launch-media` URL starts with.
    static let launchMediaPath = "/storage/v1/object/public/launch-media/"

    // MARK: Creator-written pictures

    /// Where a picture its creator wrote on chain may be loaded from, best first; empty when nowhere (see above).
    public func creatorSources(_ uri: String) -> [URL] {
        switch classify(uri) {
        case .launchMedia(let url): return [url]
        case .ipfs(let path): return ipfsGateways.compactMap { URL(string: $0 + path) }
        case nil: return []
        }
    }

    /// A Moment coin's picture, as the Moments screens load it (`MomentArtwork`), through this policy: for a photo stored
    /// on IPFS, DyorHQ's mirror of it first (found from the creator and the media hash alone, `MomentsMath.mirrorURL`),
    /// kept only while its bytes hash to the on-chain `mediaHash`, then the IPFS gateways; for a video, its poster frame
    /// from the pointer alone, since the mirror's poster is nothing any on-chain hash can check. A pointer that is this
    /// photo's own mirror (published so when pinning failed) is checked the same way, and gives nothing for a video.
    public func momentSources(mediaURI: String, mediaHash: Data?, isVideo: Bool, creator: Address) -> [RemoteImageSource] {
        let kind = classify(mediaURI)
        let pointer = creatorSources(mediaURI).map { RemoteImageSource(url: $0) }
        guard let mediaHash, let mirror = MomentsMath.mirrorURL(creator: creator, mediaHash: mediaHash, supabaseURL: supabaseURL) else { return pointer }
        switch kind {
        case .ipfs:
            return isVideo ? pointer : [RemoteImageSource(url: mirror, keccak: mediaHash)] + pointer
        case .launchMedia(let url) where url.absoluteString == mirror.absoluteString:
            return isVideo ? [] : [RemoteImageSource(url: mirror, keccak: mediaHash)]
        case .launchMedia, nil:
            return pointer
        }
    }

    // MARK: List-supplied logos

    /// Where the logo a token list gave `token` (`Token.logoURL`) may be loaded from: an https URL on one of
    /// `listHosts` (no credentials, no port, under the host's path), or else what the creator rules allow of it —
    /// DyorHQ's bucket or IPFS through the fixed gateways. A launchpad coin's stored logo came from its creator (the
    /// Launch page stores it), so it is held to the creator rules alone.
    public func listSources(for token: Token) -> [URL] {
        guard let url = token.logoURL else { return [] }
        let text = url.absoluteString
        guard text.utf8.count <= Self.maxURLBytes else { return [] }
        if token.isLaunchpad { return creatorSources(text) }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == "https",
           let host = components.host?.lowercased(), components.user == nil, components.password == nil, components.port == nil,
           Self.isCleanPath(components.percentEncodedPath),
           Self.listHosts.contains(where: { $0.host == host && components.percentEncodedPath.hasPrefix($0.pathPrefix) }) {
            return [url]
        }
        return creatorSources(text)
    }

    // MARK: Parsing

    private enum Kind: Equatable {
        /// An object in DyorHQ's `launch-media` bucket, as written.
        case launchMedia(URL)
        /// A CID and the path inside it, to put after a gateway's `/ipfs/`.
        case ipfs(String)
    }

    /// What a creator-written `uri` points at, or nil when it is nothing this policy loads. Strict: at most
    /// `maxURLBytes`, https only (no other scheme, userinfo or port), the exact Supabase host, no `..` or `.` segment, no
    /// encoded slash, dot or backslash, a real CID for IPFS, and the query and fragment of an IPFS link dropped.
    private func classify(_ uri: String) -> Kind? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxURLBytes,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value != 0x7F }) else { return nil }
        if trimmed.lowercased().hasPrefix("ipfs://") {
            let path = IPFS.path(trimmed) ?? ""
            return Self.ipfsPath(String(path.prefix { $0 != "?" && $0 != "#" })).map(Kind.ipfs)
        }
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        let path = components.percentEncodedPath
        guard Self.isCleanPath(path) else { return nil }
        if host == supabaseURL.host?.lowercased(), components.port == nil, path.hasPrefix(Self.launchMediaPath), path.count > Self.launchMediaPath.count,
           components.percentEncodedQuery == nil, components.fragment == nil, let url = URL(string: trimmed) {
            return .launchMedia(url)
        }
        // The path form (/ipfs/<cid>[/…] on any host) or the subdomain form (<cid>.ipfs.<host>/[…]).
        return IPFS.path(components).flatMap(Self.ipfsPath).map(Kind.ipfs)
    }

    /// `<cid>[/path]` when the part before the first slash is a CID (`IPFS.isCID`) and the path is clean; nil otherwise.
    static func ipfsPath(_ cidAndPath: String) -> String? {
        let cid = IPFS.cid(of: cidAndPath)
        guard IPFS.isCID(cid) else { return nil }
        let rest = cidAndPath.dropFirst(cid.count)
        guard rest.isEmpty || isCleanPath(String(rest)) else { return nil }
        return cidAndPath
    }

    /// No `.` or `..` segment, backslash, or percent-encoded slash, dot or backslash: nothing that could step out of the
    /// bucket or the CID once a server decodes it.
    static func isCleanPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard !lower.contains("\\"), !lower.contains("%2f"), !lower.contains("%2e"), !lower.contains("%5c") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }
}
