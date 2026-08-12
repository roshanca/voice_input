import Foundation
import Security

/// Minimal generic-password Keychain wrapper for LLM API keys.
/// Account = LLMConfig UUID string, service = bundle id.
enum KeychainHelper {
    static let service = "com.voiceinput.app"

    static func set(key: String, for account: UUID) {
        let accountString = account.uuidString
        let data = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountString
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

    static func key(for account: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
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

    static func delete(account: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
