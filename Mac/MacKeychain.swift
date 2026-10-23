import Foundation
import Security

/// The host's Keychain items: box URL, token and device id, in the data protection keychain under
/// the access group the widget extension shares (the same item names as the iOS app, so
/// `SharedStore.boxCredentials()` reads them in the widget). The token is never printed.
enum MacKeychain {
    enum Key: String, CaseIterable {
        case url = "box_url"
        case token = "token"
        case device = "device_id"
    }

    private static func base(_ key: Key) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedStore.appBundleID,
            kSecAttrAccount as String: key.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = SharedStore.keychainGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func string(_ key: Key) -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty deletes the item.
    static func set(_ value: String?, for key: Key) throws {
        SecItemDelete(base(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = base(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
    }
}
