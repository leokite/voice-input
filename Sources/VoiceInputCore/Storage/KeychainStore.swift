import Foundation
import Security

public enum KeychainStore {
    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    private static let account = "apiKey"

    private static func baseQuery(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves the key, replacing any existing item.
    public static func saveAPIKey(_ key: String, service: String = "dev.ykazama.VoiceInput") throws {
        deleteAPIKey(service: service)
        var query = baseQuery(service)
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func loadAPIKey(service: String = "dev.ykazama.VoiceInput") -> String? {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteAPIKey(service: String = "dev.ykazama.VoiceInput") {
        SecItemDelete(baseQuery(service) as CFDictionary)
    }
}
