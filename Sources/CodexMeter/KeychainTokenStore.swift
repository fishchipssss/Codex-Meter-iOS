import Foundation
import Security
import CodexMeterCore

enum KeychainTokenStore {
    static let repository = AccountCredentialRepository(storage: KeychainCredentialStorage(service: "com.picklemike.codexmeter.auth"))

    static func load(accountId: String) -> AuthTokens? { repository.load(localAccountId: accountId) }
    static func loadAll() -> [AuthTokens] { repository.loadAll() }
    static func remove(accountId: String) throws { try repository.remove(localAccountId: accountId) }
    static func clearAll() throws { try repository.clearAll() }
}

/// Tests inject a unique service. Production retains the existing service and
/// accessibility, with a separate v3 account for each local identity.
struct KeychainCredentialStorage: CredentialStorage {
    let service: String

    func items() throws -> [String: Data] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        try check(status)
        var items: [String: Data] = [:]
        for item in result as? [[String: Any]] ?? [] {
            if let key = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data { items[key] = data }
        }
        return items
    }

    func write(_ data: Data, for key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove(_ key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func removeAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw MeterError.message("Could not update credentials in Keychain (\(status)).") }
    }
}
