import DyorKit
import Foundation
import Observation
import Security

/// The DyorHQ social/backend session: signs in to Supabase by having the Privy wallet sign a nonce (login stays in
/// Privy), keeps the resulting token in the Keychain, and manages the wallet's public profile. Everything else
/// (feed, follows, watchlists, alerts, copy trading) builds on this session and its `SupabaseClient`.
@Observable
@MainActor
final class SocialSession {
    enum State: Equatable { case signedOut, signingIn, signedIn }

    private(set) var state: State = .signedOut
    private(set) var profile: SocialProfile?
    private(set) var error: String?
    let client: SupabaseClient

    var isSignedIn: Bool { state == .signedIn }

    init(config: AppConfig) {
        client = SupabaseClient(url: config.supabaseURL, anonKey: config.supabaseKey)
    }

    /// Reuse a stored session (if still valid) for the given wallet on launch.
    func restore(address: Address?) {
        guard let address, let stored = SupabaseSessionStore.load(), stored.wallet == address.checksummed.lowercased(), stored.isValid else { return }
        Task {
            await client.restore(stored)
            if await client.currentSession != nil { state = .signedIn; await loadProfile() }
        }
    }

    func signIn(session: Session) async {
        guard let wallet = session.wallet, let address = session.address else { error = SessionError.readOnly.localizedDescription; return }
        state = .signingIn
        error = nil
        do {
            let created = try await client.signIn(address: address.checksummed) { message in try await wallet.signMessage(message) }
            SupabaseSessionStore.save(created)
            state = .signedIn
            try? await ensureProfile(wallet: created.wallet)
            await loadProfile()
        } catch {
            state = .signedOut
            self.error = describe(error)
        }
    }

    func signOut() {
        Task { await client.signOut() }
        SupabaseSessionStore.clear()
        state = .signedOut
        profile = nil
    }

    /// Make sure a profile row exists so foreign keys (posts, follows, watchlists) resolve.
    private func ensureProfile(wallet: String) async throws {
        struct Row: Encodable { let wallet: String }
        let _: SocialProfile = try await client.upsert("profiles", Row(wallet: wallet), onConflict: "wallet")
    }

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
