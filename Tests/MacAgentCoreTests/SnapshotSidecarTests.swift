/// SnapshotSidecarTests.swift
///
/// Unit 19 — covers `SnapshotWriter` + `SnapshotReader` + the new
/// `ReceiptReplayFormatter.formatSnapshot` rendering path. All tests
/// use a temp-dir baseURL so the operator's real `~/Library/.../
/// MacAgent/snapshots/` is never touched.
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - Helpers

private func makeSnapshot(
    timestamp: Date = .now,
    bundleID: String = "com.test.app",
    hash: String = "abc123",
    elements: [UIElement] = [],
    visionObservations: [VisionObservation] = [],
    screenshotPNG: Data? = nil
) -> PerceptionSnapshot {
    PerceptionSnapshot(
        timestamp: timestamp,
        focusedAppBundleID: bundleID,
        elements: elements,
        hash: hash,
        visionObservations: visionObservations,
        visionIndexOffset: min(elements.count, 80),
        screenshotPNG: screenshotPNG,
        screenshotLogicalSize: screenshotPNG == nil ? nil : CodableSize(.init(width: 100, height: 100))
    )
}

private func makeTmpBaseURL() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - SnapshotWriter

@Test
func snapshotWriter_persistsRoundTrip() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)
    let original = makeSnapshot(
        bundleID: "com.test.app", hash: "round-trip-hash",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                      frame: CodableRect(.init(x: 10, y: 20, width: 80, height: 30)),
                      isEnabled: true, isVisible: true)
        ]
    )
    await writer.persist(original)

    // Reader should find it via the hash.
    let loaded = try SnapshotReader.load(hash: "round-trip-hash", baseURL: baseURL)
    let unwrapped = try #require(loaded)
    #expect(unwrapped.hash == original.hash)
    #expect(unwrapped.focusedAppBundleID == original.focusedAppBundleID)
    #expect(unwrapped.elements.count == 1)
    #expect(unwrapped.elements[0].label == "Submit")
}

@Test
func snapshotWriter_stripsScreenshotByDefault() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL, includeScreenshot: false)
    let original = makeSnapshot(
        hash: "with-screenshot",
        screenshotPNG: Data(repeating: 0xFF, count: 10_000)
    )
    await writer.persist(original)
    let loaded = try SnapshotReader.load(hash: "with-screenshot", baseURL: baseURL)
    let unwrapped = try #require(loaded)
    #expect(unwrapped.screenshotPNG == nil,
            "Default writer must strip screenshotPNG — disk-growth invariant")
    #expect(unwrapped.screenshotLogicalSize == nil,
            "screenshotLogicalSize is paired with screenshotPNG; both stripped")
}

@Test
func snapshotWriter_includesScreenshotWhenConfigured() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL, includeScreenshot: true)
    let payload = Data(repeating: 0xAB, count: 1024)
    let original = makeSnapshot(
        hash: "opt-in-screenshot",
        screenshotPNG: payload
    )
    await writer.persist(original)
    let loaded = try SnapshotReader.load(hash: "opt-in-screenshot", baseURL: baseURL)
    let unwrapped = try #require(loaded)
    #expect(unwrapped.screenshotPNG == payload,
            "Opt-in inclusion must preserve the PNG bytes verbatim")
}

@Test
func snapshotWriter_dedupesByHash() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)
    let snap = makeSnapshot(hash: "dupe-hash")
    await writer.persist(snap)

    // Capture mtime after first write.
    let dayFolder = baseURL
        .appendingPathComponent(yyyyMMdd(snap.timestamp), isDirectory: true)
    let file = dayFolder.appendingPathComponent("dupe-hash.json")
    let mtime1 = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

    // Brief sleep so an actual re-write would show a different mtime.
    try await Task.sleep(for: .milliseconds(50))

    await writer.persist(snap)
    let mtime2 = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    #expect(mtime1 == mtime2,
            "Dedupe-by-hash: second persist of identical hash must be a no-op (mtime unchanged)")
}

@Test
func snapshotWriter_appliesChmodAcrossAtomicReplace() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)
    let snap = makeSnapshot(hash: "chmod-test")
    await writer.persist(snap)

    // Re-write same hash would skip (dedupe). Use a fresh hash to
    // exercise the atomic-replace path that resets file attrs.
    let snap2 = makeSnapshot(hash: "chmod-test-2")
    await writer.persist(snap2)

    let dayFolder = baseURL.appendingPathComponent(yyyyMMdd(snap2.timestamp), isDirectory: true)
    let file = dayFolder.appendingPathComponent("chmod-test-2.json")

    // Real FileManager attribute check — verifies AGENTS.md
    // §Agent State Files chmod path holds across atomic replace.
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    let posix = try #require(attrs[.posixPermissions] as? NSNumber)
    #expect(posix.intValue == 0o600,
            "Snapshot files must be 0600 (AGENTS.md §Agent State Files). Got: \(String(posix.intValue, radix: 8))")

    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dayFolder.path)
    let dirPosix = try #require(dirAttrs[.posixPermissions] as? NSNumber)
    #expect(dirPosix.intValue == 0o700,
            "Snapshot day folder must be 0700. Got: \(String(dirPosix.intValue, radix: 8))")
}

@Test
func snapshotWriter_withoutScreenshot_preservesAllOtherFields() {
    let snap = makeSnapshot(
        hash: "strip-test",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "X", value: "v",
                      frame: CodableRect(.init(x: 1, y: 2, width: 3, height: 4)),
                      isEnabled: true, isVisible: true)
        ],
        screenshotPNG: Data([0xDE, 0xAD, 0xBE, 0xEF])
    )
    let stripped = SnapshotWriter.withoutScreenshot(snap)
    #expect(stripped.hash == snap.hash)
    #expect(stripped.focusedAppBundleID == snap.focusedAppBundleID)
    #expect(stripped.elements == snap.elements)
    #expect(stripped.visionObservations == snap.visionObservations)
    #expect(stripped.screenshotPNG == nil)
    #expect(stripped.screenshotLogicalSize == nil)
    #expect(stripped.agentIsOverlaid == snap.agentIsOverlaid)
}

// MARK: - SnapshotReader

@Test
func snapshotReader_missingDirReturnsEmpty() async throws {
    let bogusBase = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("definitely-does-not-exist-\(UUID().uuidString)", isDirectory: true)
    let matches = try SnapshotReader.resolveHashPrefix("anything", baseURL: bogusBase)
    #expect(matches.isEmpty,
            "Missing directory must return empty (feature-off / first-launch path is normal)")
    let snap = try SnapshotReader.load(hash: "anything", baseURL: bogusBase)
    #expect(snap == nil)
}

@Test
func snapshotReader_resolveHashPrefix_uniqueMatch() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)
    await writer.persist(makeSnapshot(hash: "abcdef123"))
    await writer.persist(makeSnapshot(hash: "fedcba987"))
    let matches = try SnapshotReader.resolveHashPrefix("abcd", baseURL: baseURL)
    #expect(matches.count == 1)
    #expect(matches.first == "abcdef123")
}

@Test
func snapshotReader_resolveHashPrefix_ambiguousMatch() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)
    await writer.persist(makeSnapshot(hash: "abc-shared-prefix-1"))
    await writer.persist(makeSnapshot(hash: "abc-shared-prefix-2"))
    let matches = try SnapshotReader.resolveHashPrefix("abc", baseURL: baseURL)
    #expect(matches.count == 2,
            "Ambiguous prefix returns all matches so CLI can disambiguate")
}

@Test
func snapshotReader_pruneOldDayFolders() async throws {
    let baseURL = try makeTmpBaseURL()
    let writer = SnapshotWriter(baseURL: baseURL)

    let cal = Calendar(identifier: .iso8601)
    let now = Date()
    let veryOld = cal.date(byAdding: .day, value: -100, to: now)!
    let recent = cal.date(byAdding: .day, value: -5, to: now)!

    await writer.persist(makeSnapshot(timestamp: veryOld, hash: "old-hash"))
    await writer.persist(makeSnapshot(timestamp: recent, hash: "recent-hash"))

    // Prune anything older than 30 days. Only the 100-day-old folder
    // should disappear.
    let deleted = try SnapshotReader.prune(olderThanDays: 30, baseURL: baseURL, now: now)
    #expect(deleted == 1,
            "Prune at threshold 30 must delete exactly the 100-day-old folder, keep the 5-day-old")
    let oldStillThere = try SnapshotReader.load(hash: "old-hash", baseURL: baseURL)
    let recentStillThere = try SnapshotReader.load(hash: "recent-hash", baseURL: baseURL)
    #expect(oldStillThere == nil, "Old snapshot must be gone post-prune")
    #expect(recentStillThere != nil, "Recent snapshot must survive prune")
}

@Test
func snapshotReader_pruneDoesNotTouchNonDayFolders() async throws {
    let baseURL = try makeTmpBaseURL()
    // Drop a non-day-shaped folder name; prune must not touch it.
    let strangeFolder = baseURL.appendingPathComponent("not-a-date", isDirectory: true)
    try FileManager.default.createDirectory(at: strangeFolder, withIntermediateDirectories: true)

    let deleted = try SnapshotReader.prune(olderThanDays: 0, baseURL: baseURL, now: Date())
    #expect(deleted == 0,
            "Folders whose names don't parse as YYYY-MM-DD must NOT be deleted by prune")
    #expect(FileManager.default.fileExists(atPath: strangeFolder.path),
            "non-day-shaped folder must survive prune")
}

// MARK: - ReceiptReplayFormatter.formatSnapshot

@Test
func formatSnapshot_includesBundleIDAndElementCount() {
    let snap = makeSnapshot(
        bundleID: "com.apple.Notes",
        hash: "fmt-test",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "New Note", value: nil,
                      frame: CodableRect(.init(x: 10, y: 10, width: 100, height: 30)),
                      isEnabled: true, isVisible: true),
            UIElement(index: 1, role: "AXTextField", label: "Title", value: "",
                      frame: CodableRect(.init(x: 10, y: 60, width: 200, height: 28)),
                      isEnabled: true, isVisible: true)
        ]
    )
    let rendered = ReceiptReplayFormatter.formatSnapshot(snap)
    #expect(rendered.contains("com.apple.Notes"))
    #expect(rendered.contains("fmt-test"))
    #expect(rendered.contains("Elements (2):"))
    #expect(rendered.contains("New Note"))
    #expect(rendered.contains("AXButton"))
}

@Test
func formatSnapshot_rendersVisionObservations() {
    let snap = makeSnapshot(
        hash: "vis-test",
        elements: [],
        visionObservations: [
            VisionObservation(text: "Submit", boundingBox: CodableRect(.init(x: 10, y: 20, width: 100, height: 30)))
        ]
    )
    let rendered = ReceiptReplayFormatter.formatSnapshot(snap)
    #expect(rendered.contains("Vision observations (1"))
    #expect(rendered.contains("Submit"))
}

// MARK: - Unit 21 / formatSnapshotDiff

@Test
func formatSnapshotDiff_identicalSnapshotsReturnsNoDifferences() {
    let snap = makeSnapshot(hash: "same-hash")
    let out = ReceiptReplayFormatter.formatSnapshotDiff(snap, snap)
    #expect(out.contains("identical"),
            "Identical snapshots (same hash) must short-circuit with 'identical' message")
    #expect(!out.contains("CHANGED"),
            "Identical-hash branch must not emit any CHANGED lines")
}

@Test
func formatSnapshotDiff_bundleIDChange() {
    let a = makeSnapshot(bundleID: "com.apple.Notes", hash: "a")
    let b = makeSnapshot(bundleID: "com.apple.Safari", hash: "b")
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("com.apple.Notes → com.apple.Safari"))
    #expect(out.contains("CHANGED"))
}

@Test
func formatSnapshotDiff_elementAddition() {
    let a = makeSnapshot(hash: "a", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let b = makeSnapshot(hash: "b", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true),
        UIElement(index: 1, role: "AXButton", label: "Cancel", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("[+1] ADDED"))
    #expect(out.contains("Cancel"))
}

@Test
func formatSnapshotDiff_elementRemoval() {
    let a = makeSnapshot(hash: "a", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true),
        UIElement(index: 1, role: "AXButton", label: "Cancel", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let b = makeSnapshot(hash: "b", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("[-1] REMOVED"))
    #expect(out.contains("Cancel"))
}

@Test
func formatSnapshotDiff_sameIndexContentChange_listsAffectedFields() {
    let a = makeSnapshot(hash: "a", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let b = makeSnapshot(hash: "b", elements: [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                  frame: CodableRect(.zero), isEnabled: false, isVisible: true)
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("[0] CHANGED:isEnabled"),
            "Diff must name exactly which field(s) differ — operator triages from this signal")
}

// Unit 25 — focus transitions are a primary failure-mode signal for the
// "did the click move focus?" question. The diff formatter must surface
// isFocused changes the same way it surfaces other field changes.
@Test
func formatSnapshotDiff_isFocusedChange_listed() {
    let a = makeSnapshot(hash: "a", elements: [
        UIElement(index: 0, role: "AXTextField", label: "Search", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true,
                  isFocused: false)
    ])
    let b = makeSnapshot(hash: "b", elements: [
        UIElement(index: 0, role: "AXTextField", label: "Search", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true,
                  isFocused: true)
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("[0] CHANGED:isFocused"),
            "Diff must list isFocused when it changes — focus transitions are first-class evidence")
}

@Test
func formatSnapshotDiff_visionObservationAddition() {
    let a = makeSnapshot(hash: "a", visionObservations: [])
    let b = makeSnapshot(hash: "b", visionObservations: [
        VisionObservation(text: "Submit",
                          boundingBox: CodableRect(.init(x: 10, y: 20, width: 100, height: 30)))
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("Vision changes"))
    #expect(out.contains("ADDED"))
    #expect(out.contains("Submit"))
}

@Test
func formatSnapshotDiff_headerCarriesCounts() {
    let a = makeSnapshot(hash: "a", elements: [
        UIElement(index: 0, role: "X", label: "X", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let b = makeSnapshot(hash: "b", elements: [
        UIElement(index: 0, role: "X", label: "X", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true),
        UIElement(index: 1, role: "Y", label: "Y", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true),
        UIElement(index: 2, role: "Z", label: "Z", value: nil,
                  frame: CodableRect(.zero), isEnabled: true, isVisible: true)
    ])
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("elements: 1 → 3"),
            "Header must show element-count delta as 'A → B'")
    #expect(out.contains("(+2)"),
            "Header must show signed delta")
}

@Test
func formatSnapshotDiff_metadataOnlyDifferenceIsExplicit() {
    // Same elements + same vision + same bundleID but different hash —
    // means timestamp / captureOrigin / flags differ. The output must
    // explicitly surface this, not silently print an empty diff.
    let a = makeSnapshot(hash: "metadata-only-a")
    let b = makeSnapshot(hash: "metadata-only-b")
    // Both have empty elements + empty vision + same bundleID
    let out = ReceiptReplayFormatter.formatSnapshotDiff(a, b)
    #expect(out.contains("metadata field differs"),
            "Diff must explicitly surface metadata-only differences — otherwise operator sees an empty diff and is confused")
}

// MARK: - Helpers

private func yyyyMMdd(_ date: Date) -> String {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .iso8601)
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)
    df.dateFormat = "yyyy-MM-dd"
    return df.string(from: date)
}
