import Foundation
import Testing
@testable import MacOSAgentV0

// MARK: - Action-model self-heal migration
//
// `UserDefaults.selectedModel` (extension getter in SettingsView.swift) is the
// single source of truth for the persisted action-LLM ID. It self-heals: if the
// stored ID is not in `AgentModel.all`, it overwrites with the default and
// returns that. 2026-05-23 removed `claude-haiku-4-5-20251001` from the
// whitelist; operators with that ID persisted must migrate to Sonnet 4.6 on
// next launch. These tests pin the migration contract.

@MainActor
private func makeIsolatedSuite() -> UserDefaults {
    // Each test gets a UUID-suffixed suite so concurrent tests don't collide
    // and prior runs don't leak state into this one.
    let name = "com.southernreach.test.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    return suite
}

@Test
@MainActor
func selectedModel_returnsStoredID_whenStillInWhitelist() {
    let suite = makeIsolatedSuite()
    suite.set("claude-sonnet-4-6", forKey: "selectedModel")
    #expect(suite.selectedModel == "claude-sonnet-4-6")
}

@Test
@MainActor
func selectedModel_returnsDefault_whenUserDefaultsEmpty() {
    // First-launch case: no stored value. Returns Sonnet 4.6 default and
    // persists it. Does NOT log a migration line because there was no
    // prior valid ID to migrate from.
    let suite = makeIsolatedSuite()
    #expect(suite.selectedModel == AgentModel.defaultModel.id)
    #expect(suite.selectedModel == "claude-sonnet-4-6")
    #expect(suite.string(forKey: "selectedModel") == "claude-sonnet-4-6")
}

@Test
@MainActor
func selectedModel_migratesStaleHaikuToSonnet() {
    // 2026-05-23 audit: operators with Haiku 4.5 persisted as action model
    // must migrate to Sonnet 4.6 on next launch. The getter self-heals.
    let suite = makeIsolatedSuite()
    suite.set("claude-haiku-4-5-20251001", forKey: "selectedModel")
    let resolved = suite.selectedModel
    #expect(resolved == "claude-sonnet-4-6",
            "Stale Haiku 4.5 must self-heal to Sonnet 4.6 (the default).")
    // Migration persisted, not just returned.
    #expect(suite.string(forKey: "selectedModel") == "claude-sonnet-4-6")
}

@Test
@MainActor
func selectedModel_migratesUnknownGarbageToDefault() {
    // Defense-in-depth: any value not in AgentModel.all migrates to default.
    // Catches typos, copy-paste errors, future retirements.
    let suite = makeIsolatedSuite()
    suite.set("not-a-real-model-id", forKey: "selectedModel")
    #expect(suite.selectedModel == "claude-sonnet-4-6")
    #expect(suite.string(forKey: "selectedModel") == "claude-sonnet-4-6")
}

@Test
@MainActor
func selectedModel_setterPersistsAnyValue() {
    // The setter does NOT validate — only the getter does. This is the
    // existing contract (the picker calls the setter; the getter is the
    // gate). If the setter validated, it would silently drop the picker's
    // selection on, e.g., an in-flight whitelist contraction. The getter's
    // self-heal handles that path.
    let suite = makeIsolatedSuite()
    suite.selectedModel = "any-string"
    #expect(suite.string(forKey: "selectedModel") == "any-string")
    // Read it back through the getter → migration to default.
    #expect(suite.selectedModel == "claude-sonnet-4-6")
}

// MARK: - D7 — Launcher window size persistence

@Test
@MainActor
func launcherWidth_defaultsTo480_whenUnset() {
    // First-launch: no stored value. Getter returns the original hub width
    // (480) so the operator's first-ever window matches pre-D7 behavior.
    let suite = makeIsolatedSuite()
    #expect(suite.launcherWidth == 480)
}

@Test
@MainActor
func launcherHeight_defaultsTo640_whenUnset() {
    let suite = makeIsolatedSuite()
    #expect(suite.launcherHeight == 640)
}

@Test
@MainActor
func launcherWidth_roundTripsPersistedValue() {
    let suite = makeIsolatedSuite()
    suite.launcherWidth = 900
    #expect(suite.launcherWidth == 900)
    // Confirm the underlying key is what the SwiftUI observer reads.
    #expect(suite.double(forKey: "launcherWidth") == 900)
}

@Test
@MainActor
func launcherHeight_roundTripsPersistedValue() {
    let suite = makeIsolatedSuite()
    suite.launcherHeight = 1200
    #expect(suite.launcherHeight == 1200)
}

@Test
@MainActor
func launcherWidth_clampedToMin_whenPathologicallySmall() {
    // Defensive: a corrupted prior session can't lock the window so small
    // it's off-screen. Setter clamps to 360.
    let suite = makeIsolatedSuite()
    suite.launcherWidth = 100
    #expect(suite.launcherWidth == 360)
}

@Test
@MainActor
func launcherHeight_clampedToMin_whenPathologicallySmall() {
    let suite = makeIsolatedSuite()
    suite.launcherHeight = 50
    #expect(suite.launcherHeight == 480)
}

@Test
@MainActor
func launcherWidth_clampedToMax_whenPathologicallyLarge() {
    // Defensive: a corrupted setter call can't push the window beyond
    // any plausible display setup.
    let suite = makeIsolatedSuite()
    suite.launcherWidth = 999_999
    #expect(suite.launcherWidth == 8000)
}

@Test
@MainActor
func launcherWidth_returnsDefault_whenStoredValueIsZeroOrNegative() {
    // A pre-D7 install would have `launcherWidth` key missing (== 0 in
    // UserDefaults.double semantics). Treat as "unset" → default 480.
    let suite = makeIsolatedSuite()
    suite.set(0.0, forKey: "launcherWidth")
    #expect(suite.launcherWidth == 480)
    suite.set(-50.0, forKey: "launcherWidth")
    #expect(suite.launcherWidth == 480)
}
