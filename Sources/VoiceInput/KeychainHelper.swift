import Foundation
import Security

/// Minimal generic-password Keychain wrapper for secrets.
/// LLM keys key by their profile UUID (account = id); secrets without a
/// profile — e.g. the single remote-ASR key — key by a fixed string
/// account. Service = bundle id for both.
enum KeychainHelper {
    static let service = "com.voiceinput.app"

    static func set(key: String, for account: UUID) {
        set(key: key, account: account.uuidString)
    }

    static func key(for account: UUID) -> String {
        key(account: account.uuidString)
    }

    static func delete(account: UUID) {
        delete(account: account.uuidString)
    }

    static func set(key: String, account: String) {
        let data = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if key.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func key(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
