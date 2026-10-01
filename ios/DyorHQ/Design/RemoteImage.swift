import DyorKit
import SwiftUI

/// The one way the app shows an image from a host it doesn't control (security audit 2026-09-26, RI-5): coin logos,
/// launch artwork, avatars, NFT art, news thumbnails. Each fetch is capped (`RemoteMedia.fetch`) — tighter for a logo-
/// sized image (`RemoteMedia.caps(forThumbnail:)`) — and only a thumbnail at the size the view asks for is decoded
/// (`RemoteMedia.thumbnail`), never the full image. Fetches and decodes run a few at a time app-wide
/// (`RemoteMedia.fetches` / `.decodes`), so a list of hostile images can't all be in memory at once. Thumbnails are
/// cached for the session under a memory budget, misses for a minute (`RecentMisses`), and one fetch is shared by every
/// view showing the same image — and cancelled once none of them is on screen any more. An image with several sources
/// (a coin's picture: DyorHQ's mirror, then the IPFS gateways, `ImageSourcePolicy`) tries them in order, under the same
/// caps, and the first that decodes wins; one whose bytes must hash to a known value (`RemoteImageSource.keccak`) counts
/// only when they do. Such an image is cached under the whole ordered list.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var misses = RecentMisses()
    private let loads = SharedLoads<UIImage>()
    private let session = RemoteMedia.makeSession()

    /// The cache key of `sources` at `maxPixelSize`: the ordered list, each source's hash included. One plain URL keys as
    /// it always has.
    static func key(_ sources: [RemoteImageSource], _ maxPixelSize: Int) -> String {
        let list = sources.map { source in
            source.url.absoluteString + (source.keccak.map { "#" + $0.map { String(format: "%02x", $0) }.joined() } ?? "")
        }
        return "\(maxPixelSize)|" + list.joined(separator: " ")
    }

    func cached(_ sources: [RemoteImageSource], maxPixelSize: Int) -> UIImage? { images.object(forKey: Self.key(sources, maxPixelSize) as NSString) }

    /// Whether `sources` failed less than a minute ago: `image` would answer nil without asking.
    func failedLately(_ sources: [RemoteImageSource], maxPixelSize: Int) -> Bool { misses.contains(Self.key(sources, maxPixelSize)) }

    /// The first image of `sources` that can be fetched within the caps and decoded, at most `maxPixelSize` pixels on its
    /// longer side (a source with a `keccak` only while its bytes hash to it), or nil when none can.
    func image(_ sources: [RemoteImageSource], maxPixelSize: Int) async -> UIImage? {
        guard !sources.isEmpty else { return nil }
        let key = Self.key(sources, maxPixelSize)
        if let hit = images.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        let session = self.session
        let caps = RemoteMedia.caps(forThumbnail: maxPixelSize)
        let result = await loads.value(for: key) { // fetched and decoded off the main thread
            for source in sources {
                guard !Task.isCancelled else { return nil }
                guard let data = try? await RemoteMedia.fetches.run({ try await RemoteMedia.fetch(source.url, session: session, maxBytes: caps.maxBytes) }),
                      source.keccak.map({ Keccak.hash256(data) == $0 }) ?? true,
                      let image = try? await RemoteMedia.decodes.run({
                          UIImage(cgImage: try RemoteMedia.thumbnail(data, maxPixelSize: maxPixelSize, maxSourcePixels: caps.maxSourcePixels))
                      }) else { continue }
                return image
            }
            return nil
        }
        if let result {
            images.setObject(result, forKey: key as NSString, cost: Self.cost(result))
            misses.remove(key)
        } else if !Task.isCancelled {
            misses.record(key) // a view that left before the answer came doesn't make it a miss
        }
        return result
    }

    /// Forgets every image and every miss (account deletion). A load under way still finishes for the views that wait on
    /// it.
    func removeAll() {
        images.removeAllObjects()
        misses = RecentMisses()
    }

    /// What a decoded thumbnail costs an image cache: its bitmap's bytes.
    static func cost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

/// A remote image through `RemoteImageLoader`, sized for a view `pointSize` points across (the thumbnail is decoded at
/// three pixels per point), or `placeholder` while it loads (`true`) and when it can't be shown (`false`). Its
/// `sources` are tried in order and the first that decodes shows (`RemoteImageLoader.image`); none is the placeholder.
/// A view with letters to stand in for the image passes a `grace` (`RemoteImageWait.grace`): the loading placeholder
/// shows only that long, then the letters while the image keeps loading, and the letters at once for an image that
/// failed lately. Without one, the loading placeholder (a spinner) stays until the answer. A cached image shows from the
/// first frame.
struct RemoteImage<Placeholder: View>: View {
    let sources: [RemoteImageSource]
    let pointSize: CGFloat
    var contentMode: ContentMode
    var grace: Duration?
    let placeholder: (_ loading: Bool) -> Placeholder
    @State private var image: UIImage?
    @State private var failed: Bool
    @State private var graceOver = false
    /// The image `graceOver` was counted for: a row scrolled back on screen keeps its letters rather than showing the
    /// disc again for another grace.
    @State private var graceKey: String?

    init(sources: [RemoteImageSource], pointSize: CGFloat, contentMode: ContentMode = .fill, grace: Duration? = nil,
         @ViewBuilder placeholder: @escaping (_ loading: Bool) -> Placeholder) {
        self.sources = sources
        self.pointSize = pointSize
        self.contentMode = contentMode
        self.grace = grace
        self.placeholder = placeholder
        // Read here rather than in `load`, which runs after the first frame: a logo already loaded never shows its
        // placeholder for a frame, and one that failed lately never shows the disc.
        let size = Self.maxPixelSize(pointSize)
        let cached = sources.isEmpty ? nil : RemoteImageLoader.shared.cached(sources, maxPixelSize: size)
        _image = State(initialValue: cached)
        _failed = State(initialValue: cached == nil && (sources.isEmpty || RemoteImageLoader.shared.failedLately(sources, maxPixelSize: size)))
    }

    /// The image at `url` alone; none for nil.
    init(url: URL?, pointSize: CGFloat, contentMode: ContentMode = .fill, grace: Duration? = nil,
         @ViewBuilder placeholder: @escaping (_ loading: Bool) -> Placeholder) {
        self.init(sources: url.map { [RemoteImageSource(url: $0)] } ?? [], pointSize: pointSize, contentMode: contentMode, grace: grace, placeholder: placeholder)
    }

    private static func maxPixelSize(_ pointSize: CGFloat) -> Int { max(64, Int((pointSize * 3).rounded(.up))) }
    private var maxPixelSize: Int { Self.maxPixelSize(pointSize) }
    /// What the view shows: the ordered sources, as the cache keys them.
    private var key: String { RemoteImageLoader.key(sources, maxPixelSize) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder(RemoteImageWait.shown(hasImage: false, hasURL: !sources.isEmpty, failed: failed, graceOver: graceOver) == .loading)
            }
        }
        .task(id: key) { await load() }
        .task(id: key) {
            if graceKey != key { graceOver = false; graceKey = key }
            guard !graceOver, let grace, image == nil, await RemoteImageWait.graceElapses(grace) else { return }
            graceOver = true
        }
    }

    private func load() async {
        guard !sources.isEmpty else { image = nil; failed = true; return }
        let loader = RemoteImageLoader.shared
        if let hit = loader.cached(sources, maxPixelSize: maxPixelSize) { image = hit; failed = false; return }
        image = nil
        failed = loader.failedLately(sources, maxPixelSize: maxPixelSize)
        guard !failed else { return }
        let loaded = await loader.image(sources, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}
