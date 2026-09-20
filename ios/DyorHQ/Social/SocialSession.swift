import DyorKit
import Foundation
import Observation
import Security

/// The DyorHQ social/backend session: signs in to Supabase by having the Privy wallet sign a nonce (login stays in
/// Privy), keeps the resulting token in the Keychain, and manages the wallet's public profile. Everything else
/// (feed, follows, watchlists, alerts) builds on this session and its `SupabaseClient`.
@Observable
@MainActor
final class SocialSession {
    enum State: Equatable { case signedOut, signingIn, signedIn }

    private(set) var state: State = .signedOut
    private(set) var profile: SocialProfile?
    private(set) var error: String?
    let client: SupabaseClient
    /// The wallet the social session is currently bound to (lowercased address), so a wallet change is detected.
    private var boundWallet: String?
    /// The open `sessions` row for this app session, persisted per wallet so a sign-out after an app relaunch can
    /// still close the same row.
    private var currentSessionRowId: String?

    var isSignedIn: Bool { state == .signedIn }

    init(config: AppConfig) {
        client = SupabaseClient(url: config.supabaseURL, anonKey: config.supabaseKey)
    }

    /// Binds the social session to the active wallet. Called whenever the signed-in wallet changes (sign in, sign
    /// out, or switch accounts), so the social identity always matches the current wallet — there is no separate
    /// social sign-out. A different wallet (or none) immediately drops the previous wallet's in-memory session so a
    /// stale profile can never show; a genuine wallet sign-out (wallet → none) also clears the stored token, fully
    /// signing out of social. A stored session is only ever reused when it belongs to exactly this wallet.
    func bind(address: Address?) {
        let target = address?.checksummed.lowercased()
        guard target != boundWallet else { return }
        let previous = boundWallet
        boundWallet = target

        // Full wallet sign-out: record the sign-out time on the still-authed session, THEN tear down.
        if target == nil {
            state = .signedOut; profile = nil; error = nil
            Task {
                if let previous { await closeSession(wallet: previous) }
                await client.signOut()
                if previous != nil { SupabaseSessionStore.clear() }
            }
            return
        }

        reset() // switching to a different wallet: drop the previous wallet's in-memory session
        guard let target, let stored = SupabaseSessionStore.load(), stored.wallet == target, stored.isValid else { return }
        Task {
            await client.restore(stored)
            if await client.currentSession != nil {
                state = .signedIn
                try? await ensureProfile(wallet: target) // safety net: a returning wallet always has a profile
                await openSession(wallet: target)        // a restored session on launch is this app-session's sign-in
                await loadProfile()
            }
        }
    }

    /// Clears the in-memory session (keeps any stored token). Used when rebinding to a different wallet.
    private func reset() {
        Task { await client.signOut() }
        state = .signedOut
        profile = nil
        error = nil
    }

    func signIn(session: Session) async {
        guard let wallet = session.wallet, let address = session.address else { error = SessionError.readOnly.localizedDescription; return }
        state = .signingIn
        error = nil
        do {
            let created = try await client.signIn(address: address.checksummed) { message in try await wallet.signMessage(message) }
            SupabaseSessionStore.save(created)
            boundWallet = created.wallet
            state = .signedIn
            try? await ensureProfile(wallet: created.wallet)
            await openSession(wallet: created.wallet)
            await loadProfile()
        } catch {
            state = .signedOut
            self.error = describe(error)
        }
    }

    /// Full sign-out: records the sign-out time, then clears the in-memory session and the stored token.
    func signOut() {
        let wallet = boundWallet
        state = .signedOut; profile = nil; error = nil
        boundWallet = nil
        Task {
            if let wallet { await closeSession(wallet: wallet) } // on the still-authed session
            await client.signOut()
            SupabaseSessionStore.clear()
        }
    }

    /// Make sure a profile row exists so foreign keys (activity, sessions, posts, follows, watchlists) resolve and the
    /// user has a profile to edit. Called on every sign-in and session restore, so creating an account, importing a
    /// private key, or using a passkey all auto-create the profile.
    private func ensureProfile(wallet: String) async throws {
        struct Row: Encodable { let wallet: String }
        let _: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet), onConflict: "wallet")
    }

    // MARK: Sessions (sign-in / sign-out analytics)

    private struct SessionRow: Decodable { let id: String }
    private static func sessionKey(_ wallet: String) -> String { "session.rowid.\(wallet)" }

    /// Opens a `sessions` row (client-generated id) marking this app-session's sign-in. Best-effort; a failure never
    /// blocks sign-in. The id is persisted per wallet so a later sign-out can close exactly this row.
    private func openSession(wallet: String) async {
        let id = UUID().uuidString.lowercased()
        struct Row: Encodable { let id: String; let wallet: String }
        let opened: SessionRow? = try? await client.upsert("sessions", Row(id: id, wallet: wallet), onConflict: "id")
        guard opened != nil else { return }
        currentSessionRowId = id
        UserDefaults.standard.set(id, forKey: Self.sessionKey(wallet))
    }

    /// Stamps `signed_out_at` on the wallet's open session row. Must run while the client is still authed.
    private func closeSession(wallet: String) async {
        guard let id = currentSessionRowId ?? UserDefaults.standard.string(forKey: Self.sessionKey(wallet)) else { return }
        struct Row: Encodable { let id: String; let wallet: String; let signed_out_at: String }
        let _: SessionRow? = try? await client.upsert("sessions", Row(id: id, wallet: wallet, signed_out_at: Self.iso(Date())), onConflict: "id")
        currentSessionRowId = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionKey(wallet))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    func loadProfile() async {
        guard let wallet = await client.signedInWallet else { return }
        let rows: [SocialProfile] = (try? await client.read("profiles", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "wallet", value: "eq.\(wallet)"),
        ], authed: true)) ?? []
        profile = rows.first
    }

    func save(handle: String?, displayName: String?, bio: String?) async throws {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        struct Row: Encodable {
            let wallet: String
            let handle: String?
            let display_name: String?
            let bio: String?
        }
        let clean: (String?) -> String? = { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        let updated: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet, handle: clean(handle)?.lowercased(), display_name: clean(displayName), bio: clean(bio)), onConflict: "wallet")
        profile = updated
    }

    /// Uploads a launchpad coin image to the wallet's folder in the public `launch-media` bucket and returns its
    /// public URL — which the caller writes on-chain as the token's logo. Requires a DyorHQ Social session.
    func uploadLaunchImage(jpeg: Data) async throws -> URL {
        guard await client.signedInWallet != nil else { throw SupabaseError.notSignedIn }
        let wallet = await client.signedInWallet!
        let name = UUID().uuidString.lowercased()
        return try await client.uploadPublic(bucket: "launch-media", path: "\(wallet)/\(name).jpg", data: jpeg, contentType: "image/jpeg")
    }

    /// Uploads a Moment's photo to the wallet's folder in the public `launch-media` bucket and returns its public
    /// URL — the caller writes it on-chain as the NFT's `mediaURI` next to the keccak-256 of these exact bytes.
    func uploadMomentImage(jpeg: Data) async throws -> URL {
        try await uploadMomentMedia(jpeg, contentType: "image/jpeg", fileExtension: "jpg")
    }

    /// Uploads any Moment media file (photo, video, or a video's cover frame) to the wallet's folder in the public
    /// `launch-media` bucket and returns its public URL, which the Moment writes on-chain as the NFT's image or
    /// animation. Videos are accepted up to 50 MB.
    func uploadMomentMedia(_ data: Data, contentType: String, fileExtension: String) async throws -> URL {
        try await uploadAndPinMomentMedia(data, contentType: contentType, fileExtension: fileExtension).mirror
    }

    /// Uploads Moment media to the public bucket and pins it to IPFS, so the NFT's on-chain pointer is a permanent
    /// `ipfs://` CID that outlives DyorHQ's servers. Returns the URI to write on-chain — the `ipfs://` CID, or the
    /// Supabase https URL as a fallback when pinning is unavailable (e.g. the Pinata secret is not set yet) — plus
    /// the Supabase URL as a fast in-app mirror. The provenance hash is of these exact bytes regardless of storage.
    func uploadAndPinMomentMedia(_ data: Data, contentType: String, fileExtension: String) async throws -> (onchain: String, mirror: URL) {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        let name = "moment-" + UUID().uuidString.lowercased()
        let path = "\(wallet)/\(name).\(fileExtension)"
        let url = try await client.uploadPublic(bucket: "launch-media", path: path, data: data, contentType: contentType)
        let onchain = (try? await client.pinToIPFS(bucket: "launch-media", path: path)) ?? url.absoluteString
        return (onchain, url)
    }

    /// Uploads a new profile picture (JPEG bytes) to the wallet's own folder in the public `avatars` bucket, then
    /// records its URL on the profile. A cache-busting query is appended so the new image shows immediately.
    func uploadAvatar(jpeg: Data) async throws {
        guard let wallet = await client.signedInWallet else { throw SupabaseError.notSignedIn }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = try await client.uploadPublic(bucket: "avatars", path: "\(wallet)/avatar.jpg", data: jpeg, contentType: "image/jpeg")
        let cacheBusted = "\(url.absoluteString)?v=\(stamp)"
        struct Row: Encodable { let wallet: String; let avatar_url: String }
        let updated: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet, avatar_url: cacheBusted), onConflict: "wallet")
        profile = updated
    }
}

/// A public DyorHQ profile row.
struct SocialProfile: Codable, Identifiable, Equatable {
    let wallet: String
    var handle: String?
    var display_name: String?
    var bio: String?
    var avatar_url: String?
    var id: String { wallet }
}

/// Keychain storage for the short-lived Supabase session token (a bearer token, never a key).
enum SupabaseSessionStore {
    private static let service = "fun.dyorhq.supabase"
    private static let account = "session"

    static func save(_ session: SupabaseSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: session token stays on this device only
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> SupabaseSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
