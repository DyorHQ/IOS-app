import Foundation
import XCTest
@testable import DyorKit

/// A news answer a feed failed is shown but never cached as fresh (security audit 2026-09-26, RS-10).
final class NewsCacheTests: XCTestCase {
    private let a = NewsSource(name: "A", feed: URL(string: "https://a.example/rss")!)
    private let b = NewsSource(name: "B", feed: URL(string: "https://b.example/rss")!)

    override func setUp() { FeedStub.reset() }

    private static func rss(_ title: String, _ link: String) -> String {
        """
        <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
        <item><title>\(title)</title><link>\(link)</link><pubDate>Sat, 26 Sep 2026 10:00:00 GMT</pubDate></item>
        </channel></rss>
        """
    }

    func testAnAnswerWithAFailedFeedIsNotCached() async {
        FeedStub.replies = ["a.example": (500, ""), "b.example": (200, Self.rss("Hello", "https://b.example/1"))]
        let news = NewsService(sources: [a, b], session: FeedStub.session())
        let first = await news.latest()
        XCTAssertEqual(first.map(\.title), ["Hello"])
        XCTAssertEqual(FeedStub.count, 2)

        // Not cached: the next call asks both feeds again.
        FeedStub.replies["a.example"] = (200, Self.rss("World", "https://a.example/1"))
        let second = await news.latest()
        XCTAssertEqual(Set(second.map(\.title)), ["Hello", "World"])
        XCTAssertEqual(FeedStub.count, 4)

        // Complete: cached for two minutes.
        _ = await news.latest()
        XCTAssertEqual(FeedStub.count, 4)
    }
}

/// Answers by host with a queued (status, body) and counts requests.
final class FeedStub: URLProtocol {
    nonisolated(unsafe) static var replies: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var count = 0

    static func reset() { replies = [:]; count = 0 }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.count += 1
        let (status, body) = Self.replies[request.url?.host ?? ""] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/rss+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
