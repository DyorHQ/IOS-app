import BigInt
import Foundation

/// A Moment's public link: what the Share button sends, and what a tapped link hands the app.
///
/// The link carries the Moment's name: `https://dyorhq.fun/moments/bitcoin-diva`. Names aren't unique, so the first
/// Moment published under a name gets it plain and later ones `-2`, `-3`… (`MomentSlug`). Names and the publish order
/// are fixed on chain, so a link never starts pointing at another Moment. `dyorhq.fun/moments/*` is a universal link:
/// with the app installed it opens the Moment in the app, anywhere else the website's Moments page. The Moments' own
/// id form is read too — the NFTs' on-chain `external_url` (`https://dyorhq.fun/moments/[c1/|c2/]<id>`) — and so is
/// the app scheme (`dyorhq://moments/<name or [cN/]id>`, for testing; never shared).
///
/// A link only navigates. Parsing yields a name or a `MomentKey`, nothing else (no amount, action or address); a name
/// resolves through `MomentDirectory` against the chain, and an id's factory comes from the pinned cohort table, never
/// from a live read. Parsing is strict and alias-free: exact host, `https` only, no userinfo, port 443 or none, the
/// percent-encoded path (`%31` is not `1`), ASCII only; the query and fragment are ignored and never acted on.
public struct MomentLink: Hashable, Identifiable, Sendable, CustomStringConvertible {
    /// What a link names: a Moment by its name (the shared form) or by (factory, id) (the on-chain form).
    public enum Target: Hashable, Sendable {
        case name(String)
        case key(MomentKey)
    }

    /// The Moments cohorts, in the order they were published — the order `MomentSlug` gives out names in, so it must
    /// never change: a new cohort goes at the end. `rawValue` is the path segment each factory put in its NFTs'
    /// `external_url` (read on chain 2026-09-27: cohort 1 `…/moments/c1/`, cohort 2 `…/moments/c2/`, cohort 3
    /// `…/moments/`). `MomentLinkTests` pins the table to `MomentsAddresses`.
    public enum Cohort: String, CaseIterable, Sendable {
        case c1 = "c1", c2 = "c2", live = ""

        public var factory: Address {
            switch self {
            case .c1: return Address(literal: "0x64698c7702d85F87f43a6dFF7D495CDD2327C020")
            case .c2: return Address(literal: "0xc12B6b6948185cef75F861c5327702c30CB8a581")
            case .live: return Address(literal: "0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26")
            }
        }

        public var isRetired: Bool { self != .live }

        /// The cohort a factory belongs to, or nil for an address that is not a Moments factory the app knows.
        public init?(factory: Address) {
            guard let known = Self.allCases.first(where: { $0.factory == factory }) else { return nil }
            self = known
        }

        var pathPrefix: String { self == .live ? "" : rawValue + "/" }
    }

    /// The host of Moment links (`applinks:` in the entitlement; the website serves the association file).
    public static let host = "dyorhq.fun"
    /// The app's own URL scheme (`CFBundleURLSchemes`); Moment links use the host `moments` under it.
    public static let scheme = "dyorhq"
    /// Ids are per-factory counters; anything longer is not a Moment.
    public static let maxIdDigits = 18

    public let target: Target

    public var id: Target { target }
    public var description: String { url.absoluteString }

    /// The link to share: `https://dyorhq.fun/moments/<name>`, or the id form for a Moment known only by its key.
    public var url: URL { URL(string: "https://\(Self.host)/moments/\(path)")! }
    /// The app-scheme form. Any app can claim the scheme, so it is only ever a test hook.
    public var appURL: URL { URL(string: "\(Self.scheme)://moments/\(path)")! }

    private var path: String {
        switch target {
        case .name(let name): return name
        case .key(let key): return (Cohort(factory: key.factory)?.pathPrefix ?? "") + String(key.id)
        }
    }

    /// A link by name; nil unless `name` is a well-formed slug (`MomentSlug.isValid`).
    public init?(name: String) {
        guard MomentSlug.isValid(name) else { return nil }
        target = .name(name)
    }

    /// A link by (factory, id), for a cohort the app knows.
    public init?(key: MomentKey) {
        guard Cohort(factory: key.factory) != nil, Self.isValidId(key.id) else { return nil }
        target = .key(key)
    }

    public init?(cohort: Cohort, id: BigUInt) {
        self.init(key: MomentKey(factory: cohort.factory, id: id))
    }

    /// Parses a link the app was handed. Everything that isn't exactly one of the accepted shapes is nil: never a guess.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil else { return nil }
        let host = parts.host?.lowercased() ?? ""
        // The percent-encoded path, so "%31" cannot alias "1"; empty segments are kept, so "//1" is rejected below.
        var segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "" else { return nil }
        segments.removeFirst()
        switch parts.scheme?.lowercased() {
        case "https":
            guard host == Self.host, parts.port == nil || parts.port == 443, segments.first == "moments" else { return nil }
            segments.removeFirst()
        case Self.scheme:
            guard host == "moments", parts.port == nil else { return nil }
        default:
            return nil
        }
        if segments.last == "" { segments.removeLast() } // one trailing slash
        switch segments.count {
        case 1:
            let segment = String(segments[0])
            if let id = Self.parseId(segments[0]) {
                target = .key(MomentKey(factory: Cohort.live.factory, id: id))
            } else if MomentSlug.isValid(segment.lowercased()) {
                target = .name(segment.lowercased())
            } else {
                return nil
            }
        case 2:
            guard let cohort = Cohort(rawValue: String(segments[0])), cohort.isRetired, let id = Self.parseId(segments[1]) else { return nil }
            target = .key(MomentKey(factory: cohort.factory, id: id))
        default:
            return nil
        }
    }

    /// Whether a URL is addressed to DyorHQ's Moments at all, parsable or not: the website's Moments paths, or the app
    /// scheme's `moments` host. Privy's OAuth callback on the same scheme is not.
    public static func isOurs(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let host = parts.host?.lowercased() ?? ""
        switch parts.scheme?.lowercased() {
        case "https": return host == Self.host && parts.percentEncodedPath.hasPrefix("/moments")
        case Self.scheme: return host == "moments"
        default: return false
        }
    }

    /// A canonical decimal id: ASCII digits only (`Character.isNumber` would take "١" or "²"), no leading zero, at most
    /// `maxIdDigits`, greater than zero.
    static func parseId(_ text: Substring) -> BigUInt? {
        guard !text.isEmpty, text.count <= maxIdDigits, text.first != "0",
              text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return BigUInt(String(text))
    }

    static func isValidId(_ id: BigUInt) -> Bool { id > 0 && String(id).count <= maxIdDigits }
}

/// The readable part of a Moment's link, made from its name, and the rule that keeps every one unique.
///
/// `base` is deterministic on every device and OS version: compatibility decomposition (NFKD, which Unicode's
/// stability policy fixes for every assigned character: "é" → "e" + accent, "ﬁ" → "fi", fullwidth → ASCII), the
/// combining accents U+0300–U+036F dropped, ASCII letters lowercased, every other run of characters one "-", trimmed,
/// at most `maxBase` characters. A name with no ASCII letter ("2024", "🔥🔥") gets a "moment-" prefix, so a name is
/// never mistaken for an id; an empty result is "moment".
public enum MomentSlug {
    public static let maxBase = 60
    /// The longest well-formed slug: a base plus a "-<n>" suffix.
    public static let maxLength = 80

    public static func base(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.decomposedStringWithCompatibilityMapping.unicodeScalars {
            let v = scalar.value
            if (0x300...0x36F).contains(v) { continue } // combining accents: "é" folds to "e"
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append((0x41...0x5A).contains(v) ? Unicode.Scalar(v + 0x20)! : scalar)
            } else {
                pendingDash = true
            }
        }
        if out.count > maxBase {
            out = String(out.prefix(maxBase))
            while out.hasSuffix("-") { out.removeLast() }
        }
        if out.isEmpty { return "moment" }
        if !out.unicodeScalars.contains(where: { (0x61...0x7A).contains($0.value) }) { return "moment-" + out }
        return out
    }

    /// Gives every Moment its slug, in publish order (`names` must be every Moment, oldest first: cohort by cohort in
    /// `MomentLink.Cohort` order, ids ascending). The first Moment with a base gets it plain; a later one gets the first
    /// free "<base>-2", "<base>-3"… Each slug depends only on the Moments before it, so publishing more never changes
    /// an existing one.
    public static func assign(_ names: [(key: MomentKey, name: String)]) -> [MomentKey: String] {
        var taken = Set<String>()
        var slugs: [MomentKey: String] = [:]
        for (key, name) in names {
            let base = self.base(name)
            var slug = base
            var n = 2
            while taken.contains(slug) {
                slug = "\(base)-\(n)"
                n += 1
            }
            taken.insert(slug)
            slugs[key] = slug
        }
        return slugs
    }

    /// Well-formed: lowercase ASCII letters and digits in "-"-joined runs, at most `maxLength`, with at least one letter.
    public static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.utf8.count <= maxLength, !slug.hasPrefix("-"), !slug.hasSuffix("-"), !slug.contains("--") else { return false }
        var letter = false
        for byte in slug.utf8 {
            switch byte {
            case 0x61...0x7A: letter = true
            case 0x30...0x39, 0x2D: break
            default: return false
            }
        }
        return letter
    }
}

/// What to do with a Moment link that arrived, given where the app is. The link waits (on the App-level Router, which
/// outlives sign-in) until a state that may navigate; it is dropped under the update gate, where nothing that signs may
/// be reachable (GP-2); and it never tears down a running or open confirmation. Pure, so every row is a test.
public enum MomentLinkGate {
    public enum Phase: Hashable, Sendable {
        /// The session hasn't answered yet (a cold start lands here).
        case loading
        case signedOut
        case signedIn
    }

    public enum Decision: Hashable, Sendable {
        /// Keep the link; a later state change decides.
        case hold
        /// Keep it, and tell the person signing in that it is waiting.
        case banner
        /// Forget it.
        case drop
        /// Open the Moment now.
        case deliver
    }

    /// - Parameters:
    ///   - updateRequired: the build is below the minimum (`UpdateGate.required`).
    ///   - deletionScreen: the account-deleted or deletion-notice screen is up (shown before onboarding).
    ///   - busy: a confirmation sheet is on screen, or an approved action is still signing or sending.
    public static func decide(phase: Phase, updateRequired: Bool, deletionScreen: Bool, busy: Bool) -> Decision {
        switch phase {
        case .loading:
            return .hold
        case .signedOut:
            if deletionScreen { return .hold }
            return updateRequired ? .drop : .banner
        case .signedIn:
            if updateRequired { return .drop }
            return busy ? .hold : .deliver
        }
    }
}

/// Every Moment's name, read from the chain in publish order, turned into link slugs (`MomentSlug.assign`). Retired
/// cohorts are final and read once; the live cohort is re-counted when a lookup needs newer Moments. Nothing is kept
/// across launches, and a read that fails anywhere fails the whole lookup: a missing name would shift the slugs after it.
public actor MomentDirectory {
    private let multicall: Multicall
    private let cohorts: [MomentLink.Cohort]
    private var names: [MomentLink.Cohort: [String]] = [:]
    private var counted: [MomentLink.Cohort: Date] = [:]
    private var refreshing: Task<Void, Error>?
    /// How long a count of the live cohort is trusted before a lookup reads it again.
    private let liveTTL: TimeInterval

    public init(rpc: RPCClient, cohorts: [MomentLink.Cohort] = MomentLink.Cohort.allCases, liveTTL: TimeInterval = 20) {
        multicall = Multicall(rpc: rpc)
        self.cohorts = cohorts
        self.liveTTL = liveTTL
    }

    /// The Moment a name link means, or nil when no Moment has that slug.
    public func key(for slug: String) async throws -> MomentKey? {
        if let hit = table().bySlug[slug] { return hit }
        try await refresh(force: true)
        return table().bySlug[slug]
    }

    /// The link to share for a Moment: its name form, or nil when the Moment isn't (yet) in the directory.
    public func link(for key: MomentKey) async throws -> MomentLink? {
        if let slug = table().byKey[key] { return MomentLink(name: slug) }
        try await refresh(force: true)
        return table().byKey[key].flatMap(MomentLink.init(name:))
    }

    private func table() -> (bySlug: [String: MomentKey], byKey: [MomentKey: String]) {
        var ordered: [(key: MomentKey, name: String)] = []
        for cohort in cohorts {
            for (i, name) in (names[cohort] ?? []).enumerated() {
                ordered.append((MomentKey(factory: cohort.factory, id: BigUInt(i + 1)), name))
            }
        }
        let byKey = MomentSlug.assign(ordered)
        var bySlug: [String: MomentKey] = [:]
        for (key, slug) in byKey { bySlug[slug] = key }
        return (bySlug, byKey)
    }

    /// Reads the names of Moments not read yet. One refresh at a time; a caller arriving meanwhile waits for it.
    private func refresh(force: Bool) async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.readNewNames(force: force) }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func readNewNames(force: Bool) async throws {
        let now = Date()
        // Counts first, for every cohort that may have grown: a retired cohort once, the live one when stale.
        let stale = cohorts.filter { cohort in
            guard let at = counted[cohort] else { return true }
            return !cohort.isRetired && (force || now.timeIntervalSince(at) > liveTTL)
        }
        guard !stale.isEmpty else { return }
        let counts = try await multicall.readAll(stale.map { MomentsABI.call($0.factory, MomentsABI.Factory.momentCount, returns: "uint256") })
        var wanted: [(cohort: MomentLink.Cohort, id: BigUInt)] = []
        for (cohort, value) in zip(stale, counts) {
            let count = value[0].uint
            let have = BigUInt(names[cohort]?.count ?? 0)
            if count > have { for id in (have + 1)...count { wanted.append((cohort, id)) } }
        }
        if !wanted.isEmpty {
            let moments = try await multicall.readAll(wanted.map { MomentsABI.call($0.cohort.factory, MomentsABI.Factory.getMoment, [.uint($0.id)], returns: MomentsABI.momentTuple) })
            let coins = zip(wanted, moments).map { MomentsABI.moment(id: $0.id, $1[0], factory: $0.cohort.factory).coin }
            let read = try await multicall.readAll(coins.map { MomentsABI.call($0, MomentsABI.Coin.name, returns: "string") })
            // Appended in id order per cohort: `wanted` is ascending within each cohort.
            for (entry, value) in zip(wanted, read) { names[entry.cohort, default: []].append(value[0].string) }
        }
        for cohort in stale { counted[cohort] = now }
    }
}
