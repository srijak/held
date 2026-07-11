import Foundation
import Security

/// Minimal Keychain string storage — used for the GitHub token so it
/// never sits in UserDefaults/plist backups in plaintext.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.srijak.held",
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String, key: String) {
        var q = query(key)
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
