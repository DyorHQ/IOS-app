import DyorKit
import SwiftUI

/// The one way the app shows an image from a host it doesn't control (security audit 2026-09-26, RI-5): coin logos,
/// launch artwork, avatars, NFT art, news thumbnails. Each fetch is capped (`RemoteMedia.fetch`) — tighter for a logo-
/// sized image (`RemoteMedia.caps(forThumbnail:)`) — and only a thumbnail at the size the view asks for is decoded
/// (`RemoteMedia.thumbnail`), never the full image. Fetches and decodes run a few at a time app-wide
/// (`RemoteMedia.fetches` / `.decodes`), so a list of hostile images can't all be in memory at once. Thumbnails are
/// cached for the session under a memory budget, misses for a minute, and one fetch is shared by every view showing
/// the same URL — and cancelled once none of them is on screen any more.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var misses: [String: Date] = [:]
    private let loads = SharedLoads<UIImage>()
    private let session = RemoteMedia.makeSession()

    private static func key(_ url: URL, _ maxPixelSize: Int) -> String { "\(maxPixelSize)|\(url.absoluteString)" }

    func cached(_ url: URL, maxPixelSize: Int) -> UIImage? { images.object(forKey: Self.key(url, maxPixelSize) as NSString) }

    /// The image at `url`, at most `maxPixelSize` pixels on its longer side, or nil when it can't be fetched within
    /// the caps or isn't an image.
    func image(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(url, maxPixelSize)
        if let hit = images.object(forKey: key as NSString) { return hit }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 60 { return nil }
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
            misses[key] = nil
        } else if !Task.isCancelled {
            misses[key] = Date() // a view that left before the answer came doesn't make it a miss
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
/// three pixels per point), or `placeholder` while it loads (`true`) and when it can't be shown (`false`).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let pointSize: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: (_ loading: Bool) -> Placeholder
    @State private var image: UIImage?
    @State private var failed = false

    private var maxPixelSize: Int { max(64, Int((pointSize * 3).rounded(.up))) }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder(url != nil && !failed)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; failed = true; return }
        if let hit = RemoteImageLoader.shared.cached(url, maxPixelSize: maxPixelSize) { image = hit; failed = false; return }
        image = nil; failed = false
        let loaded = await RemoteImageLoader.shared.image(url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}
