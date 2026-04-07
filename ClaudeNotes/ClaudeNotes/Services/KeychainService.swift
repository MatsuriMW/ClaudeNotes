import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed: \(status)"
        case .loadFailed(let status):
            return "Keychain load failed: \(status)"
        case .deleteFailed(let status):
            return "Keychain delete failed: \(status)"
        case .unexpectedData:
            return "Unexpected keychain data format"
        }
    }
}

final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let service = "com.claudenotes.api-key"

    private init() {}

    // MARK: - Multi-provider API Key Support

    private func account(for providerId: String) -> String {
        "\(providerId)-api-key"
    }

    func saveAPIKey(_ key: String, for providerId: String = "claude") throws {
        guard let data = key.data(using: .utf8) else { return }
        try? deleteAPIKey(for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func loadAPIKey(for providerId: String = "claude") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func deleteAPIKey(for providerId: String = "claude") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func hasAPIKey(for providerId: String = "claude") -> Bool {
        loadAPIKey(for: providerId) != nil
    }

    // Legacy compatibility
    func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, for: "claude")
    }

    func loadAPIKey() -> String? {
        loadAPIKey(for: "claude")
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(for: "claude")
    }

    var hasAPIKey: Bool {
        hasAPIKey(for: "claude")
    }
}
