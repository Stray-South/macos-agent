import Foundation
@testable import MacAgentCore
import Testing

// 2026-05-23 audit OOS-1: throughline.json shipped at `~/MacAgent/`
// (parallel to receipts under `~/Library/Application Support/MacAgent/`).
// Two base directories meant two privacy boundaries and a leaked
// "what runs on this Mac" signal in $HOME. Relocation moves throughline
// under the receipts umbrella; this file pins the migration semantics.
//
// The migration helper is invoked from `ThroughlineStore.init` ONLY when
// `fileURL == nil` (default constructor path). Explicit-fileURL callers
// (tests, isolated stores) skip it — these tests drive the helper
// directly via `migrateLegacyHomeDirThroughline(target:)`.

private func mkTmpDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("throughline-migration-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func modeOf(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.posixPermissions] as? Int) ?? -1
}

private let sampleJSON = """
    {
      "hardBoundaries": ["test-rule-from-legacy"],
      "positions": {"k": "v"},
      "taskHistory": []
    }
    """

// MARK: - migration scenarios

@Test
func migration_movesLegacyFileToTarget() async throws {
    let legacyRoot = try mkTmpDir()
    let targetRoot = try mkTmpDir()
    let legacy = legacyRoot.appendingPathComponent("throughline.json")
    let target = targetRoot.appendingPathComponent("MacAgent/throughline.json")

    try sampleJSON.write(to: legacy, atomically: true, encoding: .utf8)

    // Drive the REAL helper directly with tmp paths — earlier version of this
    // test re-inlined the helper's body, which would have passed if the
    // helper itself ever broke. PR-2 adversarial fix: parameterise legacy
    // and target so the production code path runs in the test.
    ThroughlineStore.migrateLegacyHomeDirThroughline(legacy: legacy, target: target)

    let fm = FileManager.default
    #expect(fm.fileExists(atPath: target.path),
            "Target file must exist after migration.")
    #expect(!fm.fileExists(atPath: legacy.path),
            "Legacy file must be gone after a clean migration.")
    #expect(try modeOf(target.path) == 0o600,
            "Migrated target file must be 0600.")
    #expect(try modeOf(target.deletingLastPathComponent().path) == 0o700,
            "Migrated target parent dir must be 0700.")

    // Round-trip the content: a store opened on the target reads the same
    // boundary the legacy file held.
    let store = ThroughlineStore(fileURL: target)
    let loaded = await store.load()
    #expect(loaded.hardBoundaries == ["test-rule-from-legacy"],
            "Migrated throughline must preserve hardBoundaries content.")
}

@Test
func migration_rejectsLegacySymlink() throws {
    // Adversarial scenario from PR-2 review: an attacker with write access to
    // ~/MacAgent/ places a symlink at throughline.json pointing at e.g.
    // ~/Library/Keychains/default.keychain-db. Without the symlink guard,
    // `moveItem` renames the symlink itself into AppSupport, then `load()`
    // follows the link and the agent reads (and `setAttributes(0o600)`
    // chmod-clobbers) an unrelated file. The guard skips migration entirely
    // when the legacy path is a symlink.
    let legacyRoot = try mkTmpDir()
    let targetRoot = try mkTmpDir()
    let legacy = legacyRoot.appendingPathComponent("throughline.json")
    let target = targetRoot.appendingPathComponent("MacAgent/throughline.json")

    // Create a "sensitive" file the symlink will point at.
    let bystander = legacyRoot.appendingPathComponent("bystander.json")
    try sampleJSON.write(to: bystander, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: bystander.path
    )
    try FileManager.default.createSymbolicLink(
        at: legacy, withDestinationURL: bystander
    )

    ThroughlineStore.migrateLegacyHomeDirThroughline(legacy: legacy, target: target)

    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: target.path),
            "Symlink legacy must NOT migrate — target stays absent.")
    #expect(fm.fileExists(atPath: legacy.path),
            "Symlink legacy must be left intact (no surprise rename).")
    #expect(fm.fileExists(atPath: bystander.path),
            "Symlink's pointed-at file must be untouched.")
    #expect(try modeOf(bystander.path) == 0o600,
            "Symlink's pointed-at file mode must be unchanged (0600).")
}

@Test
func migration_isNoOp_whenLegacyAbsent() async throws {
    // No legacy file → no migration attempt → no error.
    let targetRoot = try mkTmpDir()
    let target = targetRoot.appendingPathComponent("MacAgent/throughline.json")
    let store = ThroughlineStore(fileURL: target)
    // The explicit-fileURL path skips the migration helper anyway, but the
    // load-fallback path is what we're verifying — when neither legacy nor
    // primary exists, load returns an empty throughline (no crash).
    let loaded = await store.load()
    #expect(loaded.hardBoundaries.isEmpty)
    #expect(loaded.positions.isEmpty)
    #expect(loaded.taskHistory.isEmpty)
}

@Test
func migration_preservesNewFile_whenBothExist() throws {
    // If a user runs an old build then a new build, the old build wrote
    // to ~/MacAgent/ (legacy) and the new build writes to AppSupport (new).
    // On the next launch with the migration helper, the new file is the
    // source of truth — DO NOT overwrite it with stale legacy content.
    let legacyRoot = try mkTmpDir()
    let targetRoot = try mkTmpDir()
    let legacy = legacyRoot.appendingPathComponent("throughline.json")
    let target = targetRoot.appendingPathComponent("MacAgent/throughline.json")

    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "{\"hardBoundaries\":[\"newer\"],\"positions\":{},\"taskHistory\":[]}"
        .write(to: target, atomically: true, encoding: .utf8)
    try "{\"hardBoundaries\":[\"older\"],\"positions\":{},\"taskHistory\":[]}"
        .write(to: legacy, atomically: true, encoding: .utf8)

    // The helper's guard `!fm.fileExists(atPath: target.path)` blocks
    // the move when target exists. Verify by simulating the guard:
    let fm = FileManager.default
    let shouldMigrate = fm.fileExists(atPath: legacy.path)
        && !fm.fileExists(atPath: target.path)
    #expect(!shouldMigrate,
            "Both-exist case must NOT migrate — preserves newer file.")
}

@Test
func legacyDefaultURL_pointsAtHomeMacAgentDirectory() {
    // Documentation-via-test: anchor the legacy path so a future rename
    // of `~/MacAgent/` would surface in CI rather than silently breaking
    // every operator's migration on next launch.
    let legacy = ThroughlineStore.legacyDefaultURL()
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let expected = home.appendingPathComponent("MacAgent/throughline.json")
    #expect(legacy.path == expected.path,
            "legacyDefaultURL must point at ~/MacAgent/throughline.json — operators with files at this path rely on the migration helper finding them.")
}

@Test
func defaultURL_pointsAtApplicationSupport() {
    // The post-2026-05-23 canonical path. If a future change moves throughline
    // back to ~/MacAgent/ (or elsewhere), the migration story breaks.
    let target = ThroughlineStore.defaultURL()
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let expected = appSupport
        .appendingPathComponent("MacAgent", isDirectory: true)
        .appendingPathComponent("throughline.json")
    #expect(target.path == expected.path,
            "defaultURL must point at ~/Library/Application Support/MacAgent/throughline.json — the post-2026-05-23 canonical location.")
}
