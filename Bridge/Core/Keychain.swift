import Foundation
import Security

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain error \(status)" }
}

/// Generic-password Keychain wrapper. Items are readable after first unlock so background tasks can use them.
struct KeychainStore: Sendable {
    var service = AppInfo.bundleID

    func string(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) throws {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

struct BridgeConfig: Sendable, Equatable {
    let baseURL: URL
    let token: String
    let deviceId: String
}

/// Box URL, token and device id all live in the Keychain. The token is never logged or displayed.
enum ConfigStore {
    private static let keychain = KeychainStore()
    private enum Key {
        static let url = "box_url"
        static let token = "token"
        static let device = "device_id"
    }

    static func load() -> BridgeConfig? {
        guard let raw = keychain.string(for: Key.url), let url = URL(string: raw),
              let token = keychain.string(for: Key.token),
              let device = keychain.string(for: Key.device) else { return nil }
        return BridgeConfig(baseURL: url, token: token, deviceId: device)
    }

    static var savedURL: String? { keychain.string(for: Key.url) }
    static var savedDeviceId: String? { keychain.string(for: Key.device) }
    static var hasToken: Bool { keychain.string(for: Key.token) != nil }

    /// `token` nil or empty keeps the existing token.
    static func save(url: String, token: String?, deviceId: String) throws {
        let parsed = try BoxClient.validatedBaseURL(url)
        let device = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.isEmpty else { throw BoxError.missingDeviceId }
        try keychain.set(parsed.absoluteString, for: Key.url)
        try keychain.set(device, for: Key.device)
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try keychain.set(token, for: Key.token)
        }
    }
}
