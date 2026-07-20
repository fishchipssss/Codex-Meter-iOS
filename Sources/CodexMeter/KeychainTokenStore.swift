import Foundation
import Security
import CodexMeterCore

enum KeychainTokenStore {
    private static let service = "com.picklemike.codexmeter.auth"
    private static let legacyAccount = "chatgpt-oauth-v1"
    private static let accountPrefix = "chatgpt-oauth-v2:"

    static func save(_ tokens: AuthTokens) throws {
        guard !tokens.accountId.isEmpty else {
            throw MeterError.message("ChatGPT did not return an account identifier.")
        }
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountPrefix + tokens.accountId
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MeterError.message("Could not save credentials in Keychain (\(status)).")
        }
    }

    static func load(accountId: String) -> AuthTokens? {
        load(keychainAccount: accountPrefix + accountId)
    }

    static func loadAll() -> [AuthTokens] {
        migrateLegacyAccountIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard
                let key = item[kSecAttrAccount as String] as? String,
                key.hasPrefix(accountPrefix),
                let data = item[kSecValueData as String] as? Data,
                let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data),
                tokens.isUsable
            else { return nil }
            return tokens
        }
        .sorted { lhs, rhs in
            let left = lhs.email.isEmpty ? lhs.accountId : lhs.email
            let right = rhs.email.isEmpty ? rhs.accountId : rhs.email
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    static func remove(accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountPrefix + accountId
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func load(keychainAccount: String) -> AuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let tokens = try? JSONDecoder().decode(AuthTokens.self, from: data),
            tokens.isUsable
        else { return nil }
        return tokens
    }

    private static func migrateLegacyAccountIfNeeded() {
        guard let tokens = load(keychainAccount: legacyAccount), !tokens.accountId.isEmpty else { return }
        try? save(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
