import CoreGraphics
import Foundation
import ImageIO

/// Fetching and decoding images from hosts DyorHQ does not control — coin logos written on-chain by whoever launched
/// the coin, Moment media, NFT art, news thumbnails, profile avatars (security audit 2026-09-26, RI-5). A few MB on the
/// wire can declare a 30 000 × 30 000 image that takes gigabytes to decode, and a server can stream forever, so every
/// such image goes through here: the body is read up to a byte cap, the image's declared size is checked before any
/// pixel is decoded, and only a thumbnail at the size the screen shows is ever decoded.
public enum RemoteMedia {
    /// The most bytes read for one image.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// The longest side, in pixels, an image may declare and still be decoded.
    public static let maxSourceDimension = 8192
    /// The most pixels an image may declare and still be decoded (a 48 MP camera photo fits).
    public static let maxSourcePixels = 50_000_000

    public enum Failure: Error, Equatable {
        /// Only https is fetched.
        case insecureURL
        /// The server answered with a status outside 2xx.
        case status(Int)
        /// The body is, or says it is, larger than the cap.
        case tooLarge
        /// The bytes are not an image ImageIO can read (an HTML page, an SVG, garbage).
        case notAnImage
        /// The image declares more pixels than may be decoded.
        case tooManyPixels
    }

    /// A session for untrusted media: no cookies or stored credentials, and a limit on the whole transfer as well as
    /// on each wait for data, so a server that trickles bytes can't hold a request open.
    public static func makeSession(requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    /// GETs `url` (https only) and returns its body, reading at most `maxBytes`: refused up front when the declared
    /// Content-Length is larger, and cancelled as soon as the body grows past the cap.
    public static func fetch(_ url: URL, session: URLSession, maxBytes: Int = maxImageBytes) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            bytes.task.cancel()
            throw Failure.status(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw Failure.tooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(maxBytes))))
        for try await byte in bytes {
            guard data.count < maxBytes else {
                bytes.task.cancel()
                throw Failure.tooLarge
            }
            data.append(byte)
        }
        return data
    }

    /// Decodes `data` as a thumbnail whose longer side is at most `maxPixelSize` (never scaled up), after checking the
    /// size the image declares — so the full-resolution image is never decoded. The EXIF orientation is applied, and
    /// any thumbnail embedded in the file is ignored (it need not match the image).
    public static func thumbnail(_ data: Data, maxPixelSize: Int, maxSourceDimension: Int = maxSourceDimension,
                                 maxSourcePixels: Int = maxSourcePixels) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw Failure.notAnImage }
        guard width <= maxSourceDimension, height <= maxSourceDimension, width * height <= maxSourcePixels else { throw Failure.tooManyPixels }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, max(width, height))),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw Failure.notAnImage }
        return image
    }
}
