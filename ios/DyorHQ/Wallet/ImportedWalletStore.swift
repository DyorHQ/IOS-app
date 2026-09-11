import DyorKit
import Foundation
import Security

/// Stores an imported wallet's raw private key in this device's Keychain and nowhere else: not synced to iCloud
/// (`ThisDeviceOnly`), never written to a server, never logged. The address is re-derived from the key on load, so
/// a tampered entry simply fails to load rather than signing for the wrong account.
enum ImportedWalletStore {
    private static let service = "fun.dyorhq.imported"
    private static let account = "primary"

    static func save(privateKey: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = privateKey
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false // explicit: never sync the key to iCloud Keychain
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAccount() -> Secp256k1Account? {
        guard let key = loadKey() else { return nil }
        return Secp256k1Account(privateKey: key)
    }

    static var exists: Bool { loadKey() != nil }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}
