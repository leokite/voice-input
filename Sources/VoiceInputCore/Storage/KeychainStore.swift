import Foundation
import Security

public enum KeychainStore {
    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    /// Soniox の API キー。
    public static let sonioxAccount = "apiKey"
    /// OpenAI の API キー（直した単語の置き換え元を探すのに使う）。
    public static let openAIAccount = "openaiApiKey"

    private static func baseQuery(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves the key, replacing any existing item.
    public static func saveAPIKey(_ key: String, service: String = "dev.ykazama.VoiceInput",
                                  account: String = sonioxAccount) throws {
        deleteAPIKey(service: service, account: account)
        var query = baseQuery(service, account)
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func loadAPIKey(service: String = "dev.ykazama.VoiceInput", account: String = sonioxAccount) -> String? {
        var query = baseQuery(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteAPIKey(service: String = "dev.ykazama.VoiceInput", account: String = sonioxAccount) {
        SecItemDelete(baseQuery(service, account) as CFDictionary)
    }
}
