import Foundation
import Security

enum KeychainHelper: Sendable {
    private nonisolated static let service = "com.voicescribe"

    nonisolated static func save(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Delete if value is empty
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }

        // Try to update existing item first (avoids delete+add race)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[Keychain] Failed to add key '\(key)': \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            print("[Keychain] Failed to update key '\(key)': \(updateStatus)")
        }
    }

    static func load(key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] Failed to load key '\(key)': \(status)")
        }

        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
