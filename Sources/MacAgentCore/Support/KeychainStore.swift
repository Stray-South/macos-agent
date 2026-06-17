import Foundation
import Security

// Keychain wrapper for the Anthropic API key.
// Generic password: service = app bundle ID, account = "anthropic-api-key".
// Works in unsigned dev builds — no keychain-access-groups entitlement required
// until the app is sandboxed.
public enum KeychainStore {
    // Hardcoded rather than Bundle.main.bundleIdentifier — the smoke-test and unit-test
    // executables have different bundle contexts and intentionally do not share this slot.
    public static let defaultService = "com.southernreach.macos-agent-v0"
    private static let account = "anthropic-api-key"

    /// Read the API key from Keychain. The `service` parameter exists so unit tests
    /// can use an isolated identifier (e.g. a UUID per test) and never touch the
    /// developer's real key slot. Production callers omit it and use `defaultService`.
    public static func read(service: String = defaultService) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    public static func save(_ key: String, service: String = defaultService) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        // Try update first; add if item not yet in Keychain.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    public static func delete(service: String = defaultService) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case saveFailed(OSStatus)

    public var errorDescription: String? {
        if case .saveFailed(let status) = self {
            return "Could not save key to Keychain (OSStatus \(status))."
        }
        return nil
    }
}
