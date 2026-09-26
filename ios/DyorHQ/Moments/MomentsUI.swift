import BigInt
import DyorKit
import SwiftUI

// Shared pieces of the Moments screens: artwork, state badges, the discovery card, number formatting.

/// A Moment's media: the image behind its `mediaURI`, or a monogram on the brand tint when there is none or it
/// fails to load. Loading tries every source in order — the Supabase mirror derived from on-chain provenance when
/// the creator is known, then each IPFS gateway — so a gateway that is rate-limiting (ipfs.io and dweb.link answer
/// 429 freely) never leaves a Moment blank while another source has the bytes.
struct MomentArtwork: View {
    let provenance: MomentProvenance
    let symbol: String
    /// The Moment's creator, when known: unlocks the derived Supabase mirror as the first source.
    var creator: Address? = nil
    @State private var image: UIImage?
    @State private var failed = false

    private var sources: [MomentImageSource] { MomentMediaLoader.imageSources(provenance: provenance, creator: creator) }

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed || sources.isEmpty { placeholder }
            else { Color(.tertiarySystemFill); ProgressView().controlSize(.small) }
        }
        .task(id: provenance.mediaURI + "|" + (creator?.hex ?? "")) { await load() }
    }

    private func load() async {
        let sources = self.sources
        guard !sources.isEmpty else { return }
        // The cache is keyed by everything the sources depend on, not the pointer alone: `mediaURI` is not unique, so
        // another Moment reusing this CID with its own hash and mirror must never fill this Moment's entry.
        let key = [provenance.mediaURI, creator?.hex ?? "", provenance.mediaHash.map { String(format: "%02x", $0) }.joined()].joined(separator: "|")
        if let cached = MomentMediaLoader.shared.cached(key) { image = cached; failed = false; return }
        image = nil; failed = false
        let loaded = await MomentMediaLoader.shared.load(key: key, sources: sources)
        guard !Task.isCancelled else { return }
        if let loaded { image = loaded } else { failed = true }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.allocationMoments.opacity(0.35), Color.brand.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(symbol.prefix(2).uppercased())
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brand)
        }
    }
}

/// One place to look for a Moment's image. `keccak`, when set, is what the downloaded bytes must hash to (the Moment's
/// on-chain provenance hash); a source whose bytes don't match is skipped like a failed one.
struct MomentImageSource: Sendable {
    let url: URL
    var keccak: Data? = nil
}

/// Fetches Moment images from an ordered list of sources and remembers the outcome per media URI for the session —
/// hits for good, misses for a minute — so a feed neither re-downloads an image on every scroll nor re-probes a dead
/// link (an unrecoverable directory CID, say) on every appearance. One in-flight fetch is shared by every view
/// showing the same Moment.
@MainActor
final class MomentMediaLoader {
    static let shared = MomentMediaLoader()
    private let images = NSCache<NSString, UIImage>()
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Where to look for a Moment's image, best first. The Supabase mirror derived from the creator + media hash (only
    /// meaningful for an `ipfs://` pointer — an https pointer *is* the mirror) is an object its creator can overwrite
    /// after publishing, so it is never trusted blindly:
    /// - a photo Moment's provenance hash is the keccak-256 of the very JPEG in the mirror, so the mirror goes first (it
    ///   is fast and DyorHQ-run) but its bytes count only while they still match that hash;
    /// - a video Moment's hash is the video's, while the mirror holds its poster frame, which cannot be checked — so the
    ///   content-addressed IPFS copy goes first and the mirror is only the last fallback.
    static func imageSources(provenance: MomentProvenance, creator: Address?) -> [MomentImageSource] {
        let gateways = MomentsMath.gatewayURLs(provenance.mediaURI).map { MomentImageSource(url: $0) }
        guard let creator,
              let mirror = MomentsMath.mirrorURL(creator: creator, mediaHash: provenance.mediaHash, supabaseURL: AppConfig.current.supabaseURL) else {
            return gateways
        }
        guard provenance.mediaURI.lowercased().hasPrefix("ipfs://") else {
            // An https pointer that is this photo's own mirror (published when pinning failed) is checked the same way.
            if provenance.animationURI.isEmpty, gateways.count == 1, gateways[0].url == mirror {
                return [MomentImageSource(url: mirror, keccak: provenance.mediaHash)]
            }
            return gateways
        }
        if provenance.animationURI.isEmpty {
            return [MomentImageSource(url: mirror, keccak: provenance.mediaHash)] + gateways
        }
        return gateways + [MomentImageSource(url: mirror)]
    }

    func cached(_ key: String) -> UIImage? { images.object(forKey: key as NSString) }

    func load(key: String, sources: [MomentImageSource]) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 60 { return nil }
        if let task = inFlight[key] { return await task.value }
        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) { // decode off the main thread
            for source in sources {
                guard let (data, response) = try? await session.data(from: source.url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      source.keccak.map({ Keccak.hash256(data) == $0 }) ?? true, // a swapped mirror falls through to IPFS
                      let image = UIImage(data: data) else { continue } // an HTML directory listing never decodes
                return image
            }
            return nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { images.setObject(result, forKey: key as NSString); misses[key] = nil } else { misses[key] = Date() }
        return result
    }
}

/// Where a Moment is in its life: collecting (with the time left), window closed, graduation pending, graduated,
/// expired. Colour never stands alone — the word is always there.
struct MomentStateBadge: View {
    let info: MomentInfo
    let now: Int
    /// On top of a photo the badge sits on a material so it stays legible whatever the image.
    var onMedia = false

    private var text: String {
        switch info.state {
        case .collecting:
            if now >= info.moment.deadline { return "Window closed" }
            return onMedia ? MomentsFormat.countdown(info.secondsLeft(at: now), short: true) : "Collecting · \(MomentsFormat.countdown(info.secondsLeft(at: now)))"
        case .graduationPending: return "Graduation pending"
        case .graduated: return "Graduated"
        case .expired: return "Expired"
        }
    }

    private var tint: Color {
        switch info.state {
        case .collecting: return now >= info.moment.deadline ? .secondary : .brand
        case .graduationPending: return .attention
        case .graduated: return .positive
        case .expired: return .secondary
        }
    }

    private var symbol: String {
        switch info.state {
        case .collecting: return now >= info.moment.deadline ? "clock.badge.xmark" : "clock"
        case .graduationPending: return "hourglass"
        case .graduated: return "checkmark.seal.fill"
        case .expired: return "xmark.circle"
        }
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if onMedia { Capsule().fill(.regularMaterial) } else { Capsule().fill(tint.opacity(0.14)) }
            }
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A discovery-grid card: square media with the state badge, then name, ticker, the collect price and progress.
struct MomentCard: View {
    let info: MomentInfo
    let now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator) }
                    .clipped()
                MomentStateBadge(info: info, now: now, onMedia: true).padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(info.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        // A graduated coin's per-unit price is a tiny fraction of a cent; the fully diluted value reads better in a card.
                        Text(info.graduated ? "FDV" : "Per edition").font(.caption2).foregroundStyle(.secondary)
                        Text(info.graduated ? MomentsFormat.usd(info.pool?.fdvUSD ?? 0) : MomentsFormat.usdc(info.moment.price))
                            .font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Editions").font(.caption2).foregroundStyle(.secondary)
                        Text("\(info.editions)").font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                }
                if !info.graduated, info.state != .expired {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                                Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, Double(info.progressBps) / 10_000), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text("\(info.progressBps / 100)% to graduation").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Number formatting shared by the Moments screens.
enum MomentsFormat {
    /// USDC units as dollars, e.g. "$1.00".
    static func usdc(_ units: BigUInt) -> String {
        MomentsMath.usdc(units).formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
    }

    /// Whole coins, compact, e.g. "3.86M".
    static func coins(_ wei: BigUInt) -> String { NumberStyle.number(MomentsMath.coins(wei), compact: true) }

    /// A coin's dollar price with enough precision for small numbers (three significant digits).
    static func coinPrice(_ usd: Double) -> String {
        guard usd > 0 else { return "—" }
        return usd.formatted(.currency(code: "USD").precision(.significantDigits(2...3)))
    }

    /// A dollar amount, compact ("US$25.9", "US$1.2K").
    static func usd(_ value: Double) -> String {
        if value >= 1_000 { return "US$" + NumberStyle.number(value, compact: true) }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 2...4 : 0...2)))
    }

    /// A valuation stated in full ("$2,000", never "US$2K"): the graduation FDV is a number people quote exactly.
    static func fdv(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 100 ? 2 : 0)))
    }

    /// "2d 3h left", "45m left", "closed"; `short` drops the word for tight spaces ("2d 3h").
    static func countdown(_ seconds: Int, short: Bool = false) -> String {
        guard seconds > 0 else { return "closed" }
        let suffix = short ? "" : " left"
        if seconds < 3_600 { return "\(max(1, seconds / 60))m" + suffix }
        if seconds < 86_400 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" + suffix }
        return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h" + suffix
    }

    static func date(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .long, time: .omitted)
    }
}

/// The unix time now, refreshed every second, for countdowns and vesting math.
@Observable
@MainActor
final class Clock {
    private(set) var now = Int(Date().timeIntervalSince1970)
    func run() async {
        while !Task.isCancelled {
            now = Int(Date().timeIntervalSince1970)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// Both wallets the app can sign with provide the raw-digest signature a Permit2 collect needs.
extension LocalWallet: MomentsPermitSigner {}
extension PrivyWallet: MomentsPermitSigner {}
