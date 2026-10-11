import Foundation

/// base64url (RFC 4648 §5) with no padding: Mera's vault fields and passkey credential ids (`Mera.Base64URL`), and
/// Perpl's signatures, nonces and enrolled public keys (`PerplAuth.base64url`).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
