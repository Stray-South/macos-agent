import Foundation
@testable import MacAgentCore
import Testing

// Cluster F: CapabilityRuleStore.persist used to swallow errors silently.
// Now it surfaces the failure via `lastPersistError()` and logs to os_log
// so a future investigator can correlate "Always/Never approvals vanished"
// with disk-full / sandbox-denial conditions.

@Test
func capabilityRuleStore_persistFailure_surfacesViaLastPersistError() async throws {
    // Point the store at a path inside a non-existent root that the
    // surrounding FileManager.createDirectory call can't create either
    // (e.g. `/dev/null/...` — `/dev/null` is a character device, not a dir).
    // createDirectory throws, which is caught by persist's catch block,
    // and lastPersistError must surface the error.
    let unwritable = URL(fileURLWithPath: "/dev/null/cap-rules-test-\(UUID().uuidString)/rules.json")
    let store = CapabilityRuleStore(fileURL: unwritable)

    #expect(await store.lastPersistError() == nil,
            "Fresh store has no persist failure recorded.")

    // add() triggers persist() internally. The disk write must fail; rules
    // remain in memory but the error must be retrievable.
    let rule = CapabilityRule(
        verdict: .allow, actionType: .click,
        appBundleID: "com.example",
        labelPattern: "OK"
    )
    await store.add(rule)

    let inMemory = await store.allRules()
    #expect(inMemory.count == 1,
            "Rule must remain in memory even if disk persist failed.")
    let recorded = await store.lastPersistError()
    #expect(recorded != nil,
            "Disk-write failure must be surfaced via lastPersistError() — pre-fix this was silently swallowed.")
}

// MARK: - F4: file mode parity (2026-05-23 audit)

private func modeOf(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.posixPermissions] as? Int) ?? -1
}

@Test
func capabilityRuleStore_persistsJSONAt0600() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("capability-rules.json")
    let store = CapabilityRuleStore(fileURL: tmp)
    await store.add(CapabilityRule(
        verdict: .allow, actionType: .click,
        appBundleID: "com.example", labelPattern: "OK"
    ))
    let mode = try modeOf(tmp.path)
    #expect(mode == 0o600,
            "Capability-rules JSON must be 0600. Got: \(String(format: "0%o", mode))")
}

@Test
func capabilityRuleStore_tightensParentDirectoryTo0700() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = parent.appendingPathComponent("capability-rules.json")
    let store = CapabilityRuleStore(fileURL: file)
    await store.add(CapabilityRule(verdict: .allow, actionType: .click))
    let mode = try modeOf(parent.path)
    #expect(mode == 0o700,
            "Capability-rules parent dir must be 0700. Got: \(String(format: "0%o", mode))")
}

@Test
func capabilityRuleStore_initMigratesExistingFileTo0600() async throws {
    // Simulate a pre-2026-05-23 capability-rules.json at 0644 by writing it
    // directly, then constructing a Store and checking init migrated perms.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent("capability-rules.json")
    try "[]".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)

    _ = CapabilityRuleStore(fileURL: file)

    #expect(try modeOf(file.path) == 0o600,
            "init() must migrate a pre-existing file from 0644 → 0600.")
    #expect(try modeOf(tmp.path) == 0o700,
            "init() must tighten the parent dir 0755 → 0700.")
}

@Test
func capabilityRuleStore_persistSuccess_clearsLastError() async throws {
    // Recovery path: a previously-failed persist clears `lastPersistError`
    // once a subsequent persist succeeds.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("rules.json")
    let store = CapabilityRuleStore(fileURL: tmp)

    let rule = CapabilityRule(
        verdict: .allow, actionType: .click,
        appBundleID: "com.example",
        labelPattern: "OK"
    )
    await store.add(rule)
    #expect(await store.lastPersistError() == nil,
            "Persist into a writable path must succeed and lastPersistError must stay nil.")
}
