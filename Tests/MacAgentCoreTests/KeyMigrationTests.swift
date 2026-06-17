import Foundation
@testable import MacAgentCore
import Testing

// Cluster A: Keychain-only API key with one-shot migration from the legacy
// plaintext fallback file. Every test uses a unique per-test Keychain service
// string so we never touch the developer's real `defaultService` slot.
//
// Test isolation contract: each test:
//   1. Generates a fresh `service = "test-<UUID>"`
//   2. Operates against a temp file path (NSTemporaryDirectory + UUID)
//   3. Cleans up the Keychain entry via KeychainStore.delete(service:) on exit

@Test
func migrateLegacyAgentFile_movesKeyToKeychainAndDeletesFile() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try "test-key-abc123\n".write(to: tmp, atomically: true, encoding: .utf8)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }

    let returned = ClaudeLLMClient.migrateLegacyAgentFile(at: tmp.path, service: service)
    #expect(returned == "test-key-abc123",
            "Whitespace-trimmed file contents must be returned for the current session.")
    #expect(KeychainStore.read(service: service) == "test-key-abc123",
            "Key must be persisted to Keychain under the supplied service identifier.")
    #expect(!FileManager.default.fileExists(atPath: tmp.path),
            "Plaintext fallback file must be deleted after successful migration.")
}

@Test
func migrateLegacyAgentFile_returnsNilWhenFileAbsent() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }
    #expect(ClaudeLLMClient.migrateLegacyAgentFile(at: tmp.path, service: service) == nil,
            "Missing file returns nil without touching Keychain.")
    #expect(KeychainStore.read(service: service) == nil,
            "Keychain entry must not be created on absent-file path.")
}

@Test
func migrateLegacyAgentFile_returnsNilWhenFileEmpty() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try "   \n  ".write(to: tmp, atomically: true, encoding: .utf8)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }

    #expect(ClaudeLLMClient.migrateLegacyAgentFile(at: tmp.path, service: service) == nil,
            "Whitespace-only file is treated as absent key.")
    #expect(KeychainStore.read(service: service) == nil,
            "Keychain must not receive whitespace.")
    // File MAY still exist (we don't delete files without a valid key) — invariant
    // is only that Keychain wasn't polluted.
}

@Test
func borrowAnthropicCLIKey_readsButNeverWritesOrDeletes() throws {
    // Anthropic CLI's key file is a different tool's secret — we read it for the
    // current session but must never sync it into our Keychain slot and must
    // never delete it.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try "anthropic-cli-key-xyz\n".write(to: tmp, atomically: true, encoding: .utf8)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service); try? FileManager.default.removeItem(at: tmp) }

    let borrowed = ClaudeLLMClient.borrowAnthropicCLIKey(at: tmp.path)
    #expect(borrowed == "anthropic-cli-key-xyz",
            "Anthropic CLI key file content must be returned for the current session.")
    #expect(KeychainStore.read(service: service) == nil,
            "borrow path must NEVER promote a different tool's key into our Keychain slot.")
    #expect(FileManager.default.fileExists(atPath: tmp.path),
            "Anthropic CLI key file must never be deleted by us.")
}

@Test
func borrowAnthropicCLIKey_returnsNilWhenAbsent() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    #expect(ClaudeLLMClient.borrowAnthropicCLIKey(at: tmp.path) == nil)
}

@Test
func saveKey_purgesLegacyAgentFileIfPresent() throws {
    // Settings-UI-driven save flow: writing to Keychain triggers cleanup of any
    // leftover plaintext file from a pre-Cluster-A build. The file is no longer
    // the fallback path and shouldn't sit on disk in cleartext.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try "stale-key-on-disk\n".write(to: tmp, atomically: true, encoding: .utf8)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }

    try ClaudeLLMClient.saveKey("fresh-key-from-settings",
                                service: service,
                                legacyPath: tmp.path)
    #expect(KeychainStore.read(service: service) == "fresh-key-from-settings",
            "Keychain receives the new key under the test service slot.")
    #expect(!FileManager.default.fileExists(atPath: tmp.path),
            "saveKey must purge any pre-Cluster-A leftover plaintext file at the given legacyPath.")
}

@Test
func saveKey_noOpOnLegacyPathWhenFileAbsent() throws {
    // saveKey on a fresh installation should not error or create the legacy file.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let service = "test-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }

    try ClaudeLLMClient.saveKey("clean-install-key",
                                service: service,
                                legacyPath: tmp.path)
    #expect(KeychainStore.read(service: service) == "clean-install-key")
    #expect(!FileManager.default.fileExists(atPath: tmp.path),
            "Legacy file path must remain absent — saveKey never creates the plaintext file.")
}
