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
    /// Content-Length is larger, and cancelled as soon as the body grows past the cap. The body arrives in the chunks
    /// the network delivers (a task delegate), so the cap costs nothing per byte.
    public static func fetch(_ url: URL, session: URLSession, maxBytes: Int = maxImageBytes) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        let load = CappedLoad(maxBytes: maxBytes)
        task.delegate = load
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in load.start(task, continuation) }
        } onCancel: {
            task.cancel()
        }
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

/// One capped download: checks the response, appends the body's chunks up to the cap, and answers once. Its callbacks
/// run on the session's serial delegate queue; `start` runs on the caller's. The continuation is handed between the
/// two under a lock, so it is resumed exactly once, whichever comes first — the task's completion, or a cancellation
/// that got in before the task was resumed.
private final class CappedLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private var data = Data()
    private var failure: RemoteMedia.Failure?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Data, Error>) {
        // Only a task never resumed can be started. One already cancelled (canceling, or completed if its completion
        // came first) may never report back, so it is answered here; one cancelled from now on reports its
        // completion, which finds the continuation stored.
        lock.lock()
        let startable = task.state == .suspended
        if startable { self.continuation = continuation }
        lock.unlock()
        guard startable else { continuation.resume(throwing: CancellationError()); return }
        task.resume()
    }

    /// The continuation, taken once.
    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = .status(http.statusCode)
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maxBytes) {
            failure = .tooLarge
            completionHandler(.cancel)
        } else {
            data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard data.count + chunk.count <= maxBytes else {
            failure = .tooLarge
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = take() else { return }
        if let failure { continuation.resume(throwing: failure) }
        else if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: data) }
    }
}
