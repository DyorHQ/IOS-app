import CryptoKit
import Foundation

/* Perpl's authenticated API uses an Ed25519 key the user enrolls once with a wallet EIP-712 signature; after that
   every REST request and the trading-WS sign-in is signed with that key. The private key is generated on device
   and never leaves it (the server only stores the public key). This is the pure crypto + the enrollment HTTP
   calls; the app supplies the wallet's EIP-712 signature via Privy. See docs.perpl.xyz/.../api/authentication. */

/// A stored Perpl API key: the opaque server token plus the 32-byte Ed25519 secret, both kept in the Keychain.
public struct PerplApiKey: Sendable, Codable, Equatable {
    public let token: String
    public let secret: Data
    public let address: String
    public let scopeMask: Int

    public init(token: String, secret: Data, address: String, scopeMask: Int) {
        self.token = token
        self.secret = secret
        self.address = address
        self.scopeMask = scopeMask
    }
}

extension PerplApiKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: the Ed25519 secret and bearer token must never appear in a log, `print`, interpolation,
    /// or crash reflection.
    public var description: String { "PerplApiKey(address: \(address), secret: <redacted>, token: <redacted>)" }
    public var debugDescription: String { description }
}

public enum PerplScope {
    public static let read = 1
    public static let trade = 2
    public static let all = 3
}

public enum PerplAuth {
    // MARK: Encodings

    /// base64url with no padding, as every Perpl signature/nonce uses.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The 6-field REST canonical string.
    public static func restCanonical(chainId: Int, method: String, target: String, timestamp: String, nonce: String, body: String) -> String {
        [String(chainId), method, target, timestamp, nonce, sha256hex(Data(body.utf8))].joined(separator: "\n")
    }

    /// The 4-field trading-WS sign-in canonical string.
    public static func wsSigninCanonical(chainId: Int, timestamp: String, nonce: String) -> String {
        [String(chainId), "trading-ws-signin", timestamp, nonce].joined(separator: "\n")
    }

    // MARK: Ed25519

    public static func newSecret() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }

    public static func publicKeyHex(secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return "0x" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Ed25519 signature over the raw bytes, base64url — for REST/WS canonical strings.
    public static func sign(_ message: Data, secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return base64url(try key.signature(for: message))
    }

    /// The Ed25519 proof-of-possession over the 32-byte EIP-712 digest, `0x`-hex — sent as `pop_signature`.
    public static func proofOfPossession(digest: Data, secret: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        return "0x" + (try key.signature(for: digest)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs the two-step enrollment and signs REST requests. The wallet EIP-712 signature is supplied by the caller
/// (the app asks Privy to `secp256k1Sign` the same digest), so this stays free of any wallet dependency.
public actor PerplAuthClient {
    public struct Payload: Sendable {
        public let typedData: [String: Any]
        public let mac: String
        /// The 32-byte EIP-712 digest the wallet must sign and the Ed25519 PoP must cover.
        public let digest: Data
    }

    private let chainId: Int
    private let apiBase: URL
    private let session: URLSession

    public init(chainId: Int = 143, apiBase: URL = PerplService.restBase, session: URLSession = .shared) {
        self.chainId = chainId
        self.apiBase = apiBase
        self.session = session
    }

    /// Step 1: ask the server for the typed data to sign, and compute its digest locally.
    public func requestPayload(address: String, publicKeyHex: String, scopeMask: Int, label: String) async throws -> Payload {
        let body: [String: Any] = ["chain_id": chainId, "address": address, "public_key": publicKeyHex, "scope_mask": scopeMask, "label": label]
        let json = try await post("v1/api-key/payload", body: body)
        guard let typedData = json["typed_data"] as? [String: Any], let mac = json["mac"] as? String else {
            throw PerplError.malformedResponse("api-key payload")
        }
        let digest = try EIP712.digest(EIP712.parse(typedData))
        return Payload(typedData: typedData, mac: mac, digest: digest)
    }

    /// Step 2: submit both signatures and receive the API-key token.
    public func enroll(address: String, secret: Data, payload: Payload, walletSignature: String, scopeMask: Int) async throws -> PerplApiKey {
        let pop = try PerplAuth.proofOfPossession(digest: payload.digest, secret: secret)
        let body: [String: Any] = [
            "chain_id": chainId, "address": address, "typed_data": payload.typedData, "mac": payload.mac,
            "signature": walletSignature, "pop_signature": pop,
        ]
        let json = try await post("v1/api-key/enroll", body: body)
        guard let info = json["api_key"] as? [String: Any], let token = info["api_key"] as? String else {
            throw PerplError.malformedResponse("api-key enroll")
        }
        return PerplApiKey(token: token, secret: secret, address: address, scopeMask: scopeMask)
    }

    /// A signed GET against a history endpoint (fills, order-history, …). `target` is the path+query exactly as the
    /// gateway receives it — leading slash, no `/api` prefix, e.g. `/v1/trading/fills?count=100` — signed byte for
    /// byte and appended verbatim to the API base, so the query survives (URL.appending(path:) would percent-encode
    /// the `?` and break it). Matches PerplFoundation/api-docs examples/js/authed_rest_requests.js.
    public func signedGet(_ target: String, key: PerplApiKey, timestamp: String, nonce: String) async throws -> Data {
        let canonical = PerplAuth.restCanonical(chainId: chainId, method: "GET", target: target, timestamp: timestamp, nonce: nonce, body: "")
        let signature = try PerplAuth.sign(Data(canonical.utf8), secret: key.secret)
        guard let url = URL(string: apiBase.absoluteString + target) else { throw PerplError.malformedResponse("history URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(key.token, forHTTPHeaderField: "X-API-Key")
        request.setValue(timestamp, forHTTPHeaderField: "X-API-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-API-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-API-Signature")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PerplError.contextUnavailable(status: http.statusCode) }
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        // Native apps send no Origin, which Perpl's enrollment endpoints accept (whitelisted-or-absent).
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PerplError.contextUnavailable(status: http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PerplError.malformedResponse("json object") }
        return json
    }
}
