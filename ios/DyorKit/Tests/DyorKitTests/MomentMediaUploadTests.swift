import Foundation
import XCTest
@testable import DyorKit

/// Moment media goes to a write-once bucket and is pinned before it goes on-chain (security audit 2026-09-26, PR-2,
/// RI-9, RW-9): uploads never overwrite, an object already there reads as uploaded, and a pin that fails, is refused
/// or times out comes back as an error the app can show.
final class MomentMediaUploadTests: XCTestCase {
    private let base = URL(string: "https://project.supabase.co")!

    override func setUp() { UploadStub.reset() }

    private func client() async -> SupabaseClient {
        let client = SupabaseClient(url: base, anonKey: "anon", session: UploadStub.session())
        await client.restore(SupabaseSession(accessToken: "token", wallet: "0x" + String(repeating: "a", count: 40), expiresAt: Date().addingTimeInterval(3600)))
        return client
    }

    func testWriteOnceUploadAsksStorageNotToOverwrite() async throws {
        UploadStub.replies = [(200, "{}"), (200, "{}")]
        let client = await client()
        let url = try await client.uploadPublic(bucket: "launch-media", path: "0xaa/moment-1.jpg", data: Data([1, 2, 3]), contentType: "image/jpeg", upsert: false)
        _ = try await client.uploadPublic(bucket: "avatars", path: "0xaa/avatar.jpg", data: Data([4]), contentType: "image/jpeg")
        XCTAssertEqual(url.absoluteString, "https://project.supabase.co/storage/v1/object/public/launch-media/0xaa/moment-1.jpg")
        XCTAssertEqual(UploadStub.requests[0].value(forHTTPHeaderField: "x-upsert"), "false")
        XCTAssertEqual(UploadStub.bodies[0], Data([1, 2, 3]))
        XCTAssertEqual(UploadStub.requests[1].value(forHTTPHeaderField: "x-upsert"), "true")
    }

    func testFileUploadSendsTheFileBytes() async throws {
        UploadStub.replies = [(200, "{}")]
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).mov")
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = await client()
        _ = try await client.uploadPublic(bucket: "launch-media", path: "0xaa/moment-2.mov", file: file, contentType: "video/quicktime", upsert: false)
        XCTAssertEqual(UploadStub.bodies.first, bytes)
        XCTAssertEqual(UploadStub.requests.first?.value(forHTTPHeaderField: "Content-Type"), "video/quicktime")
    }

    func testAnObjectThatAlreadyExistsIsRecognised() {
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(409, #"{"error":"Duplicate"}"#)))
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}"#)))
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":409,"error":"Duplicate"}"#)))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}"#)))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(SupabaseError.http(403, "")))
        XCTAssertFalse(SupabaseClient.isDuplicateUpload(URLError(.timedOut)))
    }

    func testPinReturnsTheIPFSURIAndWaitsTheServersBudget() async throws {
        UploadStub.replies = [(200, #"{"cid":"bafy","uri":"ipfs://bafy","contentType":"image/jpeg","wrapped":false}"#)]
        let uri = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
        XCTAssertEqual(uri, "ipfs://bafy")
        XCTAssertEqual(UploadStub.requests.first?.url?.path, "/functions/v1/pin-media")
        // pin-media answers within its 20 s budget; the app waits a little longer, never less.
        XCTAssertEqual(UploadStub.requests.first?.timeoutInterval, SupabaseClient.pinMediaTimeout)
        XCTAssertGreaterThan(SupabaseClient.pinMediaTimeout, 20)
    }

    func testPinThatIsRateLimitedSaysWhenToRetry() async {
        UploadStub.replies = [(429, #"{"error":"too many requests — try again later","retryAfter":120,"limit":"subject"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("expected a rate limit")
        } catch SupabaseError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 120)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPinThatFailsThrowsInsteadOfFallingBack() async {
        UploadStub.replies = [(502, #"{"error":"pinning failed"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("expected an error")
        } catch SupabaseError.http(let code, _) {
            XCTAssertEqual(code, 502)
        } catch {
            XCTFail("unexpected \(error)")
        }
        UploadStub.replies = [(200, #"{"uri":"https://project.supabase.co/storage/v1/object/public/launch-media/0xaa/moment-1.jpg"}"#)]
        do {
            _ = try await client().pinToIPFS(bucket: "launch-media", path: "0xaa/moment-1.jpg")
            XCTFail("an https answer is not a pin")
        } catch {
            XCTAssertEqual((error as? SupabaseError).map { "\($0)" }, "\(SupabaseError.decoding("the pin-media response"))")
        }
    }
}

/// Answers each request with the next queued (status, JSON body) and records the request and the body it carried.
final class UploadStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var replies: [(Int, String)] = []

    static func reset() { requests = []; bodies = []; replies = [] }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append(body)
        let (status, text) = Self.replies.isEmpty ? (500, #"{"error":"no reply queued"}"#) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
