import Foundation

enum AccountNicknameStore {
    private static let key = "account-nicknames-v1"

    static func nickname(for accountID: String) -> String? {
        nicknames[accountID]
    }

    static func set(_ value: String?, for accountID: String) {
        var values = nicknames
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            values.removeValue(forKey: accountID)
        } else {
            values[accountID] = String(trimmed.prefix(40))
        }
        UserDefaults.standard.set(values, forKey: key)
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static var nicknames: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
