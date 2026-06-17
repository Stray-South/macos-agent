import Foundation
import MacAgentCore

// MacOSAgentSmokeAction — live-LLM regression harness for the action model.
//
// Crafted to catch the failure class the 2026-05-23 audit found: a model
// whose default ID is whitelisted but which regresses to click-only under
// the custom multi-tool schema. Sends ~5 scenarios to the LIVE Anthropic
// API and asserts each emits the expected action type.
//
// **Opt-in.** Gated on env var MACOS_AGENT_SMOKE_ACTION=1 to keep this
// out of routine CI (live API cost + Anthropic rate limits). Run manually:
//
//   ANTHROPIC_API_KEY=... \
//   MACOS_AGENT_SMOKE_ACTION=1 \
//   swift run MacOSAgentSmokeAction
//
// Optional env:
//   ACTION_MODEL=<model-id> — override the default action model.
//   MACOS_AGENT_SMOKE_INCLUDE_AUDIT=1 — run the audit set
//     (defaults + currently-known-failing scenarios). As of Unit 25h
//     this is just defaults + openAppViaVerbScenario (the "Open" verb
//     Spotlight-bias scenario). The multi-step scenarios verified at
//     10/10 in the Unit 25g live run and now ship in defaults.
//     Audit-mode exit code still follows the same "fail-on-any-failure"
//     contract; operator reads the per-step output to triage what's new
//     vs. expected when adding future known-failing scenarios.

@main
struct MacOSAgentSmokeAction {
    static func main() async {
        guard ProcessInfo.processInfo.environment["MACOS_AGENT_SMOKE_ACTION"] == "1" else {
            FileHandle.standardError.write(Data("""
                MacOSAgentSmokeAction is opt-in. Set MACOS_AGENT_SMOKE_ACTION=1 to run.

                  ANTHROPIC_API_KEY=... MACOS_AGENT_SMOKE_ACTION=1 swift run MacOSAgentSmokeAction

                This harness makes ~5 live Anthropic API calls per run. Exit non-zero on
                any regression in action-type emission.
                """.utf8))
            // Exit 2 (NOT 0) so a CI pipeline that invokes this binary without
            // the env gate set fails loudly rather than silently passing —
            // sev-1 adversarial-review finding.
            exit(2)
        }

        do {
            let modelOverride = ProcessInfo.processInfo.environment["ACTION_MODEL"]
            let llm = try modelOverride.map { try ClaudeLLMClient(model: $0) } ?? ClaudeLLMClient()

            // Hoist scenario construction so the count print and runAll see
            // the same Scenario instances (otherwise two separate
            // `defaultScenarios()` calls stamp different timestamps into the
            // snapshot hashes — harmless today, but sev-2 review flagged the
            // latent inconsistency).
            //
            // Unit 25c — MACOS_AGENT_SMOKE_INCLUDE_AUDIT=1 switches to the
            // audit set (defaults + currently-known-failing scenarios).
            // Used for verifying whether quarantined scenarios unblock after
            // a schema or prompt change. Default (env var unset) preserves
            // the harness contract: only defaults run, all-must-pass.
            let auditMode = ProcessInfo.processInfo.environment["MACOS_AGENT_SMOKE_INCLUDE_AUDIT"] == "1"
            let scenarios = auditMode
                ? try ActionRegressionScenarios.auditScenariosIncludingKnownFailing()
                : try ActionRegressionScenarios.defaultScenarios()
            let modeTag = auditMode ? " [audit mode — includes known-failing]" : ""
            print("MacOSAgentSmokeAction — \(scenarios.count) scenarios against live Anthropic API.\(modeTag)")

            let outcomes = try await ActionRegressionScenarios.runAll(llm: llm, scenarios: scenarios)

            var passed = 0
            var failed = 0
            for outcome in outcomes {
                let mark = outcome.passed ? "✓ PASS" : "✗ FAIL"
                if outcome.passed { passed += 1 } else { failed += 1 }
                print("  \(mark) [\(outcome.scenario.id)]")
                print("        task:     \(outcome.scenario.task)")
                if outcome.stepOutcomes.isEmpty {
                    // Single-action scenario — existing format.
                    print("        expected: \(outcome.scenario.expectedActionType)\(outcome.scenario.expectedTextSubstring.map { " (text contains \"\($0)\")" } ?? "")")
                    print("        observed: \(outcome.observedActionType) text=\(formatObservedText(outcome.observedText))")
                    if !outcome.passed {
                        print("        rationale: \(outcome.rationale)")
                    }
                } else {
                    // Unit 24a — multi-step scenario. Print each step's
                    // pass/fail so a failure surfaces WHICH step diverged
                    // and WHY, not just the LAST step's data mirrored
                    // onto the parent Outcome.
                    for step in outcome.stepOutcomes {
                        let stepMark = step.passed ? "✓" : "✗"
                        let expectedText = step.expected.expectedTextSubstring.map { " (text contains \"\($0)\")" } ?? ""
                        let forbidden = step.expected.forbiddenTargetIndex.map { " (NOT index \($0))" } ?? ""
                        print("        \(stepMark) step \(step.step): expected=\(step.expected.expectedActionType)\(expectedText)\(forbidden)")
                        print("                  observed=\(step.observedActionType) text=\(formatObservedText(step.observedText))")
                        if !step.passed {
                            print("                  rationale: \(step.rationale)")
                        }
                    }
                    // If the harness fail-fasted, remaining steps never ran.
                    let ran = outcome.stepOutcomes.count
                    let planned = outcome.scenario.expectedSteps?.count ?? ran
                    if ran < planned {
                        print("        ⊘ steps \(ran)-\(planned - 1) skipped (fail-fast after step \(ran - 1))")
                    }
                }
            }

            print("")
            print("Result: \(passed)/\(outcomes.count) passed.")
            if failed > 0 {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("MacOSAgentSmokeAction failed: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    /// Pretty-print an `observedText` field (nil → "<nil>", over-40 chars → truncated).
    /// Hoisted out of the loop for reuse between single-action and per-step paths.
    private static func formatObservedText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "<nil>" }
        return "\"\(text.count > 40 ? String(text.prefix(37)) + "..." : text)\""
    }
}
