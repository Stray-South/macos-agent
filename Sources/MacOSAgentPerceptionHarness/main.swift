import AppKit
import Foundation
import MacAgentCore

// MacOSAgentPerceptionHarness (H2) — real-app perception fidelity harness.
//
// The confidence audit found the perception layer has ZERO real-app test
// coverage: every test injects a synthetic AX walker. This harness closes that
// for evidence: it activates each target app, walks its LIVE Accessibility tree
// through the production AXPerception, and reports what each app class exposes
// (element count, role distribution, focus) vs. what is AX-blind and therefore
// depends on the Vision OCR fallback.
//
// **Opt-in.** Gated on MACOS_AGENT_PERCEPTION_HARNESS=1. REQUIRES Accessibility
// permission for the running binary — without it the AX tree reads empty and
// every app reports AX-blind. Run manually:
//
//   MACOS_AGENT_PERCEPTION_HARNESS=1 swift run MacOSAgentPerceptionHarness
//
// Optional: PERCEPTION_HARNESS_BUNDLES="com.apple.Notes,com.apple.Safari"
// overrides the target list (comma-separated bundle IDs).

@main
struct MacOSAgentPerceptionHarness {
    static let defaultTargets: [(label: String, bundleID: String)] = [
        ("Notes", "com.apple.Notes"),
        ("Safari", "com.apple.Safari"),
        ("Mail", "com.apple.mail"),
        ("Finder", "com.apple.finder"),
        ("System Settings", "com.apple.systempreferences"),
        ("TextEdit", "com.apple.TextEdit"),
    ]

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard env["MACOS_AGENT_PERCEPTION_HARNESS"] == "1" else {
            FileHandle.standardError.write(Data("""
                MacOSAgentPerceptionHarness is opt-in. Set MACOS_AGENT_PERCEPTION_HARNESS=1 to run.

                  MACOS_AGENT_PERCEPTION_HARNESS=1 swift run MacOSAgentPerceptionHarness

                Activates each target app and walks its live Accessibility tree, then
                reports perception fidelity per app: element count, role distribution,
                AX-rich vs AX-blind (vision-dependent), truncation, focus.

                REQUIRES Accessibility permission for the RUNNING binary
                (System Settings > Privacy & Security > Accessibility). Without it the
                AX tree reads empty and every app reports AX-blind — grant it, re-run.

                Optional: PERCEPTION_HARNESS_BUNDLES="com.apple.Notes,com.apple.Safari"
                overrides the target list (comma-separated bundle IDs).
                """.utf8))
            // Exit 2 (not 0) so a CI invocation without the gate fails loudly
            // rather than silently passing — mirrors MacOSAgentSmokeAction.
            exit(2)
        }

        let targets: [(label: String, bundleID: String)]
        if let override = env["PERCEPTION_HARNESS_BUNDLES"], !override.isEmpty {
            targets = override.split(separator: ",").map {
                let id = $0.trimmingCharacters(in: .whitespaces)
                return (label: id, bundleID: id)
            }
        } else {
            targets = defaultTargets
        }

        let perception = AXPerception()
        var results: [AppFidelity] = []
        for t in targets {
            results.append(await probe(label: t.label, bundleID: t.bundleID, perception: perception))
        }
        print(PerceptionFidelity.render(results))
    }

    static func probe(label: String, bundleID: String, perception: AXPerception) async -> AppFidelity {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return PerceptionFidelity.failure(label: label, requestedBundleID: bundleID,
                                              error: "not installed / no app for bundle id")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } catch {
            return PerceptionFidelity.failure(label: label, requestedBundleID: bundleID,
                                              error: "could not activate: \(error.localizedDescription)")
        }
        // Let the app come frontmost and render before walking its tree.
        try? await Task.sleep(for: .milliseconds(1500))
        do {
            let observed = try await perception.capture(forceRefresh: true)
            return PerceptionFidelity.analyze(label: label, requestedBundleID: bundleID,
                                              snapshot: observed.snapshot)
        } catch {
            return PerceptionFidelity.failure(label: label, requestedBundleID: bundleID,
                                              error: error.localizedDescription)
        }
    }
}
