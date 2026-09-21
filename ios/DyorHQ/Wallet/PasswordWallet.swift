import CommonCrypto
import CryptoKit
import DyorKit
import Foundation

/// Deterministic email + password wallet. The private key is derived from the password (email as salt) with a slow
/// KDF and NEVER stored anywhere but this device's Keychain — the same email + password always regenerate the same
/// wallet on any device, so there is no server, no backup, and no verification code.
///
/// This is a "brainwallet": its security is exactly the strength of the password, and a wrong password silently
/// derives a *different* wallet. That is why sign-up enforces a strong password (`PasswordStrength`) and the UI is
/// blunt that the password IS the wallet and cannot be reset. Users who want stronger guarantees use a passkey or
/// import their own key.
enum PasswordWallet {
    /// Domain separation + version. Bump only with a migration — changing it changes every derived address.
    private static let version = "dyorhq.email-password.v1"
    /// PBKDF2-HMAC-SHA256 rounds. High enough that an offline guess costs ~a second on commodity hardware, while a
    /// single on-device derivation stays well under a second. (Memory-hard scrypt/Argon2 would be stronger but isn't
    /// in this build's crypto stack; the dominant defense here is the enforced password strength.)
    private static let iterations: UInt32 = 1_000_000

    /// Derive the wallet for `(email, password)`. Pure and deterministic. Run off the main actor — it takes ~a second.
    static func deriveAccount(email: String, password: String) -> Secp256k1Account? {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else { return nil }
        // Salt binds the key to this app + version + the exact email, so the same password under different emails
        // yields different wallets and a single rainbow table can't cover every user.
        let salt = Data(SHA256.hash(data: Data("\(version)|\(normalizedEmail)".utf8)))
        guard let seed = pbkdf2(password: Data(password.utf8), salt: salt, keyLength: 32) else { return nil }
        // seed (32 bytes) → BIP-39 (24 words) → seed → BIP-32 m/44'/60'/0'/0/0 — DyorKit's proven derivation.
        return Mera.evmAccount(prf: seed)
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

/// Sign-up password rules. Because the password IS the wallet key and can be brute-forced offline by anyone who
/// knows the email, weak passwords are rejected outright — enforcement is the main thing standing between a user and
/// a drained wallet.
enum PasswordStrength {
    static let minLength = 12

    /// A 0…4 score for the strength meter.
    static func score(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var score = 0
        if password.count >= minLength { score += 1 }
        if password.count >= 16 { score += 1 }
        if classes(password) >= 3 { score += 1 }
        if password.count >= minLength, classes(password) >= 3, !isPredictable(password) { score += 1 }
        return min(score, 4)
    }

    /// `nil` when the password is acceptable, otherwise a short reason to show and block sign-up on.
    static func rejection(_ password: String, email: String) -> String? {
        if password.count < minLength { return "Use at least \(minLength) characters." }
        if classes(password) < 3 { return "Mix uppercase, lowercase, numbers and symbols (any three)." }
        if isPredictable(password) { return "Too predictable — avoid repeats and simple sequences." }
        let lower = password.lowercased()
        if blocked.contains(lower) { return "That password is too common." }
        for weak in ["password", "dyorhq", "qwerty", "letmein", "monad", "crypto", "wallet"] where lower.contains(weak) {
            return "Avoid common words like “\(weak)”."
        }
        let localPart = email.split(separator: "@").first.map { $0.lowercased() } ?? ""
        if localPart.count >= 3, lower.contains(localPart) { return "Don’t base your password on your email." }
        return nil
    }

    private static func classes(_ password: String) -> Int {
        var found = 0
        if password.contains(where: \.isLowercase) { found += 1 }
        if password.contains(where: \.isUppercase) { found += 1 }
        if password.contains(where: \.isNumber) { found += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { found += 1 }
        return found
    }

    /// All one character, or a run of sequential characters (abcd / 1234) covering most of the password.
    private static func isPredictable(_ password: String) -> Bool {
        let chars = Array(password)
        if Set(chars).count <= 2 { return true }
        var longestRun = 1, run = 1
        for i in 1..<chars.count {
            guard let a = chars[i - 1].asciiValue, let b = chars[i].asciiValue else { run = 1; continue }
            if b == a + 1 || b == a - 1 { run += 1; longestRun = max(longestRun, run) } else { run = 1 }
        }
        return longestRun >= max(4, chars.count - 2)
    }

    private static let blocked: Set<String> = [
        "password123!", "password1234", "letmein12345", "qwerty123456", "iloveyou1234",
        "admin1234567", "welcome12345", "abcd1234!@#$", "aaaaaaaaaaaa", "123456789012",
    ]
}
