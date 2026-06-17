import Foundation
@testable import MacAgentCore
import Testing

// 2026-05-23 audit: throughline.json shipped at default umask (0644
// world-readable) while receipts were 0600. Throughline holds operator hard
// rules + learned positions + 20 task records — same privacy class as
// receipts (which include typed text). F4 brings the two stores to parity.

private func modeOf(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.posixPermissions] as? Int) ?? -1
}

@Test
func throughlineStore_persistsJSONAt0600() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("throughline.json")
    let store = ThroughlineStore(fileURL: tmp)
    var t = AgentThroughline()
    t.addBoundary("audit test rule")
    await store.save(t)

    let mode = try modeOf(tmp.path)
    #expect(mode == 0o600,
            "Throughline JSON must be mode 0600. Got: \(String(format: "0%o", mode))")
}

@Test
func throughlineStore_tightensParentDirectoryTo0700() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = parent.appendingPathComponent("throughline.json")
    let store = ThroughlineStore(fileURL: file)
    await store.save(AgentThroughline())

    let mode = try modeOf(parent.path)
    #expect(mode == 0o700,
            "Throughline parent dir must be 0700. Got: \(String(format: "0%o", mode))")
}

@Test
func throughlineStore_reAppliesModeAfterRepeatedAtomicWrites() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("throughline.json")
    let store = ThroughlineStore(fileURL: tmp)
    await store.save(AgentThroughline())
    await store.save(AgentThroughline())
    await store.save(AgentThroughline())

    let mode = try modeOf(tmp.path)
    #expect(mode == 0o600,
            "After repeated atomic writes the throughline must still be 0600 — chmod must re-apply per save.")
}

@Test
func throughlineStore_initMigratesExistingFileTo0600() async throws {
    // Simulate a pre-2026-05-23 throughline file at 0644 by writing it
    // directly (bypassing save()), then constructing a Store and checking
    // the init-time migration tightened the perms.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent("throughline.json")
    try "{}".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)

    // Construct the store; init's tightenPermissions should fire.
    _ = ThroughlineStore(fileURL: file)

    #expect(try modeOf(file.path) == 0o600,
            "init() must migrate a pre-existing file from 0644 → 0600 (one-shot at construction).")
    #expect(try modeOf(tmp.path) == 0o700,
            "init() must tighten the parent dir 0755 → 0700.")
}
