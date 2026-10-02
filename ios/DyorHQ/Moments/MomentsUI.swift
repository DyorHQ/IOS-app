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
        .accessibilityIgnoresInvertColors()
    }

    private func load() async {
        let sources = self.sources
        guard !sources.isEmpty else { return }
        let key = Self.cacheKey(provenance: provenance, creator: creator)
        if let cached = MomentMediaLoader.shared.cached(key) { image = cached; failed = false; return }
        image = nil; failed = false
        let loaded = await MomentMediaLoader.shared.load(key: key, sources: sources)
        guard !Task.isCancelled else { return }
        if let loaded { image = loaded } else { failed = true }
    }

    /// The media cache's key for a Moment's image: everything the sources depend on, not the pointer alone. `mediaURI`
    /// is not unique, so another Moment reusing this CID with its own hash and mirror must never fill this Moment's
    /// entry. The Share button uses it to offer the artwork already on screen as the share preview.
    static func cacheKey(provenance: MomentProvenance, creator: Address?) -> String {
        [provenance.mediaURI, creator?.hex ?? "", provenance.mediaHash.map { String(format: "%02x", $0) }.joined()].joined(separator: "|")
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.allocationMoments.opacity(0.35), Color.brand.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 36 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 36. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(ChainText.leading(symbol, 2).uppercased())
                    .font(.system(size: min(36, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
/// hits under a memory budget, misses for a minute — so a feed neither re-downloads an image on every scroll nor
/// re-probes a dead link (an unrecoverable directory CID, say) on every appearance. One in-flight fetch is shared by
/// every view showing the same Moment, and cancelled once none of them is on screen. Media URIs are written on-chain by
/// whoever publishes, so each fetch is capped, fetches and decodes run a few at a time app-wide, and only a thumbnail
/// is decoded (`RemoteMedia`, security audit 2026-09-26, RI-5).
@MainActor
final class MomentMediaLoader {
    static let shared = MomentMediaLoader()
    /// The longest side, in pixels, a Moment image is decoded at: the full-width detail artwork on a 3x screen.
    static let maxPixelSize = 1200
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private var misses: [String: Date] = [:]
    private let loads = SharedLoads<UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Where to look for a Moment's image, best first, through `ImageSourcePolicy` (`momentSources`), as a Moment coin's
    /// icon loads it: only DyorHQ's `launch-media` bucket and the fixed IPFS gateways, never a host the creator chose
    /// (another https link shows the placeholder). The Supabase mirror derived from the creator + media hash is a
    /// DyorHQ-hosted object, so it is never shown on trust (security audit 2026-09-26, PR-2):
    /// - a photo Moment's provenance hash is the keccak-256 of the very JPEG in the mirror, so the mirror goes first (it
    ///   is fast and DyorHQ-run) but its bytes count only while they still match that hash;
    /// - a video Moment's hash is the video's, while the mirror holds its poster frame, which nothing on-chain can check
    ///   — so the mirror is not a source at all, and the image comes from the content-addressed IPFS pointer only.
    ///   That includes a video Moment whose on-chain image IS that mirror (earlier builds wrote it when pinning failed):
    ///   it shows the placeholder, since until the bucket is write-once (supabase migration 26) the creator can swap
    ///   those bytes.
    /// Without a creator there is no mirror to derive: the pointer alone, held to the same hosts.
    static func imageSources(provenance: MomentProvenance, creator: Address?) -> [MomentImageSource] {
        let policy = ImageSourcePolicy.app
        guard let creator else { return policy.creatorSources(provenance.mediaURI).map { MomentImageSource(url: $0) } }
        return policy.momentSources(mediaURI: provenance.mediaURI, mediaHash: provenance.mediaHash, isVideo: !provenance.animationURI.isEmpty, creator: creator)
            .map { MomentImageSource(url: $0.url, keccak: $0.keccak) }
    }

    func cached(_ key: String) -> UIImage? { images.object(forKey: key as NSString) }

    /// Forgets every image and every miss (account deletion).
    func removeAll() {
        images.removeAllObjects()
        misses = [:]
    }

    func load(key: String, sources: [MomentImageSource]) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 60 { return nil }
        let session = self.session
        let maxPixelSize = Self.maxPixelSize
        let caps = RemoteMedia.caps(forThumbnail: maxPixelSize)
        let result = await loads.value(for: key) { // fetched and decoded off the main thread
            for source in sources {
                guard !Task.isCancelled else { return nil }
                guard let data = try? await RemoteMedia.fetches.run({ try await RemoteMedia.fetch(source.url, session: session, maxBytes: caps.maxBytes) }),
                      source.keccak.map({ Keccak.hash256(data) == $0 }) ?? true, // a swapped mirror falls through to IPFS
                      let image = try? await RemoteMedia.decodes.run({ // an HTML directory listing never decodes
                          UIImage(cgImage: try RemoteMedia.thumbnail(data, maxPixelSize: maxPixelSize, maxSourcePixels: caps.maxSourcePixels))
                      }) else { continue }
                return image
            }
            return nil
        }
        if let result {
            images.setObject(result, forKey: key as NSString, cost: RemoteImageLoader.cost(result))
            misses[key] = nil
        } else if !Task.isCancelled {
            misses[key] = Date()
        }
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

    /// The badge's words, in the app's language.
    private var text: String {
        switch info.state {
        case .collecting:
            if now >= info.moment.deadline { return tr(LocalizedStringResource("Window closed", comment: "[tight] Moment badge: its collect window has closed")) }
            let left = MomentsFormat.countdown(info.secondsLeft(at: now), short: onMedia)
            return onMedia ? left : tr(LocalizedStringResource("Collecting · \(left)", comment: "[tight] Moment badge: still collecting, then the time left (\"2d 3h left\")"))
        case .graduationPending: return tr(LocalizedStringResource("Graduation pending", comment: "[tight] Moment badge: its graduation has not completed yet"))
        case .graduated: return tr(LocalizedStringResource("Graduated", comment: "[tight] Moment badge: its coin graduated into a pool"))
        case .expired: return tr(LocalizedStringResource("Expired", comment: "[tight] Moment badge: it expired before graduating"))
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
                    Text(verbatim: "$\(info.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        // A graduated coin's per-unit price is a tiny fraction of a cent; the fully diluted value reads better in a card.
                        (info.graduated ? Text("FDV", comment: "[tight] Moment card: fully diluted valuation") : Text("Per edition", comment: "[tight] Moment card: the price of one edition"))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(info.graduated ? MomentsFormat.usd(info.pool?.fdvUSD ?? 0) : MomentsFormat.usdc(info.moment.price))
                            .font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Editions", comment: "[tight] Moment card: how many editions were collected").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: "\(info.editions)").font(.footnote.weight(.semibold)).monospacedDigit()
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
                        Text("\(String(info.progressBps / 100))% to graduation", comment: "[tight] Moment card: how far the reserve is toward graduation")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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

/// Number formatting shared by the Moments screens, in the app's one dollar style (`PriceFormat`).
enum MomentsFormat {
    /// USDC units as dollars with every decimal kept (up to 6), e.g. "$1.00", "$0.123456": for amounts that must be
    /// exact, like what a collect pays and approves.
    static func usdc(_ units: BigUInt) -> String {
        PriceFormat.usdValue(MomentsMath.usdc(units), fractionDigits: 2...6)
    }

    /// USDC units rounded to the cent, e.g. "$771.43": for the reserve, the graduation threshold and what is still needed,
    /// which a policy can set to a sixth decimal (771.428571 USDC for cohort 4). Under half a cent but not zero reads
    /// "<$0.01".
    static func usdcCents(_ units: BigUInt) -> String {
        PriceFormat.usdValue(MomentsMath.usdc(units))
    }

    /// Whole coins, compact, e.g. "3.86M".
    static func coins(_ wei: BigUInt) -> String { NumberStyle.number(MomentsMath.coins(wei), compact: true) }

    /// A coin's dollar price (`PriceFormat.usdPrice`: "$0.0₆1234" for a tiny one), "—" when there is none. VoiceOver
    /// reads `coinPriceSpoken`.
    static func coinPrice(_ usd: Double) -> String {
        guard usd > 0 else { return "—" }
        return PriceFormat.usdPrice(usd)
    }

    /// `coinPrice` with every zero written out, for VoiceOver.
    static func coinPriceSpoken(_ usd: Double) -> String {
        guard usd > 0 else { return "—" }
        return PriceFormat.spoken(usd)
    }

    /// A dollar amount, compact ("$25.90", "$1.2K").
    static func usd(_ value: Double) -> String {
        PriceFormat.usdValue(value, compact: true)
    }

    /// A valuation stated in full ("$2,000", never "$2K"): the graduation FDV is a number people quote exactly.
    static func fdv(_ value: Double) -> String {
        PriceFormat.usdValue(value, fractionDigits: value < 100 ? 2...2 : 0...0)
    }

    /// "2d 3h left", "45m left", "closed"; `short` drops the word for tight spaces ("2d 3h"). The units are the system's
    /// narrow ones in the app's language ("2j 3h" in French), whole units only: minutes under an hour (at least one),
    /// hours and minutes under a day, then days and hours.
    static func countdown(_ seconds: Int, short: Bool = false) -> String {
        guard seconds > 0 else { return tr(LocalizedStringResource("closed", comment: "[tight] A Moment's collect window: it has closed")) }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 3_600 ? [.minutes] : seconds < 86_400 ? [.hours, .minutes] : [.days, .hours]
        let time = Duration.seconds(max(60, seconds)).formatted(remaining(units))
        return short ? time : tr(LocalizedStringResource("\(time) left", comment: "[tight] The time left to collect a Moment (\"2d 3h left\")"))
    }

    /// The countdown's style: narrow units in the app's language, a zero unit still shown ("1h 0m"), never rounded up.
    static func remaining(_ units: Set<Duration.UnitsFormatStyle.Unit>) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(allowedUnits: units, width: .narrow, zeroValueUnits: .show(length: 1), fractionalPart: .hide(rounded: .down)).locale(L10n.locale)
    }

    /// A day and time ("Oct 1, 2026 at 9:41 AM"), in the app's language.
    static func date(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return date(Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }

    /// A day ("October 1, 2026"), in the app's language.
    static func day(_ unix: Int) -> String {
        guard unix > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(unix)).formatted(Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale))
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
