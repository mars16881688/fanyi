import Foundation
import Security

/// Stores the API key as a generic password (service ai.mars.suiyi).
/// The value is cached in memory after the first successful read so the
/// Keychain is not queried on every request.
@MainActor
enum Keychain {
    static let service = "ai.mars.suiyi"
    static let account = "api-key"
    /// Service used before the rename to 随译. Read once during migration, never written.
    static let legacyService = "ai.mars.fanyi"

    private static var cachedKey: String?
    private static var didLoad = false

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func apiKey() -> String? {
        if didLoad { return cachedKey }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let key = String(data: data, encoding: .utf8) {
                cachedKey = key.trimmed
            } else {
                cachedKey = nil
            }
            didLoad = true
        case errSecItemNotFound:
            cachedKey = nil
            didLoad = true
        default:
            // e.g. the user denied access; try again next time.
            return nil
        }
        return cachedKey
    }

    /// Returns the key stored by the pre-rename Fanyi app, if any. macOS may ask
    /// the user once to allow access, because the item belongs to the old app.
    static func legacyAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8)?.trimmed,
              !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or, for an empty string, deletes) the key. Returns an OSStatus.
    @discardableResult
    static func setAPIKey(_ newValue: String) -> OSStatus {
        let key = newValue.trimmed
        if key.isEmpty {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                cachedKey = nil
                didLoad = true
                return errSecSuccess
            }
            return status
        }
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "随译 API Key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            cachedKey = key
            didLoad = true
        }
        return status
    }
}
