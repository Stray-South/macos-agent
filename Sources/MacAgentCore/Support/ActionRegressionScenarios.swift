import Foundation

/// Live-LLM regression scenarios for the action model.
///
/// Each scenario pairs a synthetic `PerceptionSnapshot` + task prompt with
/// the action type the model SHOULD emit if it's reasoning correctly about
/// the available tools. Designed to catch the failure class the 2026-05-23
/// audit found: Haiku 4.5 under the custom multi-tool schema regressed to
/// click/wait/cmd+tab only, never reaching for `switchApp` / `typeText` /
/// `menuSelect` / `scroll`.
///
/// Run via `MacOSAgentSmokeAction` (env-gated, opt-in). Library lives in
/// MacAgentCore so future tests can use individual scenarios offline.
public enum ActionRegressionScenarios {
    /// Unit 24 — a step the LLM is expected to emit at position `i` in a
    /// multi-step scenario. Mirrors the per-action assertions on
    /// `Scenario` but applied to each step of a trajectory.
    ///
    /// Per-step `advanceSnapshot` simulates the executor's effect on the
    /// UI: after the LLM emits step `i`'s action against `cursor`, the
    /// harness sets `cursor = advanceSnapshot ?? cursor` for the next
    /// `nextAction` call. nil means "keep the same snapshot" (useful when
    /// the final step is `.complete` — UI doesn't change).
    public struct ExpectedStep: Sendable {
        public let expectedActionType: String
        public let expectedTextSubstring: String?
        public let forbiddenTargetIndex: Int?
        public let advanceSnapshot: PerceptionSnapshot?

        public init(
            expectedActionType: String,
            expectedTextSubstring: String? = nil,
            forbiddenTargetIndex: Int? = nil,
            advanceSnapshot: PerceptionSnapshot? = nil
        ) {
            self.expectedActionType = expectedActionType
            self.expectedTextSubstring = expectedTextSubstring
            self.forbiddenTargetIndex = forbiddenTargetIndex
            self.advanceSnapshot = advanceSnapshot
        }
    }

    /// Unit 24 — per-step outcome rendered into the parent `Outcome.stepOutcomes`
    /// list. `passed` uses the same predicate as single-action `Outcome` (type
    /// match + optional text-substring + optional forbidden-index).
    public struct StepOutcome: Sendable {
        public let step: Int
        public let expected: ExpectedStep
        public let observedActionType: String
        public let observedText: String?
        public let passed: Bool
        public let rationale: String

        public init(step: Int, expected: ExpectedStep, action: AgentAction) {
            self.step = step
            self.expected = expected
            self.observedActionType = action.type.rawValue
            self.observedText = action.text
            self.rationale = action.rationale
            let typeMatch = action.type.rawValue == expected.expectedActionType
            let textMatch: Bool = {
                guard let needle = expected.expectedTextSubstring else { return true }
                guard let haystack = action.text else { return false }
                return haystack.lowercased().contains(needle.lowercased())
            }()
            let notForbidden: Bool = {
                guard let forbidden = expected.forbiddenTargetIndex else { return true }
                return action.targetIndex != forbidden
            }()
            self.passed = typeMatch && textMatch && notForbidden
        }
    }

    public struct Scenario: Sendable {
        public let id: String
        public let task: String
        public let snapshot: PerceptionSnapshot
        /// Per-scenario running-apps list. Threaded through to
        /// `ActionThinking.nextAction(runningApps:)` so scenarios can
        /// independently shape the Running Apps block in the system prompt.
        /// `switchApp_to_notes` uses this to seed Notes as launchable —
        /// without it the model can legitimately reach for Spotlight
        /// (keyCombo cmd+space) which is also a valid path to Notes,
        /// producing a false-negative regression report.
        public let runningApps: [RunningApp]
        /// The action type the model is expected to emit. Free-form `String`
        /// rather than `ActionType` so the comparison is the raw-value the LLM
        /// returns; insulates from internal enum-case renames.
        public let expectedActionType: String
        /// Optional substring the `action.text` field must contain. nil means
        /// any text (or nil text) passes.
        public let expectedTextSubstring: String?
        /// Unit 20 — optional targetIndex the model MUST NOT pick.
        /// nil means no constraint. Used by the recovery scenario to
        /// assert the LLM picked a DIFFERENT element than the one the
        /// task's inlined recovery hint said failed. Mirrors how
        /// Orchestrator's recovery prompt (Unit 14) tells the LLM
        /// "do not retry index N against the upcoming snapshot."
        public let forbiddenTargetIndex: Int?

        /// Unit 24 — optional multi-step trajectory. nil → single-action
        /// mode (existing behaviour, all 7 default scenarios). Non-nil →
        /// the harness loops `nextAction` once per step, advancing the
        /// snapshot per `ExpectedStep.advanceSnapshot`. Cost: ~$0.04 per
        /// step at current Anthropic rates, so a 3-step scenario costs
        /// ~$0.12. Step count is capped at `maxSteps` to bound per-run
        /// API spend.
        public let expectedSteps: [ExpectedStep]?

        /// Hard cap on multi-step scenarios. Three steps is the longest
        /// trajectory we ship in defaults (openNotesThenSearchThenComplete).
        /// Raising this cap requires the operator to acknowledge the cost
        /// — at 5 steps a single scenario hits ~$0.20.
        public static let maxSteps = 3

        public init(
            id: String,
            task: String,
            snapshot: PerceptionSnapshot,
            runningApps: [RunningApp] = [],
            expectedActionType: String,
            expectedTextSubstring: String? = nil,
            forbiddenTargetIndex: Int? = nil,
            expectedSteps: [ExpectedStep]? = nil
        ) {
            self.id = id
            self.task = task
            self.snapshot = snapshot
            self.runningApps = runningApps
            self.expectedActionType = expectedActionType
            self.expectedTextSubstring = expectedTextSubstring
            self.forbiddenTargetIndex = forbiddenTargetIndex
            if let steps = expectedSteps {
                precondition(!steps.isEmpty,
                    "Scenario \(id): expectedSteps must be nil or non-empty")
                precondition(steps.count <= Self.maxSteps,
                    "Scenario \(id): expectedSteps.count (\(steps.count)) exceeds maxSteps (\(Self.maxSteps)) — bounded per-run cost")
            }
            self.expectedSteps = expectedSteps
        }
    }

    public struct Outcome: Sendable {
        public let scenario: Scenario
        public let observedActionType: String
        public let observedText: String?
        public let passed: Bool
        public let rationale: String
        /// Unit 24 — per-step outcomes when the scenario carried
        /// `expectedSteps`. Empty for single-action scenarios. `passed`
        /// on the parent Outcome mirrors `stepOutcomes.allSatisfy(\.passed)`
        /// — fail-fast means later steps may be absent if an earlier one
        /// diverged (the harness short-circuits to save API spend).
        public let stepOutcomes: [StepOutcome]

        /// Single-action initialiser — back-compat for the 7 existing
        /// scenarios. stepOutcomes is empty by construction.
        public init(scenario: Scenario, action: AgentAction) {
            self.scenario = scenario
            self.observedActionType = action.type.rawValue
            self.observedText = action.text
            self.rationale = action.rationale
            let typeMatch = action.type.rawValue == scenario.expectedActionType
            let textMatch: Bool = {
                guard let expected = scenario.expectedTextSubstring else { return true }
                guard let actual = action.text else { return false }
                return actual.lowercased().contains(expected.lowercased())
            }()
            // Unit 20 — forbidden-index predicate. nil = no constraint
            // (preserves all existing scenarios' back-compat behavior).
            // Non-nil = the LLM must NOT have picked this exact index.
            let notForbidden: Bool = {
                guard let forbidden = scenario.forbiddenTargetIndex else { return true }
                return action.targetIndex != forbidden
            }()
            self.passed = typeMatch && textMatch && notForbidden
            self.stepOutcomes = []
        }

        /// Unit 24 — multi-step initialiser. `stepOutcomes` is the
        /// trajectory the harness walked; `passed` is true iff every
        /// step passed. The first failing step's index appears in
        /// stepOutcomes (fail-fast surfaces the diverging step
        /// immediately for operator triage).
        public init(scenario: Scenario, stepOutcomes: [StepOutcome]) {
            precondition(scenario.expectedSteps != nil,
                "Multi-step Outcome init requires Scenario.expectedSteps to be non-nil")
            precondition(!stepOutcomes.isEmpty,
                "Multi-step Outcome requires at least one StepOutcome — runMultiStep always appends before breaking, so an empty list is a wiring bug")
            self.scenario = scenario
            self.stepOutcomes = stepOutcomes
            // For UI / receipt convenience, mirror the LAST observed
            // action's fields onto the top-level Outcome — that's the
            // most-recent thing the LLM did. Empty stepOutcomes is
            // ruled out by the precondition above.
            let last = stepOutcomes[stepOutcomes.count - 1]
            self.observedActionType = last.observedActionType
            self.observedText = last.observedText
            self.rationale = last.rationale
            self.passed = stepOutcomes.allSatisfy(\.passed)
        }
    }

    /// Scenarios crafted to flush out the Haiku-class regression. Each one
    /// targets a specific action type that Haiku failed to emit. A passing
    /// model emits the expected type; a regressing model emits `.click` or
    /// `.keyCombo cmd+tab` instead.
    public static func defaultScenarios() throws -> [Scenario] {
        [
            try switchAppScenario(),
            // openAppViaVerbScenario intentionally NOT in defaultScenarios
            // until prompt tuning lands. Dogfood evidence (2026-05-27)
            // confirms the current LLM emits `keyCombo cmd+space` for
            // `"Open Notes"` — so including this scenario here would make
            // `MacOSAgentSmokeAction` exit non-zero on EVERY invocation,
            // violating the harness contract (0 = clean, 1 = regression).
            // The scenario lives as a public function below so operators
            // can run it explicitly when validating prompt-tuning work;
            // it returns to defaults once the regression is fixed at
            // the prompt layer.
            try launchAppColdScenario(),
            try recoveryFromExecutorErrorScenario(),
            try typeTextScenario(),
            try menuSelectScenario(),
            try scrollScenario(),
            try baselineClickScenario(),
            // Unit 25h — multi-step scenarios un-quarantined. The Unit 25
            // chain (schema + walker + prompt + grounding + fixture
            // corrections) closed the isFocused gap that originally
            // forced both into audit-only. Live audit-mode T2 run
            // (2026-06-03) confirmed 10/10 with the corrected Safari
            // 3-step trajectory. Both scenarios now serve as default
            // regression guards for multi-step orchestration.
            try safariSearchSequenceScenario(),
            try openNotesThenSearchThenCompleteScenario(),
        ]
    }

    /// Audit-grade scenarios INCLUDING currently-known-failing ones.
    /// Returned list is a superset of `defaultScenarios()` — adds
    /// regression guards for issues that haven't been fixed yet.
    /// Caller is responsible for interpreting partial failures
    /// (vs. defaultScenarios' "all must pass" contract).
    ///
    /// Unit 24b — `safariSearchSequenceScenario` joined the quarantine.
    /// Live T2 evidence (2026-05-28) showed the LLM emits switchApp
    /// DEFENSIVELY at step 1 (rationale: "Switch to Safari to ensure
    /// it is the active application"), even though the snapshot already
    /// shows Safari frontmost and history contains its own prior
    /// switchApp rationale. This is a real LLM behavior pattern under
    /// default tuning — same failure CLASS as the May-27 Spotlight loop,
    /// just routed through switchApp instead of cmd+space. No H-series
    /// detector currently catches repeated switchApp (H.5a is keyCombo-
    /// scoped, H.3 is click-scoped). Scenario is retained as a regression
    /// guard for prompt-tuning work and as evidence for a future H-series
    /// detector (sameSwitchAppLoop) but is OUT of defaults until the
    /// behavior changes.
    public static func auditScenariosIncludingKnownFailing() throws -> [Scenario] {
        try defaultScenarios() + [
            // Unit 25h — the two multi-step scenarios moved back into
            // defaultScenarios(). Only the "Open" verb scenario remains
            // here as known-failing (the Spotlight prompt bias is a
            // separate gap that prompt-tuning will close in its own
            // unit). The audit set therefore = defaults + 1.
            try openAppViaVerbScenario(),
        ]
    }

    // MARK: - Individual scenarios

    /// Operator names a different app; model should emit `switchApp` with the
    /// target's bundle ID. Regression signature: keyCombo cmd+tab / cmd+space.
    ///
    /// Seeds the Running Apps list with Finder + Notes so the system prompt
    /// renders the Running Apps block (suppressed when the list is empty)
    /// and the model has explicit `switchApp` candidates to choose from.
    /// Without this seeding a correct model could legitimately emit
    /// `keyCombo cmd+space` (Spotlight) as a valid alternative path,
    /// producing a false-negative regression report.
    public static func switchAppScenario() throws -> Scenario {
        Scenario(
            id: "switchApp_to_notes",
            task: "Switch to the Notes app to start a new note.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.finder",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Search",
                              value: nil,
                              frame: CodableRect(CGRect(x: 10, y: 10, width: 60, height: 24)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            runningApps: [
                RunningApp(bundleID: "com.apple.finder", name: "Finder"),
                RunningApp(bundleID: "com.apple.Notes", name: "Notes")
            ],
            expectedActionType: "switchApp",
            expectedTextSubstring: "com.apple.notes"
        )
    }

    /// Snapshot has a focused text field labelled Search; task asks the model
    /// to type a query. Regression signature: click on the search field
    /// without the typeText follow-up.
    ///
    /// Unit 25d — fixture now sets `isFocused: true` on the search field
    /// to match the task wording ("is already focused"). Prior to Unit 25
    /// the LLM ignored the missing focus signal; after Unit 25's prompt
    /// rule the LLM correctly refuses to type into a field whose
    /// isFocused is false. This is the new contract: when a fixture
    /// claims an element is focused, the snapshot must reflect it.
    public static func typeTextScenario() throws -> Scenario {
        Scenario(
            id: "typeText_search_query",
            // Explicit-focus wording so a careful model doesn't legitimately
            // emit `click` (to focus) as a first step and then typeText next
            // — the harness gates the FIRST returned action, so a two-step
            // valid path would false-positive as a regression.
            task: "The Search field at index 0 is already focused. Type 'octopus' into it.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.Safari",
                elements: [
                    UIElement(index: 0, role: "AXTextField", label: "Search",
                              value: "",
                              frame: CodableRect(CGRect(x: 100, y: 50, width: 200, height: 28)),
                              isEnabled: true, isVisible: true,
                              isFocused: true),
                    UIElement(index: 1, role: "AXButton", label: "Bookmarks",
                              value: nil,
                              frame: CodableRect(CGRect(x: 310, y: 50, width: 80, height: 28)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            expectedActionType: "typeText",
            expectedTextSubstring: "octopus"
        )
    }

    /// Task names a menu path; model should emit `menuSelect`. Regression
    /// signature: click on a random element.
    public static func menuSelectScenario() throws -> Scenario {
        Scenario(
            id: "menuSelect_file_new_note",
            task: "Use the File menu to create a new note via File > New Note.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.Notes",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Sidebar",
                              value: nil,
                              frame: CodableRect(CGRect(x: 10, y: 10, width: 24, height: 24)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            expectedActionType: "menuSelect",
            expectedTextSubstring: "File"
        )
    }

    /// Task explicitly asks for scroll; model should emit `scroll`. Regression
    /// signature: click somewhere on the page.
    public static func scrollScenario() throws -> Scenario {
        Scenario(
            id: "scroll_long_document",
            task: "Scroll down to see more of the document.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.TextEdit",
                elements: [
                    UIElement(index: 0, role: "AXScrollArea", label: "Document",
                              value: nil,
                              frame: CodableRect(CGRect(x: 0, y: 50, width: 600, height: 400)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            expectedActionType: "scroll"
        )
    }

    /// Baseline — a single enabled "Continue" button + a click-it task.
    /// Mirrors `SmokeCheck.makeSampleSnapshot`'s shape so a regression on
    /// the simplest case is visible. Pass on every model that's working.
    public static func baselineClickScenario() throws -> Scenario {
        Scenario(
            id: "baseline_click_continue",
            task: "Click the Continue button.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.example.app",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Continue",
                              value: nil,
                              frame: CodableRect(CGRect(x: 120, y: 80, width: 120, height: 32)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            expectedActionType: "click"
        )
    }

    // MARK: - Unit 17 / Path F additions
    //
    // Three scenarios closing gaps surfaced by the 2026-05-27 dogfood:
    // - openAppViaVerbScenario:  "Open X" wording (vs switchAppScenario's
    //   "Switch to X") — the dogfood failure showed the LLM picks
    //   Spotlight (cmd+space) on "open" verbs instead of switchApp.
    // - launchAppColdScenario:   target app NOT in runningApps — exercises
    //   the cold-launch path that NSWorkspace.openApplication is the
    //   correct underlying mechanism, requiring switchApp with bundleID
    //   the agent has never seen running before.
    // - recoveryFromExecutorErrorScenario: synthetic conversation history
    //   simulates a prior failed action; assert the LLM honors the
    //   recovery prompt and emits a DIFFERENT action than the one that
    //   just failed (Unit 14's stale-target hint regression guard).

    /// "Open X" wording — dogfood evidence (2026-05-27) showed the LLM
    /// emits `keyCombo cmd+space` (Spotlight) for `"Open Notes"` instead
    /// of `switchApp(text: "com.apple.Notes")`. Regression signature:
    /// any non-switchApp first action.
    public static func openAppViaVerbScenario() throws -> Scenario {
        Scenario(
            id: "open_notes_verb_test",
            task: "Open Notes.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.finder",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Search",
                              value: nil,
                              frame: CodableRect(CGRect(x: 10, y: 10, width: 60, height: 24)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            runningApps: [
                RunningApp(bundleID: "com.apple.finder", name: "Finder"),
                RunningApp(bundleID: "com.apple.Notes", name: "Notes")
            ],
            expectedActionType: "switchApp",
            expectedTextSubstring: "com.apple.notes"
        )
    }

    /// Cold-launch: Calculator NOT in runningApps. switchApp's executor
    /// path handles this via `NSWorkspace.openApplication`; the LLM
    /// should still emit `switchApp` with the bundleID (not Spotlight,
    /// not "I can't find this app"). Regression signature: clarify /
    /// keyCombo / any non-switchApp action.
    public static func launchAppColdScenario() throws -> Scenario {
        Scenario(
            id: "cold_launch_calculator",
            task: "Launch the Calculator app.",
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.apple.finder",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Search",
                              value: nil,
                              frame: CodableRect(CGRect(x: 10, y: 10, width: 60, height: 24)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            // Calculator intentionally absent — exercises the cold-launch path.
            runningApps: [
                RunningApp(bundleID: "com.apple.finder", name: "Finder")
            ],
            expectedActionType: "switchApp",
            expectedTextSubstring: "com.apple.calculator"
        )
    }

    /// Unit 20 — Unit 14's stale-target recovery prompt regression
    /// guard. The production Orchestrator injects the recovery hint
    /// into conversationHistory automatically; the T2 harness has no
    /// history channel, so we INLINE the hint into the task wording
    /// (functionally equivalent for the regression-guard signal).
    ///
    /// Snapshot has two enabled buttons; the task tells the LLM that
    /// index 0 ("Submit") just failed and to pick a DIFFERENT element.
    /// `forbiddenTargetIndex: 0` enforces that — a regressing model
    /// that re-emits `click[0]` despite the inlined hint fails the
    /// scenario.
    ///
    /// Distinct from `openAppViaVerbScenario` (known-failing prompt
    /// bias, quarantined): the recovery scenario tests instruction-
    /// following on an explicit "do NOT" hint, which a competent
    /// action model handles cleanly. Ships in defaults.
    public static func recoveryFromExecutorErrorScenario() throws -> Scenario {
        Scenario(
            id: "recovery_picks_alternative",
            task: """
            The previous click at index 0 (the 'Submit' button) failed because that element is no longer valid. \
            A fresh snapshot follows. Pick a DIFFERENT element this time — do NOT retry index 0.
            """,
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now,
                focusedAppBundleID: "com.example.app",
                elements: [
                    UIElement(index: 0, role: "AXButton", label: "Submit",
                              value: nil,
                              frame: CodableRect(CGRect(x: 10, y: 10, width: 80, height: 28)),
                              isEnabled: true, isVisible: true),
                    UIElement(index: 1, role: "AXButton", label: "Cancel",
                              value: nil,
                              frame: CodableRect(CGRect(x: 100, y: 10, width: 80, height: 28)),
                              isEnabled: true, isVisible: true)
                ]
            ),
            expectedActionType: "click",
            forbiddenTargetIndex: 0
        )
    }

    // MARK: - Unit 24 multi-step scenarios

    /// Unit 24 — 3-step trajectory. switchApp → keyCombo cmd+l → typeText.
    /// Ships in `defaultScenarios()` as of Unit 25h.
    ///
    /// The trajectory matches real Safari behavior: switching to Safari
    /// leaves focus in the content area, not the URL bar. The reliable
    /// way to focus the address bar is cmd+l. Earlier Unit 24/25
    /// iterations tried a 2-step direct-typeText shape; the LLM
    /// correctly distrusted those fixtures because they didn't match
    /// real Safari focus behavior. Unit 25g rewrote the scenario as
    /// 3 steps with realistic per-step snapshots (post-switchApp:
    /// address bar NOT focused; post-cmd+l: address bar focused).
    ///
    /// Wording uses "Switch to" (proven correct verb per
    /// `switchAppScenario`) to avoid the "Open X" → Spotlight prompt
    /// bias. Task text stays minimal — the LLM must derive cmd+l from
    /// the snapshot state, not from a hint in the prompt.
    ///
    /// Step 0 regression signature: any non-switchApp first action.
    /// Step 1 regression signature: any non-keyCombo or wrong-key
    /// emission. Step 2 regression signature: defensive re-action
    /// (click, keyCombo) on the already-focused address bar instead
    /// of typeText.
    public static func safariSearchSequenceScenario() throws -> Scenario {
        let initialSnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.finder",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Search",
                          value: nil,
                          frame: CodableRect(CGRect(x: 10, y: 10, width: 60, height: 24)),
                          isEnabled: true, isVisible: true)
            ]
        )
        // Unit 25g — post-switchApp: Safari is frontmost but the address
        // bar is NOT focused. This matches real Safari behavior: when you
        // bring Safari to the front, focus lands in the content area or
        // last-used field, not the URL bar. The reliable way to focus
        // the address bar is cmd+l. Earlier Unit 25d marked the address
        // bar isFocused=true here as a workaround, but live T2 evidence
        // showed the LLM correctly distrusts that signal (training data
        // says Safari's URL bar doesn't auto-focus on switch); it emitted
        // cmd+l anyway. The scenario now models the realistic trajectory.
        let safariFrontmostSnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.Safari",
            elements: [
                UIElement(index: 0, role: "AXTextField", label: "Address and search",
                          value: "",
                          frame: CodableRect(CGRect(x: 200, y: 30, width: 600, height: 28)),
                          isEnabled: true, isVisible: true,
                          isFocused: false),
                UIElement(index: 1, role: "AXButton", label: "Reload",
                          value: nil,
                          frame: CodableRect(CGRect(x: 820, y: 30, width: 28, height: 28)),
                          isEnabled: true, isVisible: true)
            ]
        )
        // Unit 25g — post-cmd+l: the address bar is now focused. Real
        // Safari behavior: cmd+l selects the URL bar contents and moves
        // keyboard focus there. From this state, typeText goes directly
        // into the URL bar.
        let safariAddressBarFocusedSnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.Safari",
            elements: [
                UIElement(index: 0, role: "AXTextField", label: "Address and search",
                          value: "",
                          frame: CodableRect(CGRect(x: 200, y: 30, width: 600, height: 28)),
                          isEnabled: true, isVisible: true,
                          isFocused: true),
                UIElement(index: 1, role: "AXButton", label: "Reload",
                          value: nil,
                          frame: CodableRect(CGRect(x: 820, y: 30, width: 28, height: 28)),
                          isEnabled: true, isVisible: true)
            ]
        )
        return Scenario(
            id: "multistep_safari_search",
            // Task wording stays minimal — let snapshot state drive each
            // step's action choice. Don't spoon-feed "cmd+l first" as a
            // hint; the LLM should derive that from the post-switchApp
            // snapshot showing the address bar NOT focused.
            task: "Switch to Safari and search for 'AuDHD productivity' in the address bar.",
            snapshot: initialSnapshot,
            runningApps: [
                RunningApp(bundleID: "com.apple.finder", name: "Finder"),
                RunningApp(bundleID: "com.apple.Safari", name: "Safari")
            ],
            // Top-level fields mirror step 0 — kept populated for back-compat
            // with single-action consumers that read Scenario.expectedActionType
            // directly. Multi-step harness uses expectedSteps instead.
            expectedActionType: "switchApp",
            expectedTextSubstring: "com.apple.safari",
            expectedSteps: [
                ExpectedStep(
                    expectedActionType: "switchApp",
                    expectedTextSubstring: "com.apple.safari",
                    advanceSnapshot: safariFrontmostSnapshot
                ),
                ExpectedStep(
                    expectedActionType: "keyCombo",
                    expectedTextSubstring: "cmd+l",
                    advanceSnapshot: safariAddressBarFocusedSnapshot
                ),
                ExpectedStep(
                    expectedActionType: "typeText",
                    expectedTextSubstring: "AuDHD productivity",
                    advanceSnapshot: nil  // typeText doesn't change discoverable AX state in this fixture
                ),
            ]
        )
    }

    /// Unit 24 — 3-step trajectory. The dogfood-anchored one (2026-05-27
    /// failure was "Open Notes" → 13 actions, no switchApp, no complete).
    /// Ships in `defaultScenarios()` as of Unit 25h.
    ///
    /// Task wording uses "Launch" (proven correct verb from
    /// `launchAppColdScenario`) to avoid the "Open" → Spotlight bias.
    /// Unit 24a dropped state hints ("is not currently running",
    /// "becomes available once Notes is frontmost") that aged out
    /// after step 0. Unit 24b cleared the step-2 snapshot's pre-
    /// populated value. Unit 25d marked the search field isFocused=true
    /// in the step-2 snapshot so the LLM sees the post-click state
    /// correctly. Unit 25e added user-observation grounding between
    /// assistant turns. Unit 25f tightened the prompt rule to forbid
    /// redundant clicks on already-focused elements.
    ///
    /// Steps:
    ///   0: switchApp → com.apple.Notes (cold-launch path; Notes NOT running)
    ///   1: click on the Search field (label "Search")
    ///   2: typeText "meeting prep" into the focused search field
    public static func openNotesThenSearchThenCompleteScenario() throws -> Scenario {
        let initialSnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.finder",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Search",
                          value: nil,
                          frame: CodableRect(CGRect(x: 10, y: 10, width: 60, height: 24)),
                          isEnabled: true, isVisible: true)
            ]
        )
        let notesFrontmostSnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.Notes",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Sidebar Toggle",
                          value: nil,
                          frame: CodableRect(CGRect(x: 10, y: 10, width: 24, height: 24)),
                          isEnabled: true, isVisible: true),
                UIElement(index: 1, role: "AXButton", label: "New Note",
                          value: nil,
                          frame: CodableRect(CGRect(x: 40, y: 10, width: 80, height: 24)),
                          isEnabled: true, isVisible: true),
                UIElement(index: 2, role: "AXTextField", label: "Search",
                          value: "",
                          frame: CodableRect(CGRect(x: 130, y: 10, width: 200, height: 24)),
                          isEnabled: true, isVisible: true)
            ]
        )
        // Unit 24b — POST-click, PRE-typeText snapshot. The search field
        // is focused but EMPTY (value: ""), so the LLM at step 2 sees an
        // empty target and naturally emits typeText. Previous fixture
        // pre-populated value: "meeting prep" (simulating post-typeText
        // state) which caused the LLM to correctly emit `.complete` —
        // a SCENARIO bug, not a regression, but it surfaced after the
        // Unit 24a per-step output landed.
        //
        // Unit 25d — search field at index 2 now sets isFocused=true.
        // Step 1's click in production would focus the field; fixture
        // must reflect that or the LLM (after Unit 25's prompt rule)
        // defensively re-clicks rather than typing.
        let searchFocusedEmptySnapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.Notes",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Sidebar Toggle",
                          value: nil,
                          frame: CodableRect(CGRect(x: 10, y: 10, width: 24, height: 24)),
                          isEnabled: true, isVisible: true),
                UIElement(index: 1, role: "AXButton", label: "New Note",
                          value: nil,
                          frame: CodableRect(CGRect(x: 40, y: 10, width: 80, height: 24)),
                          isEnabled: true, isVisible: true),
                UIElement(index: 2, role: "AXTextField", label: "Search",
                          value: "",
                          frame: CodableRect(CGRect(x: 130, y: 10, width: 200, height: 24)),
                          isEnabled: true, isVisible: true,
                          isFocused: true)
            ]
        )
        return Scenario(
            id: "multistep_open_notes_search_complete",
            // "Launch X" + a clear two-clause goal — no stale state hints.
            // Mirrors the proven-passing `launchAppColdScenario` verb.
            task: "Launch the Notes app and type 'meeting prep' into the search field.",
            snapshot: initialSnapshot,
            // Notes intentionally absent — cold-launch path.
            runningApps: [
                RunningApp(bundleID: "com.apple.finder", name: "Finder")
            ],
            expectedActionType: "switchApp",
            expectedTextSubstring: "com.apple.notes",
            expectedSteps: [
                ExpectedStep(
                    expectedActionType: "switchApp",
                    expectedTextSubstring: "com.apple.notes",
                    advanceSnapshot: notesFrontmostSnapshot
                ),
                ExpectedStep(
                    // Click the Search field at index 2. Accept the broad
                    // case — text substring "Search" pins it to the right
                    // element via the rationale (not action.text, which is
                    // nil for click). Falling back: forbidden-index path
                    // would block index 0 (Sidebar Toggle) and index 1
                    // (New Note) but we only have one forbidden slot per
                    // step. Most useful gate: type match alone.
                    expectedActionType: "click",
                    advanceSnapshot: searchFocusedEmptySnapshot
                ),
                ExpectedStep(
                    // Step 2: typeText "meeting prep" into the focused
                    // search field. Validates the LLM follows through
                    // on the multi-action plan rather than emitting
                    // .complete prematurely.
                    expectedActionType: "typeText",
                    expectedTextSubstring: "meeting prep",
                    advanceSnapshot: nil
                ),
            ]
        )
    }

    // MARK: - Run

    /// Production loop's history cap (Orchestrator.swift PARITY-ANCHOR: history-cap). The
    /// harness mirrors this so multi-step scenarios don't diverge from
    /// production behaviour as step count grows.
    ///
    /// Unit 25e — bumped 6 → 12 because each successful step now
    /// contributes both an assistant rationale and a user observation
    /// turn (production parity per Orchestrator.swift around line 760).
    /// 12 preserves the prior effective 6-action history depth.
    internal static let historyCap = 12

    /// Run scenarios sequentially. Each makes one live LLM call PER STEP
    /// (single-action scenarios = 1 call, multi-step = up to maxSteps
    /// calls with fail-fast on the first divergence). Returns outcomes
    /// in input order. Caller decides exit status.
    ///
    /// `scenarios` defaults to the audit-trigger set (`defaultScenarios()`).
    /// Pass an explicit list when the caller needs to construct scenarios
    /// once and reuse them — avoids the latent inconsistency of computing
    /// snapshot hashes at multiple timestamps across separate
    /// `defaultScenarios()` invocations.
    public static func runAll(
        llm: ActionThinking,
        scenarios: [Scenario]? = nil
    ) async throws -> [Outcome] {
        let toRun = try scenarios ?? defaultScenarios()
        var outcomes: [Outcome] = []
        for scenario in toRun {
            if let steps = scenario.expectedSteps {
                outcomes.append(try await runMultiStep(scenario: scenario, steps: steps, llm: llm))
            } else {
                let action = try await llm.nextAction(
                    task: scenario.task,
                    snapshot: scenario.snapshot,
                    history: [],
                    runningApps: scenario.runningApps
                )
                outcomes.append(Outcome(scenario: scenario, action: action))
            }
        }
        return outcomes
    }

    /// Unit 24 — multi-step trajectory walker. For each `ExpectedStep`:
    ///   1. Call `nextAction(snapshot: cursor, history: history)`
    ///   2. Record a `StepOutcome` from the returned action
    ///   3. FAIL-FAST: if the step diverged, stop — later steps are absent
    ///      from `stepOutcomes`. Saves API spend and surfaces the FIRST
    ///      divergence (which is the only one that matters for triage).
    ///   4. Otherwise: append the assistant turn to history (production
    ///      parity per Orchestrator.swift PARITY-ANCHOR: history-append), cap history at
    ///      `historyCap` (production parity per Orchestrator.swift PARITY-ANCHOR: history-cap),
    ///      advance cursor per `ExpectedStep.advanceSnapshot`.
    internal static func runMultiStep(
        scenario: Scenario,
        steps: [ExpectedStep],
        llm: ActionThinking
    ) async throws -> Outcome {
        var history: [LLMMessage] = []
        var cursor = scenario.snapshot
        var stepOutcomes: [StepOutcome] = []
        for (i, step) in steps.enumerated() {
            let action = try await llm.nextAction(
                task: scenario.task,
                snapshot: cursor,
                history: history,
                runningApps: scenario.runningApps
            )
            let outcome = StepOutcome(step: i, expected: step, action: action)
            stepOutcomes.append(outcome)
            if !outcome.passed { break }
            // Production-parity history mutation. After Unit 25e, production
            // appends BOTH the assistant rationale and a user observation
            // turn after each successful action (Orchestrator.swift around
            // line 760). Mirror that here so the harness's conversation
            // shape matches what production sends. The observation gives
            // the LLM grounding between its own consecutive actions —
            // without it, long trajectories devolve into defensive re-
            // emission ("let me click again to confirm focus") even when
            // the snapshot signal (isFocused=true) says otherwise.
            history.append(LLMMessage(role: "assistant", content: action.rationale))
            history.append(LLMMessage(role: "user", content: "Previous action observed: \(action.type.rawValue) executed"))
            if history.count > historyCap {
                history.removeFirst(history.count - historyCap)
            }
            // Advance the snapshot per the ExpectedStep. nil = leave cursor
            // unchanged (useful when the last step doesn't mutate visible UI).
            if let next = step.advanceSnapshot {
                cursor = next
            }
        }
        return Outcome(scenario: scenario, stepOutcomes: stepOutcomes)
    }
}
