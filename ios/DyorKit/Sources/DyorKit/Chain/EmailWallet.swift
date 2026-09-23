import BigInt
import CommonCrypto
import CryptoKit
import Foundation

/* The email + password wallet's key derivation. Two generations share one slow step:

     S       PBKDF2-HMAC-SHA256(password, salt: sha256("dyorhq.email-password.v1|" + email), 1,000,000 rounds), 32 bytes
     legacy  S → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/0        — accounts created before v2
     v2      e = sha256("dyorhq/email-pepper/v1/email:" + email)
             t = sha256("dyorhq/email-pepper/v1/t:" || S)
             p = the `email-pepper` Edge Function's HMAC of (e, t) under a key only the server holds
             key = HKDF-SHA256(ikm: S || p, salt: "dyorhq/email-wallet/v2", info: "secp256k1"), 32 bytes

   The legacy wallet is a brainwallet: anyone who knows the email can test password guesses offline. v2 mixes in p,
   which only the server can compute, so every guess costs a rate-limited server round-trip. The server sees only e
   and t — hashes, never the email, the password or S — so a compromised server is no better off than an attacker is
   against the legacy scheme. Every constant here is part of the derived addresses: never change one. Test vectors
   (EmailWalletTests) were computed independently with Python's hashlib/hmac and eth_account. */
public enum EmailWallet {
    /// Legacy domain separation + version (the PBKDF2 salt prefix). Defines every legacy address.
    private static let legacyVersion = "dyorhq.email-password.v1"
    /// PBKDF2-HMAC-SHA256 rounds for S: an offline guess costs ~a second on commodity hardware, a single on-device
    /// derivation stays well under one.
    private static let iterations: UInt32 = 1_000_000
    private static let pepperEmailLabel = "dyorhq/email-pepper/v1/email:"
    private static let pepperSeedLabel = "dyorhq/email-pepper/v1/t:"
    private static let v2Salt = "dyorhq/email-wallet/v2"
    private static let v2Info = "secp256k1"
    /// How many HKDF candidates to try before giving up. A candidate is invalid with probability ~2⁻¹²⁸, so the
    /// bound is never reached in practice; it only keeps a broken validity check from looping forever.
    static let maxV2Attempts = 256

    /// The email exactly as the derivation sees it: trimmed and lowercased.
    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Legacy (and v2's input)

    /// S: the slow, password-derived 32-byte seed both generations start from. Pure and deterministic; takes ~a
    /// second, so run it off the main actor. Nil for an empty email or password.
    public static func legacySeed(email: String, password: String) -> Data? {
        let normalizedEmail = normalize(email)
        guard !normalizedEmail.isEmpty, !password.isEmpty else { return nil }
        // Salt binds the key to this app + version + the exact email, so the same password under different emails
        // yields different wallets and a single rainbow table can't cover every user.
        let salt = Data(SHA256.hash(data: Data("\(legacyVersion)|\(normalizedEmail)".utf8)))
        return pbkdf2(password: Data(password.utf8), salt: salt, keyLength: 32)
    }

    /// The legacy wallet for S: seed (32 bytes) → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/0.
    public static func legacyAccount(seed: Data) -> Secp256k1Account? {
        Mera.evmAccount(prf: seed)
    }

    // MARK: v2 (server-peppered)

    /// What the `email-pepper` function is sent: e names the email, t commits to S. Both are one-way hashes.
    public static func pepperInput(email: String, seed: Data) -> (e: Data, t: Data) {
        let e = Data(SHA256.hash(data: Data((pepperEmailLabel + normalize(email)).utf8)))
        let t = Data(SHA256.hash(data: Data(pepperSeedLabel.utf8) + seed))
        return (e, t)
    }

    /// The v2 private key: HKDF-SHA256(S || p). A candidate that is not a valid secp256k1 scalar (0 or ≥ n) is
    /// skipped by re-deriving with info "secp256k1/1", "secp256k1/2", …. `isValid` is injectable only for tests.
    public static func v2PrivateKey(seed: Data, pepper: Data,
                                    isValid: (Data) -> Bool = isValidPrivateKey) -> Data? {
        let ikm = SymmetricKey(data: seed + pepper)
        for attempt in 0..<maxV2Attempts {
            let info = attempt == 0 ? v2Info : "\(v2Info)/\(attempt)"
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(v2Salt.utf8), info: Data(info.utf8),
                                             outputByteCount: 32)
            let candidate = key.withUnsafeBytes { Data($0) }
            if isValid(candidate) { return candidate }
        }
        return nil
    }

    /// The v2 wallet for S and the server pepper p.
    public static func v2Account(seed: Data, pepper: Data) -> Secp256k1Account? {
        v2PrivateKey(seed: seed, pepper: pepper).flatMap { Secp256k1Account(privateKey: $0) }
    }

    /// A usable secp256k1 private key: 32 bytes, 1 ≤ k < n.
    public static func isValidPrivateKey(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }
        let scalar = BigUInt(key)
        return scalar > 0 && scalar < Secp256k1Account.curveOrder
    }

    private static func pbkdf2(password: Data, salt: Data, keyLength: Int) -> Data? {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }
}
