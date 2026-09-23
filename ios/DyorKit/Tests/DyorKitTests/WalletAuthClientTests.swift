import XCTest
@testable import DyorKit

/// The client side of the backend's sign-in and email-pepper contracts: the server-issued single-use nonce, the exact
/// message the wallet signs, the email-pepper request, and how refusals and rate limits map to user-facing errors.
final class WalletAuthClientTests: XCTestCase {
    private let base = "https://fmnjqrguvopusfufmirs.supabase.co"
    private lazy var backend = SupabaseClient(url: URL(string: base)!, anonKey: "sb_publishable_test", session: WalletAuthCapture.session())
    private let account = Secp256k1Account(privateKeyHex: "0x" + String(repeating: "11", count: 32))!
    private let serverNonce = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    /// The backend's anchored template (wallet-auth), with the same capture groups.
    private let template = try! NSRegularExpression(pattern: #"^DyorHQ Sign-In\n\nWallet: (0x[0-9a-fA-F]{40})\nNonce: ([0-9a-f]{64})\nIssued At: (\d{13})$"#)

    override func setUp() {
        super.setUp()
        WalletAuthCapture.reset()
    }

    private final class Signed { var messages: [Data] = [] }

    private func json(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: WalletAuthCapture.body(request)) as? [String: Any]) ?? [:]
    }

    private func matchesTemplate(_ message: String) -> [String]? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = template.firstMatch(in: message, range: range), match.range == range else { return nil }
        return (1...3).map { String(message[Range(match.range(at: $0), in: message)!]) }
    }

    // MARK: Sign-in message

    func testSignInMessageIsTheExactTemplate() {
        let address = account.address.checksummed
        let message = SupabaseClient.signInMessage(address: address, nonce: serverNonce, issuedAt: 1_758_600_000_123)
        XCTAssertEqual(message, "DyorHQ Sign-In\n\nWallet: \(address)\nNonce: \(serverNonce)\nIssued At: 1758600000123")
        XCTAssertEqual(matchesTemplate(message), [address, serverNonce, "1758600000123"])
        XCTAssertFalse(message.hasSuffix("\n"))
    }

    func testSignInSignsTheServerNonce() async throws {
        let address = account.address.checksummed
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1758600300000}"#),
            (200, #"{"access_token":"session.jwt","token_type":"bearer","expires_in":43200,"wallet":"\#(address.lowercased())"}"#),
        ]
        let signed = Signed()
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let session = try await backend.signIn(address: address) { message in
            signed.messages.append(message)
            return try self.account.signMessage(message)
        }
        let after = Int(Date().timeIntervalSince1970 * 1000)

        let requests = WalletAuthCapture.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "\(base)/functions/v1/wallet-auth")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sb_publishable_test")
        }
        // 1. The nonce request names the wallet exactly as the sign-in will.
        let nonceBody = json(requests[0])
        XCTAssertEqual(nonceBody.count, 2)
        XCTAssertEqual(nonceBody["action"] as? String, "nonce")
        XCTAssertEqual(nonceBody["address"] as? String, address)

        // 2. The wallet signed exactly the template around the server's nonce, and that is what was sent.
        let authBody = json(requests[1])
        let message = try XCTUnwrap(authBody["message"] as? String)
        XCTAssertEqual(authBody["address"] as? String, address)
        XCTAssertEqual(signed.messages, [Data(message.utf8)])
        let fields = try XCTUnwrap(matchesTemplate(message))
        XCTAssertEqual(fields[0], address)
        XCTAssertEqual(fields[1], serverNonce)
        let issued = try XCTUnwrap(Int(fields[2]))
        XCTAssertTrue((before...after).contains(issued))
        XCTAssertEqual(message, SupabaseClient.signInMessage(address: address, nonce: serverNonce, issuedAt: issued))
        XCTAssertEqual(authBody["signature"] as? String, try account.signMessage(Data(message.utf8)).hexString)

        XCTAssertEqual(session.accessToken, "session.jwt")
        XCTAssertEqual(session.wallet, address.lowercased())
        let current = await backend.currentSession
        XCTAssertEqual(current, session)
    }

    func testMalformedNonceIsRefusedBeforeAnythingIsSigned() async {
        for bad in [String(repeating: "A", count: 64), "abc123", serverNonce + "00", String(serverNonce.dropLast()) + "g"] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(200, #"{"nonce":"\#(bad)","expiresAt":1}"#)]
            let signed = Signed()
            do {
                _ = try await backend.signIn(address: account.address.checksummed) { signed.messages.append($0); return Data(count: 65) }
                XCTFail("accepted nonce \(bad)")
            } catch SupabaseError.decoding {} catch { XCTFail("unexpected \(error)") }
            XCTAssertTrue(signed.messages.isEmpty)
            XCTAssertEqual(WalletAuthCapture.requests.count, 1)
        }
    }

    func testSpentOrExpiredNonceIsAClearError() async {
        WalletAuthCapture.replies = [
            (200, #"{"nonce":"\#(serverNonce)","expiresAt":1}"#),
            (401, #"{"error":"sign-in nonce invalid, expired or already used"}"#),
        ]
        do {
            _ = try await backend.signIn(address: account.address.checksummed) { try self.account.signMessage($0) }
            XCTFail("expected signInRejected")
        } catch let error as SupabaseError {
            guard case .signInRejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(reason, "sign-in nonce invalid, expired or already used")
            XCTAssertEqual(error.errorDescription, "That sign-in expired or was already used. Please try again.")
        } catch { XCTFail("unexpected \(error)") }
        let current = await backend.currentSession
        XCTAssertNil(current)
    }

    func testTooManyPendingSignInsIsRateLimited() async {
        WalletAuthCapture.replies = [(429, #"{"error":"too many pending sign-ins"}"#)]
        let signed = Signed()
        do {
            _ = try await backend.signIn(address: account.address.checksummed) { signed.messages.append($0); return Data(count: 65) }
            XCTFail("expected rateLimited")
        } catch let error as SupabaseError {
            guard case .rateLimited(let retryAfter) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertNil(retryAfter)
            XCTAssertEqual(error.errorDescription, "Too many attempts. Please wait a few minutes and try again.")
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertTrue(signed.messages.isEmpty)
    }

    // MARK: email-pepper

    func testEmailPepperSendsOnlyTheHashes() async throws {
        let e = Data(repeating: 0xE0, count: 32), t = Data(repeating: 0x0F, count: 32)
        let p = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        WalletAuthCapture.replies = [(200, #"{"p":"\#(p)"}"#)]
        let pepper = try await backend.emailPepper(e: e, t: t)
        XCTAssertEqual(pepper, Data(hex: p))

        let request = try XCTUnwrap(WalletAuthCapture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "\(base)/functions/v1/email-pepper")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sb_publishable_test")
        let body = json(request)
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body["e"] as? String, String(repeating: "e0", count: 32))
        XCTAssertEqual(body["t"] as? String, String(repeating: "0f", count: 32))
    }

    func testEmailPepperRateLimitCarriesTheWait() async {
        for (retryAfter, text) in [(600, "Too many attempts. Try again in 10 min."), (61, "Too many attempts. Try again in 2 min."),
                                   (5, "Too many attempts. Try again in 1 min.")] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(429, #"{"error":"too many attempts","retryAfter":\#(retryAfter)}"#)]
            do {
                _ = try await backend.emailPepper(e: Data(count: 32), t: Data(count: 32))
                XCTFail("expected rateLimited")
            } catch let error as SupabaseError {
                guard case .rateLimited(let wait) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(wait, retryAfter)
                XCTAssertEqual(error.errorDescription, text)
            } catch { XCTFail("unexpected \(error)") }
        }
    }

    /// `retryAfter` is network input: huge, negative or non-numeric values must clamp or drop, never trap.
    func testRetryAfterNeverTraps() {
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":1e300}"#), 86_400)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":-1e300}"#), 0)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":9223372036854775807}"#), 86_400)
        XCTAssertEqual(SupabaseClient.retryAfter(#"{"retryAfter":59.2}"#), 60)
        XCTAssertNil(SupabaseClient.retryAfter(#"{"retryAfter":"soon"}"#))
        XCTAssertNil(SupabaseClient.retryAfter("not json"))
        XCTAssertEqual(SupabaseError.rateLimited(retryAfter: 86_400).errorDescription, "Too many attempts. Try again in 1440 min.")
    }

    func testEmailPepperRefusesAMalformedAnswer() async {
        for body in [#"{"p":"xyz"}"#, #"{"p":"\#(String(repeating: "AB", count: 32))"}"#, "{}", #"{"p":"\#(String(repeating: "ab", count: 31))"}"#] {
            WalletAuthCapture.reset()
            WalletAuthCapture.replies = [(200, body)]
            do {
                _ = try await backend.emailPepper(e: Data(count: 32), t: Data(count: 32))
                XCTFail("accepted \(body)")
            } catch SupabaseError.decoding {} catch { XCTFail("unexpected \(error)") }
        }
    }
}

/// Answers each request with the next queued reply and records it.
final class WalletAuthCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var replies: [(Int, String)] = []

    static func reset() { requests = []; replies = [] }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletAuthCapture.self]
        return URLSession(configuration: configuration)
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // Keep the body readable after the request is recorded (the stream can only be read once).
        var recorded = request
        recorded.httpBody = Self.body(request)
        Self.requests.append(recorded)
        let (status, body) = Self.replies.isEmpty ? (500, #"{"error":"no reply queued"}"#) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
