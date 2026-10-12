import Foundation
import Security

/// Secrets the user enters (like an endpoint token) live in their Keychain, never in settings files or the repo.
enum Keychain {
    private static let service = "local.kshud.KSHud"

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or removes the item when it is nil or empty.
    @discardableResult
    static func write(_ value: String?, for account: String) -> Bool {
        let query = baseQuery(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "KS HUD (\(account))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
