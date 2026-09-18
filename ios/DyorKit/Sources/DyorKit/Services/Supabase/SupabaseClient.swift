import Foundation

/* A small Supabase client for DyorHQ's backend: signs in by having the user's wallet personal_sign a fresh nonce
   (verified by the wallet-auth Edge Function, which mints a session), then reads and writes tables over PostgREST.
   Public data reads with the publishable key alone; writes carry the wallet session token, and row-level security
   ties every row to the signed-in wallet. No private keys are ever sent — only a signature over a nonce. */

public struct SupabaseSession: Sendable, Codable, Equatable {
    public let accessToken: String
    public let wallet: String
    public let expiresAt: Date
    public var isValid: Bool { expiresAt > Date().addingTimeInterval(60) }
}

public enum SupabaseError: LocalizedError {
    case http(Int, String)
    case notSignedIn
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if code == 500, body.contains("APP_JWT_SECRET") { return "Sign-in isn't finished on the server yet (APP_JWT_SECRET not set)." }
            return "Supabase request failed (\(code))."
        case .notSignedIn: return "Sign in to DyorHQ to continue."
        case .decoding(let what): return "Could not read \(what) from the server."
        }
    }
}

public actor SupabaseClient {
    public let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private var current: SupabaseSession?

    public init(url: URL, anonKey: String, session: URLSession = .shared) {
        baseURL = url
        self.anonKey = anonKey
        self.session = session
    }

    public var currentSession: SupabaseSession? { current?.isValid == true ? current : nil }
    public var signedInWallet: String? { currentSession?.wallet }

    /// Reuse a stored session if it's still valid.
    public func restore(_ stored: SupabaseSession?) {
        current = (stored?.isValid == true) ? stored : nil
    }

    public func signOut() { current = nil }

    /// Signs in: builds a nonce message, has the wallet sign it, and exchanges the signature for a session at the
    /// wallet-auth function. `sign` is the wallet's `signMessage` (EIP-191 personal_sign).
    public func signIn(address: String, sign: (Data) async throws -> Data) async throws -> SupabaseSession {
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) }).hexString
        let issued = Int(Date().timeIntervalSince1970 * 1000)
        let message = "DyorHQ Sign-In\n\nWallet: \(address)\nNonce: \(nonce)\nIssued At: \(issued)"
        let signature = try await sign(Data(message.utf8)).hexString
        let body = try JSONSerialization.data(withJSONObject: ["address": address, "message": message, "signature": signature])
        let data = try await send(method: "POST", path: "functions/v1/wallet-auth", query: [], body: body, prefer: nil, authed: false)
        struct AuthResponse: Decodable { let access_token: String; let expires_in: Int; let wallet: String }
        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data) else { throw SupabaseError.decoding("the sign-in response") }
        let created = SupabaseSession(accessToken: response.access_token, wallet: response.wallet, expiresAt: Date().addingTimeInterval(Double(response.expires_in)))
        current = created
        return created
    }

    // MARK: PostgREST

    /// Reads rows from a table. `query` is the PostgREST query (select, filters, order, limit).
    public func read<T: Decodable>(_ table: String, query: [URLQueryItem] = [], authed: Bool = false) async throws -> [T] {
        let data = try await send(method: "GET", path: "rest/v1/\(table)", query: query, body: nil, prefer: nil, authed: authed)
        return try decode(data, as: [T].self)
    }

    /// Inserts or upserts a row, returning the stored representation. Requires a session.
    @discardableResult
    public func upsert<Body: Encodable, T: Decodable>(_ table: String, _ value: Body, onConflict: String? = nil, returning: T.Type = T.self) async throws -> T {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        let body = try JSONEncoder().encode(value)
        let data = try await send(method: "POST", path: "rest/v1/\(table)", query: query, body: body, prefer: "return=representation,resolution=merge-duplicates", authed: true)
        let rows = try decode(data, as: [T].self)
        guard let first = rows.first else { throw SupabaseError.decoding(table) }
        return first
    }

    /// Upserts many rows in one request (no representation returned). Requires a session.
    public func upsertRows<Body: Encodable>(_ table: String, _ rows: [Body], onConflict: String? = nil) async throws {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        guard !rows.isEmpty else { return }
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }
        let body = try JSONEncoder().encode(rows)
        _ = try await send(method: "POST", path: "rest/v1/\(table)", query: query, body: body, prefer: "return=minimal,resolution=merge-duplicates", authed: true)
    }

    /// Calls a Postgres function through PostgREST RPC with the current session (or the publishable key).
    public func rpc<T: Decodable>(_ function: String, _ arguments: [String: String] = [:], authed: Bool = false) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: arguments)
        let data = try await send(method: "POST", path: "rest/v1/rpc/\(function)", query: [], body: body, prefer: nil, authed: authed)
        return try decode(data, as: T.self)
    }

    /// Deletes rows matching the query. Requires a session.
    public func delete(_ table: String, query: [URLQueryItem]) async throws {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        _ = try await send(method: "DELETE", path: "rest/v1/\(table)", query: query, body: nil, prefer: "return=minimal", authed: true)
    }

    // MARK: Storage

    /// Uploads bytes to a public Storage bucket (upserting) and returns the public URL. Requires a session; RLS on
    /// `storage.objects` decides whether the wallet may write to that path. Only the resulting public URL is stored
    /// in a row — never the bytes.
    @discardableResult
    public func uploadPublic(bucket: String, path: String, data: Data, contentType: String) async throws -> URL {
        guard let token = currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        var request = URLRequest(url: baseURL.appending(path: "storage/v1/object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (respData, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: respData, encoding: .utf8) ?? "")
        }
        return baseURL.appending(path: "storage/v1/object/public/\(bucket)/\(path)")
    }

    /// Deletes every object under `prefix` (a folder) in a Storage bucket: lists first, then removes what is there,
    /// so an empty folder is simply a no-op (Storage answers a blind delete of a missing object with an error).
    /// RLS on `storage.objects` decides whether the wallet owns those paths. Requires a session. Returns the count.
    @discardableResult
    public func deleteObjects(bucket: String, prefix: String) async throws -> Int {
        guard let token = currentSession?.accessToken else { throw SupabaseError.notSignedIn }
        func storageRequest(_ method: String, _ path: String, json: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: baseURL.appending(path: "storage/v1/\(path)"))
            request.httpMethod = method
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            return request
        }
        let (listData, listResponse) = try await session.data(for: try storageRequest("POST", "object/list/\(bucket)", json: ["prefix": prefix, "limit": 1000]))
        if let http = listResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: listData, encoding: .utf8) ?? "")
        }
        let entries = (try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]) ?? []
        // Folders come back without an id; only real objects are deletable.
        let paths = entries.compactMap { entry -> String? in
            guard entry["id"] is String, let name = entry["name"] as? String else { return nil }
            return "\(prefix)/\(name)"
        }
        guard !paths.isEmpty else { return 0 }
        let (deleteData, deleteResponse) = try await session.data(for: try storageRequest("DELETE", "object/\(bucket)", json: ["prefixes": paths]))
        if let http = deleteResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: deleteData, encoding: .utf8) ?? "")
        }
        return paths.count
    }

    // MARK: Edge Functions

    /// Pins an already-uploaded public object to IPFS through the `pin-media` Edge Function (Pinata) and returns its
    /// `ipfs://<cid>` URI, for writing on-chain as a Moment's permanent media pointer. Requires a session; throws if
    /// the function is unavailable or its Pinata secret is not configured (the caller falls back to the https URL).
    public func pinToIPFS(bucket: String, path: String) async throws -> String {
        guard currentSession != nil else { throw SupabaseError.notSignedIn }
        let body = try JSONSerialization.data(withJSONObject: ["bucket": bucket, "path": path])
        let data = try await send(method: "POST", path: "functions/v1/pin-media", query: [], body: body, prefer: nil, authed: true)
        struct Response: Decodable { let uri: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.uri.hasPrefix("ipfs://") else {
            throw SupabaseError.decoding("the pin-media response")
        }
        return response.uri
    }

    /// Calls an Edge Function that authenticates the caller with its own bearer token (not a Supabase session) —
    /// e.g. `delete-account`, which takes the Privy access token. Returns the response body.
    public func invoke(function: String, bearer: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "functions/v1/\(function)"))
        request.httpMethod = "POST"
        request.httpBody = body ?? Data("{}".utf8)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Transport

    private func send(method: String, path: String, query: [URLQueryItem], body: Data?, prefer: String?, authed: Bool) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let bearer = (authed ? currentSession?.accessToken : nil) ?? anonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.timeoutInterval = 25

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SupabaseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(T.self, from: data) }
        catch { throw SupabaseError.decoding(String(describing: T.self)) }
    }
}
