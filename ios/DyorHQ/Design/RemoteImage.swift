import DyorKit
import SwiftUI

/// The one way the app shows an image from a host it doesn't control (security audit 2026-09-26, RI-5): coin logos,
/// launch artwork, avatars, NFT art, news thumbnails. Each fetch is capped (`RemoteMedia.fetch`) — tighter for a logo-
/// sized image (`RemoteMedia.caps(forThumbnail:)`) — and only a thumbnail at the size the view asks for is decoded
/// (`RemoteMedia.thumbnail`), never the full image. Fetches and decodes run a few at a time app-wide
/// (`RemoteMedia.fetches` / `.decodes`), so a list of hostile images can't all be in memory at once. Thumbnails are
/// cached for the session under a memory budget, misses for a minute (`RecentMisses`), and one fetch is shared by every
/// view showing the same URL — and cancelled once none of them is on screen any more.
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

    private static func key(_ url: URL, _ maxPixelSize: Int) -> String { "\(maxPixelSize)|\(url.absoluteString)" }

    func cached(_ url: URL, maxPixelSize: Int) -> UIImage? { images.object(forKey: Self.key(url, maxPixelSize) as NSString) }

    /// Whether `url` failed less than a minute ago: `image` would answer nil without asking.
    func failedLately(_ url: URL, maxPixelSize: Int) -> Bool { misses.contains(Self.key(url, maxPixelSize)) }

    /// The image at `url`, at most `maxPixelSize` pixels on its longer side, or nil when it can't be fetched within
    /// the caps or isn't an image.
    func image(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(url, maxPixelSize)
        if let hit = images.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        let session = self.session
        let caps = RemoteMedia.caps(forThumbnail: maxPixelSize)
        let result = await loads.value(for: key) { // fetched and decoded off the main thread
            guard let data = try? await RemoteMedia.fetches.run({ try await RemoteMedia.fetch(url, session: session, maxBytes: caps.maxBytes) }) else { return nil }
            return try? await RemoteMedia.decodes.run {
                UIImage(cgImage: try RemoteMedia.thumbnail(data, maxPixelSize: maxPixelSize, maxSourcePixels: caps.maxSourcePixels))
            }
        }
        if let result {
            images.setObject(result, forKey: key as NSString, cost: Self.cost(result))
            misses.remove(key)
        } else if !Task.isCancelled {
            misses.record(key) // a view that left before the answer came doesn't make it a miss
        }
        return result
    }

    /// What a decoded thumbnail costs an image cache: its bitmap's bytes.
    static func cost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

/// A remote image through `RemoteImageLoader`, sized for a view `pointSize` points across (the thumbnail is decoded at
/// three pixels per point), or `placeholder` while it loads (`true`) and when it can't be shown (`false`). A view with
/// letters to stand in for the image passes a `grace` (`RemoteImageWait.grace`): the loading placeholder shows only
/// that long, then the letters while the image keeps loading, and the letters at once for a URL that failed lately.
/// Without one, the loading placeholder (a spinner) stays until the answer. A cached image shows from the first frame.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let pointSize: CGFloat
    var contentMode: ContentMode
    var grace: Duration?
    let placeholder: (_ loading: Bool) -> Placeholder
    @State private var image: UIImage?
    @State private var failed: Bool
    @State private var graceOver = false
    /// The URL `graceOver` was counted for: a row scrolled back on screen keeps its letters rather than showing the disc
    /// again for another grace.
    @State private var graceURL: URL?

    init(url: URL?, pointSize: CGFloat, contentMode: ContentMode = .fill, grace: Duration? = nil,
         @ViewBuilder placeholder: @escaping (_ loading: Bool) -> Placeholder) {
        self.url = url
        self.pointSize = pointSize
        self.contentMode = contentMode
        self.grace = grace
        self.placeholder = placeholder
        // Read here rather than in `load`, which runs after the first frame: a logo already loaded never shows its
        // placeholder for a frame, and one that failed lately never shows the disc.
        let size = Self.maxPixelSize(pointSize)
        let cached = url.flatMap { RemoteImageLoader.shared.cached($0, maxPixelSize: size) }
        _image = State(initialValue: cached)
        _failed = State(initialValue: cached == nil && (url.map { RemoteImageLoader.shared.failedLately($0, maxPixelSize: size) } ?? true))
    }

    private static func maxPixelSize(_ pointSize: CGFloat) -> Int { max(64, Int((pointSize * 3).rounded(.up))) }
    private var maxPixelSize: Int { Self.maxPixelSize(pointSize) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder(RemoteImageWait.shown(hasImage: false, hasURL: url != nil, failed: failed, graceOver: graceOver) == .loading)
            }
        }
        .task(id: url) { await load() }
        .task(id: url) {
            if graceURL != url { graceOver = false; graceURL = url }
            guard !graceOver, let grace, image == nil, await RemoteImageWait.graceElapses(grace) else { return }
            graceOver = true
        }
    }

    private func load() async {
        guard let url else { image = nil; failed = true; return }
        let loader = RemoteImageLoader.shared
        if let hit = loader.cached(url, maxPixelSize: maxPixelSize) { image = hit; failed = false; return }
        image = nil
        failed = loader.failedLately(url, maxPixelSize: maxPixelSize)
        guard !failed else { return }
        let loaded = await loader.image(url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}
