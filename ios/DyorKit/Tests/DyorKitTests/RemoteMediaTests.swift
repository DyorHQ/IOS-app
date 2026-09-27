import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DyorKit

/// Untrusted remote media is read up to a byte cap and decoded only as a thumbnail, after its declared size is checked
/// (security audit 2026-09-26, RI-5).
final class RemoteMediaTests: XCTestCase {
    override func setUp() { MediaStub.reset() }

    // MARK: Decoding

    func testThumbnailDownsamplesToTheLongerSide() throws {
        let image = try RemoteMedia.thumbnail(Self.png(width: 400, height: 200), maxPixelSize: 100)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
    }

    func testThumbnailNeverScalesUp() throws {
        let image = try RemoteMedia.thumbnail(Self.png(width: 40, height: 30), maxPixelSize: 1000)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
    }

    func testDeclaredSideOverTheCapIsRefusedBeforeDecoding() throws {
        let data = try Self.png(width: 9000, height: 2)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(data, maxPixelSize: 64)) { XCTAssertEqual($0 as? RemoteMedia.Failure, .tooManyPixels) }
    }

    func testDeclaredAreaOverTheCapIsRefused() throws {
        let data = try Self.png(width: 300, height: 300)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(data, maxPixelSize: 64, maxSourcePixels: 300 * 299)) {
            XCTAssertEqual($0 as? RemoteMedia.Failure, .tooManyPixels)
        }
        XCTAssertNoThrow(try RemoteMedia.thumbnail(data, maxPixelSize: 64, maxSourcePixels: 300 * 300))
    }

    func testHTMLIsNotAnImage() {
        let html = Data("<html><body>Index of /ipfs/bafy…</body></html>".utf8)
        XCTAssertThrowsError(try RemoteMedia.thumbnail(html, maxPixelSize: 64)) { XCTAssertEqual($0 as? RemoteMedia.Failure, .notAnImage) }
    }

    // MARK: Fetching

    func testFetchReturnsTheBody() async throws {
        MediaStub.reply = (200, ["Content-Type": "image/png"], Data(repeating: 7, count: 2048))
        let data = try await RemoteMedia.fetch(URL(string: "https://cdn.example/logo.png")!, session: MediaStub.session(), maxBytes: 4096)
        XCTAssertEqual(data.count, 2048)
    }

    func testDeclaredLengthOverTheCapIsRefused() async {
        MediaStub.reply = (200, ["Content-Length": "5000"], Data(repeating: 1, count: 5000))
        await XCTAssertThrowsFailure(.tooLarge) { try await RemoteMedia.fetch(URL(string: "https://cdn.example/big.png")!, session: MediaStub.session(), maxBytes: 4096) }
    }

    func testUndeclaredBodyOverTheCapIsCutOff() async {
        MediaStub.reply = (200, [:], Data(repeating: 1, count: 10_000))
        MediaStub.omitLength = true
        await XCTAssertThrowsFailure(.tooLarge) { try await RemoteMedia.fetch(URL(string: "https://cdn.example/stream")!, session: MediaStub.session(), maxBytes: 4096) }
    }

    func testErrorStatusIsRefused() async {
        MediaStub.reply = (429, [:], Data("slow down".utf8))
        await XCTAssertThrowsFailure(.status(429)) { try await RemoteMedia.fetch(URL(string: "https://ipfs.io/ipfs/bafy")!, session: MediaStub.session()) }
    }

    func testOnlyHTTPSIsFetched() async {
        await XCTAssertThrowsFailure(.insecureURL) { try await RemoteMedia.fetch(URL(string: "http://cdn.example/logo.png")!, session: MediaStub.session()) }
        XCTAssertTrue(MediaStub.requests.isEmpty)
    }

    // MARK: Helpers

    private func XCTAssertThrowsFailure(_ expected: RemoteMedia.Failure, _ body: () async throws -> Data, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteMedia.Failure, expected, file: file, line: line)
        }
    }

    static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Serves one canned response to every request, and records the requests.
final class MediaStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var reply: (Int, [String: String], Data) = (500, [:], Data())
    /// Leave Content-Length out, as a streaming server would.
    nonisolated(unsafe) static var omitLength = false

    static func reset() { requests = []; reply = (500, [:], Data()); omitLength = false }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, body) = Self.reply
        var fields = headers
        if !Self.omitLength, fields["Content-Length"] == nil { fields["Content-Length"] = "\(body.count)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a network would deliver it.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 1024, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
