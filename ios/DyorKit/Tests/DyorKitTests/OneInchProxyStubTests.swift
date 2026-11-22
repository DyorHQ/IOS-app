import BigInt
import XCTest
@testable import DyorKit

/// The 1inch venue's own transport (`OneInchVenue.transport`, over the engine's URL session), answered by a URLProtocol
/// stub as `SwapNetStub` and `GatedKuruStub` answer the other venues: the request that reaches the wire is the proxy's
/// route, POSTed with the session's headers and the exact body, and its answer is read. Kept apart from
/// `OneInchVenueTests`, which needs no network stub at all: URLProtocol stubs can stall under swift-corelibs-foundation.
final class OneInchProxyStubTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let proxy = URL(string: "https://project.supabase.invalid/functions/v1/oneinch-proxy")!

    override func setUp() {
        super.setUp()
        OneInchProxyURLStub.reset()
        XStockFixtures.reads.reset()
    }

    func testTheURLSessionTransportSendsTheRouteAndReadsTheAnswer() async throws {
        let stock = XStockFixtures.stock
        let usdc = BigUInt(100_000_000)
        let fair = usdc * BigUInt(10).power(26) / (XStockFixtures.answer * BigUInt(10).power(6))
        OneInchProxyURLStub.answer = (Data(#"{"dstAmount":"\#(fair)"}"#.utf8), 200)
        let engine = SwapEngine(rpc: NoNetworkStub.rpc(), session: OneInchProxyURLStub.session(), xStocks: XStockFixtures.registry,
                                xStocksCompiledIn: true, referenceRead: XStockFixtures.reads.reader(), oneInchProxy: proxy,
                                oneInchCredentials: { _ in ["apikey": "sb_publishable_test", "Authorization": "Bearer session.jwt"] })
        await engine.setXStocksFlag(true)
        await engine.setXStocksServerStatus(mode: .on, beta: false, for: account)
        await engine.setXStocksDisclosure(acknowledged: true, for: account)
        let request = SwapRequest(tokenIn: .usdc, tokenOut: stock, amountIn: usdc, slippageBps: 50, account: account)
        let quote = try await engine.quote(.oneInch, for: request)
        XCTAssertEqual(quote?.amountOut, fair)
        XCTAssertEqual(quote?.firmness, .indicative)

        let sent = try XCTUnwrap(OneInchProxyURLStub.requests().first)
        XCTAssertEqual(OneInchProxyURLStub.requests().count, 1)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://project.supabase.invalid/functions/v1/oneinch-proxy/quote")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer session.jwt")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(String(decoding: sent.body, as: UTF8.self),
                       #"{"amount":"100000000","dst":"\#(stock.address.hex)","src":"\#(Monad.usdc.hex.lowercased())"}"#)

        // A refusal is the proxy's code, said in the app's words.
        OneInchProxyURLStub.answer = (Data(#"{"code":"rate_limited","retryAfter":30}"#.utf8), 429)
        do {
            _ = try await engine.quote(.oneInch, for: request)
            XCTFail("rate limited")
        } catch {
            XCTAssertEqual(error as? OneInchError, .rateLimited(retryAfter: 30))
        }
    }
}

/// Answers every request with `answer`, recording each with its body (read from the body stream when the system moved
/// it there).
final class OneInchProxyURLStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) private static var reply: (Data, Int) = (Data(), 500)

    static var answer: (Data, Int) {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }

    static func reset() {
        lock.withLock {
            sent = []
            reply = (Data(), 500)
        }
    }

    static func requests() -> [(request: URLRequest, body: Data)] { lock.withLock { sent } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneInchProxyURLStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let (data, status) = Self.lock.withLock {
            Self.sent.append((request, body))
            return Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
