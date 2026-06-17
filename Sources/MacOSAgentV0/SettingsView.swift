import MacAgentCore
import os.log
import SwiftUI

private let settingsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "SettingsView"
)

// MARK: - Persisted settings keys

extension UserDefaults {
    // NOTE: suite name must NOT equal the app's bundle ID — macOS rejects that with
    // "does not make sense and will not work" and silently drops all reads/writes.
    // The name is also a nonisolated constant so @Sendable provider closures
    // (read off the main actor, e.g. the park-ceiling provider) can construct
    // their own suite handle without touching the @MainActor static.
    nonisolated static let agentSuiteName = "com.southernreach.agent.prefs"
    @MainActor static let agentSuite = UserDefaults(suiteName: agentSuiteName) ?? .standard

    var selectedModel: String {
        get {
            let stored = string(forKey: "selectedModel") ?? ""
            if AgentModel.all.contains(where: { $0.id == stored }) { return stored }
            // Stored ID is stale or missing — migrate to default and persist.
            // First launch leaves `stored` empty; only log a migration when a
            // previously valid ID is now invalid (model retirement / whitelist
            // contraction). 2026-05-23 audit removed claude-haiku-4-5-* from
            // the action-model whitelist; this code path silently migrates
            // existing operators to Sonnet 4.6, with one os_log line for
            // observability per AGENTS §LLM Client "never swap silently".
            let fallback = AgentModel.defaultModel.id
            if !stored.isEmpty {
                settingsLog.info(
                    "action model '\(stored, privacy: .public)' no longer valid; reset to '\(fallback, privacy: .public)'"
                )
            }
            set(fallback, forKey: "selectedModel")
            return fallback
        }
        set { set(newValue, forKey: "selectedModel") }
    }

    var defaultAutonomyMode: String {
        get { string(forKey: "defaultAutonomyMode") ?? AutonomyMode.semiAutonomous.rawValue }
        set { set(newValue, forKey: "defaultAutonomyMode") }
    }

    /// When true, `ComputerUseClient` is used instead of `ClaudeLLMClient`.
    /// Computer Use sends a screenshot each step and receives pixel-coordinate actions.
    var useComputerUse: Bool {
        get { bool(forKey: "useComputerUse") }
        set { set(newValue, forKey: "useComputerUse") }
    }

    /// When true, typeText payloads > 20 chars route through NSPasteboard.general
    /// + cmd+v instead of typing every character via CGEventKeyboardSetUnicodeString.
    /// Faster (~3-5x) for long text but exposes the payload to clipboard-monitor
    /// apps for ~150ms — a privacy / exfiltration trade-off. Default false.
    /// No Settings UI toggle yet; flip via `defaults write com.southernreach.agent.prefs useFastPasteForLongText -bool YES`.
    var useFastPasteForLongText: Bool {
        get { bool(forKey: "useFastPasteForLongText") }
        set { set(newValue, forKey: "useFastPasteForLongText") }
    }

    /// Model used by `ComputerUseClient` when Computer Use mode is on. Decoupled
    /// from `selectedModel` because the two pickers answer independent questions:
    /// action LLM (custom tool, any whitelisted model) vs CU model (Anthropic
    /// native tool, restricted to models compatible with `computer-use-2025-11-24`).
    var computerUseModelID: String {
        get {
            let stored = string(forKey: "computerUseModelID") ?? ""
            if ComputerUseModel.all.contains(where: { $0.id == stored }) { return stored }
            let fallback = ComputerUseModel.defaultModel.id
            set(fallback, forKey: "computerUseModelID")
            return fallback
        }
        set { set(newValue, forKey: "computerUseModelID") }
    }

    /// True after the user has dismissed the welcome screen at least once.
    /// Prevents the welcome screen from re-appearing on every cold launch.
    var hasSeenWelcome: Bool {
        get { bool(forKey: "hasSeenWelcome") }
        set { set(newValue, forKey: "hasSeenWelcome") }
    }

    /// Persisted launcher-window width. Default 480 (the original hub width)
    /// when unset. SwiftUI's `WindowGroup` doesn't persist size natively, so
    /// MacAgentApp attaches an NSWindow resize observer that writes back to
    /// these keys. Cap to a safe upper bound (max display width range) so a
    /// pathological prior session can't lock the window off-screen.
    var launcherWidth: Double {
        get {
            let stored = double(forKey: "launcherWidth")
            return stored > 0 ? stored.clamped(to: 360...8000) : 480
        }
        set { set(newValue.clamped(to: 360...8000), forKey: "launcherWidth") }
    }

    /// Persisted launcher-window height. Default 640.
    var launcherHeight: Double {
        get {
            let stored = double(forKey: "launcherHeight")
            return stored > 0 ? stored.clamped(to: 480...8000) : 640
        }
        set { set(newValue.clamped(to: 480...8000), forKey: "launcherHeight") }
    }

    /// Unit 15 — F.6 v1 stretch. When true, AppModel wraps the
    /// production `KeywordTaskGuard` in an `LLMTaskClassifier` that
    /// makes a single Haiku call before `Orchestrator.run()` emits
    /// `.started`. Adds ~500ms p50 latency to every task. Default
    /// false so the common case has no latency regression; operators
    /// who want the additional semantic-harm coverage opt in.
    var useLLMTaskClassifier: Bool {
        get { bool(forKey: "useLLMTaskClassifier") }
        set { set(newValue, forKey: "useLLMTaskClassifier") }
    }

    /// Unit 19 — when true, AppModel constructs a `SnapshotWriter`
    /// and passes it to the Orchestrator. After every successful
    /// `observe()` the snapshot is persisted to
    /// `~/Library/Application Support/MacAgent/snapshots/YYYY-MM-DD/<hash>.json`
    /// for later forensic replay via `swift run MacAgentReplay
    /// --snapshot <hash>`. screenshotPNG is STRIPPED from the
    /// sidecar by default (would otherwise be 100× disk usage).
    /// Default false — feature is opt-in; disk growth without a
    /// purge policy is operator-visible. Manual prune via
    /// `swift run MacAgentReplay --prune-snapshots --older-than N`.
    var persistSnapshots: Bool {
        get { bool(forKey: "persistSnapshots") }
        set { set(newValue, forKey: "persistSnapshots") }
    }

    /// Unit 29c — minutes a parked approval gate may wait before it
    /// self-rejects. 0 means unbounded (the operator explicitly accepts the
    /// unbounded synthetic-keystroke / stale-approve exposure documented in
    /// MANIFEST §Safety Model). Default 60.
    /// Single source of truth for the key + default — also read off the
    /// main actor by AppModel's park-ceiling provider closure, so a change
    /// here can never desync the live heartbeat ceiling from this UI.
    nonisolated static func gateMaxParkMinutes(in suite: UserDefaults) -> Int {
        if suite.object(forKey: "gateMaxParkMinutes") == nil { return 60 }
        return suite.integer(forKey: "gateMaxParkMinutes")
    }

    /// Unit 36 — opt-in agent file workspace. When true, AppModel passes the
    /// 0700 workspace root to the Executor, enabling confirm-tier writeFile to
    /// ~/Library/Application Support/MacAgent/workspace/. Default OFF; the
    /// capability is inert (executor throws "disabled") unless enabled.
    var agentWorkspaceEnabled: Bool {
        get { bool(forKey: "agentWorkspaceEnabled") }
        set { set(newValue, forKey: "agentWorkspaceEnabled") }
    }

    /// Unit 34 — interface complexity toggle. false (default) = simple
    /// chat-first window: conversation + composer, machinery folded into
    /// expandable step groups. true = the full detail pane (presets,
    /// transparency panel, plan strip, every event inline).
    var detailedInterface: Bool {
        get { bool(forKey: "detailedInterface") }
        set { set(newValue, forKey: "detailedInterface") }
    }

    var gateMaxParkMinutes: Int {
        get { Self.gateMaxParkMinutes(in: self) }
        set { set(newValue, forKey: "gateMaxParkMinutes") }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Available models

struct AgentModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let note: String

    // 2026-05-23 audit removed claude-haiku-4-5-20251001 from this whitelist —
    // multi-tool selection regressed to a degenerate click/wait/cmd+tab loop
    // across all 6 Lane 1 tasks (no switchApp / typeText / menuSelect / scroll
    // ever emitted). Haiku remains valid for the planner (ClaudeTaskPlanner
    // default) and for Computer Use under the old-beta CU header — both use
    // simpler tool schemas where Haiku performs correctly.
    static let all: [AgentModel] = [
        AgentModel(id: "claude-opus-4-6",              displayName: "Claude Opus 4.6",    note: "Most capable · slower"),
        AgentModel(id: "claude-sonnet-4-6",            displayName: "Claude Sonnet 4.6",  note: "Balanced · recommended"),
    ]

    static let defaultModel = all[1] // Sonnet 4.6

    var subtitleColor: Color {
        switch id {
        case let s where s.hasPrefix("claude-opus"):   return .purple
        default:                                        return .blue
        }
    }
}

// MARK: - Computer Use models
// Restricted to IDs Anthropic accepts under either `computer-use-2025-11-24`
// (new beta) or `computer-use-2025-01-24` (old beta). Kept separate from
// `AgentModel.all` because the two pickers answer independent questions:
// - Action LLM (custom multi-tool schema; AgentModel.all): the model must
//   reliably emit switchApp / typeText / menuSelect / scroll under the
//   custom tool schema. The 2026-05-23 audit caught Haiku 4.5 regressing
//   to click-only here; Haiku is removed from AgentModel.all.
// - CU model (this list): Anthropic's native tool schema. Haiku 4.5 works
//   correctly under the old-beta CU header and stays whitelisted here.
struct ComputerUseModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let note: String

    // Per Anthropic CU docs (J-2 dual-beta support):
    // New beta (`computer-use-2025-11-24` + `computer_20251124`):
    //   - Opus 4.7: 1:1 coords with sent image (up to 2576-px long edge)
    //   - Opus 4.6 / Sonnet 4.6: 1568-px downsample + inverse rescale
    // Old beta (`computer-use-2025-01-24` + `computer_20250124`):
    //   - Sonnet 4.5 / Haiku 4.5 / Opus 4.1 / Sonnet 4 / Opus 4: 1568-px scaled
    // ComputerUseClient.cuToolVersion dispatches the right beta per model.
    // Whitelist excludes unversioned `claude-sonnet-4` and `claude-opus-4` —
    // both retire 2026-06-15 per Anthropic's deprecation list (announced
    // 2026-04-14). Stored UserDefaults values pointing at those aliases
    // auto-migrate via the `computerUseModelID` getter self-heal at line 39-48.
    static let all: [ComputerUseModel] = [
        ComputerUseModel(id: "claude-opus-4-7",            displayName: "Claude Opus 4.7",   note: "1:1 coords · highest capability · most expensive"),
        ComputerUseModel(id: "claude-opus-4-6",            displayName: "Claude Opus 4.6",   note: "Scaled · very capable"),
        ComputerUseModel(id: "claude-sonnet-4-6",          displayName: "Claude Sonnet 4.6", note: "Scaled · balanced · recommended"),
        ComputerUseModel(id: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5", note: "Scaled · old beta · less expensive"),
        ComputerUseModel(id: "claude-haiku-4-5-20251001",  displayName: "Claude Haiku 4.5",  note: "Scaled · old beta · ~5× cheaper · no zoom"),
        ComputerUseModel(id: "claude-opus-4-1",            displayName: "Claude Opus 4.1",   note: "Scaled · old beta · legacy"),
    ]

    static let defaultModel = all[2] // Sonnet 4.6 per MANIFEST.md

    var subtitleColor: Color {
        switch id {
        case let s where s.hasPrefix("claude-opus"):   return .purple
        default:                                        return .blue
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    // Driven by AppModel so changes take effect immediately in the live hub.
    @EnvironmentObject private var model: AppModel

    @State private var rawKey: String = ""
    @State private var showKey: Bool = false
    @State private var keyStatus: KeyStatus = .unknown
    @State private var selectedModelID: String = UserDefaults.agentSuite.selectedModel
    @State private var selectedCUModelID: String = UserDefaults.agentSuite.computerUseModelID
    @State private var useComputerUse: Bool = UserDefaults.agentSuite.useComputerUse
    @State private var selectedModeRaw: String = UserDefaults.agentSuite.defaultAutonomyMode
    /// Unit 15 — LLM-augmented pre-run task safety toggle (F.6 v1 stretch).
    @State private var useLLMTaskClassifier: Bool = UserDefaults.agentSuite.useLLMTaskClassifier
    /// Unit 19 — snapshot sidecar opt-in.
    @State private var persistSnapshots: Bool = UserDefaults.agentSuite.persistSnapshots
    @State private var gateMaxParkMinutes: Int = UserDefaults.agentSuite.gateMaxParkMinutes
    @AppStorage("detailedInterface", store: UserDefaults.agentSuite) private var detailedInterfaceSetting: Bool = false
    @State private var agentWorkspaceEnabled: Bool = UserDefaults.agentSuite.agentWorkspaceEnabled
    @State private var receiptRows: [ReceiptRow] = []
    @State private var receiptLoadError: String? = nil
    /// Count of receipt JSONL lines that failed to decode during the last load.
    /// Surfaced as a small "N unreadable" chip in the section header — F5.
    @State private var skippedReceiptCount: Int = 0
    @State private var hardBoundaries: [String] = []
    @State private var positions: [String: String] = [:]
    @State private var taskHistory: [TaskRecord] = []
    @State private var newBoundary: String = ""
    @State private var capabilityRules: [CapabilityRule] = []
    /// Surfaces `CapabilityRuleStore.lastPersistError()` so the UI shows when
    /// rules aren't landing on disk. Refreshed alongside `capabilityRules` on
    /// every Settings reload and every revoke / reset. Nil when persistence
    /// is healthy. AuDHD-safe: rendered as an inline Section, never a toast,
    /// no auto-dismiss.
    @State private var rulePersistError: String? = nil

    // Allocated once — DateFormatter is expensive and SwiftUI re-evaluates view bodies often.
    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    enum KeyStatus: Equatable {
        case unknown, testing, valid, invalid(String)

        var label: String {
            switch self {
            case .unknown:          return ""
            case .testing:          return "Testing…"
            case .valid:            return "Connected"
            case .invalid(let m):   return m
            }
        }
        var color: Color {
            switch self {
            case .valid:   return .green
            case .invalid: return .red
            default:       return .secondary
            }
        }
        var icon: String {
            switch self {
            case .valid:   return "checkmark.circle.fill"
            case .invalid: return "xmark.circle.fill"
            case .testing: return "arrow.trianglehead.2.clockwise"
            default:       return ""
            }
        }
    }

    private var taskSafetySection: some View {
        Section {
            Toggle(isOn: $useLLMTaskClassifier) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM semantic check before each run")
                        .font(.system(size: 13, weight: .medium))
                    Text("Adds a ~500ms Haiku call to evaluate the task for semantic harm beyond the keyword banlist. The keyword guard always runs first — this only triggers when the keyword pass is clean. Network failures fall back to the keyword verdict. Borderline-destructive tasks (e.g. \"empty the trash\") are allowed but the FIRST action is escalated to confirm so you see it before the agent commits.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: useLLMTaskClassifier) { _, newValue in
                UserDefaults.agentSuite.useLLMTaskClassifier = newValue
                // AppModel reads the toggle when constructing the next
                // Orchestrator (per-run), so no live-reconfigure call
                // here. The next task starts the new guard.
            }
        } header: {
            Label("Pre-run task safety", systemImage: "shield.lefthalf.filled")
        } footer: {
            Text("Default: off. The keyword-based guard always runs regardless of this setting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Unit 34a — interface complexity, mirrored here for discoverability
    /// (the top-bar toggle is hover-labelled only).
    private var interfaceSection: some View {
        Section {
            Toggle(isOn: $detailedInterfaceSetting) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detailed interface")
                        .font(.system(size: 13, weight: .medium))
                    Text("Shows presets, the plan strip, the transparency panel, and every agent step inline. Off (default): a simple chat window — steps fold into expandable groups, and the approval card appears whenever a decision is waiting. The expand/collapse button in the main window's top bar toggles the same setting.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Label("Interface", systemImage: "rectangle.expand.vertical")
        }
    }

    /// Unit 29c — park ceiling for an unanswered approval gate.
    private var approvalParkSection: some View {
        Section {
            Picker(selection: $gateMaxParkMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("Never (unbounded)").tag(0)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop waiting for approval or an answer after")
                        .font(.system(size: 13, weight: .medium))
                    Text("A paused approval beeps each minute until you answer (F13 approve · F14 reject — rejecting stops the task · F15 abort). If this window passes with no decision the task stops safely — the action is rejected, never auto-approved. \"Never\" keeps waiting indefinitely; while parked, any process with Accessibility rights could synthesize an approval keypress, so unbounded parking is only recommended on a locked-down machine. Voice Control users: if your keyboard has no F13–F15 keys, create custom commands (Settings → Accessibility → Voice Control → Commands) that press them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: gateMaxParkMinutes) { _, newValue in
                UserDefaults.agentSuite.gateMaxParkMinutes = newValue
                // Read live by the orchestrator's ceiling provider at each
                // heartbeat — no rebuild needed, applies mid-park.
            }
        } header: {
            Label("Approval wait limit", systemImage: "clock.badge.questionmark")
        } footer: {
            Text("Default: 1 hour. Applies immediately — including to an approval or agent question that is already waiting. \"Never\" also lets an unanswered question park and beep indefinitely.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Unit 36 — agent file workspace opt-in.
    private var workspaceSection: some View {
        Section {
            Toggle(isOn: $agentWorkspaceEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow the agent to write files")
                        .font(.system(size: 13, weight: .medium))
                    Text("Lets the agent save text files inside a sandboxed folder (~/Library/Application Support/MacAgent/workspace/). Every write requires your confirmation and can never escape that folder, overwrite your other files, or run anything. Off by default; enabling or disabling takes effect immediately.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: agentWorkspaceEnabled) { _, newValue in
                UserDefaults.agentSuite.agentWorkspaceEnabled = newValue
            }
        } header: {
            Label("Agent workspace", systemImage: "folder.badge.gearshape")
        } footer: {
            Text("Default: off. Writes are confined to the workspace folder and always require confirmation.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Unit 19 — snapshot sidecar opt-in.
    private var forensicsSection: some View {
        Section {
            Toggle(isOn: $persistSnapshots) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Persist snapshots to disk")
                        .font(.system(size: 13, weight: .medium))
                    Text("After every successful observation, write the perception snapshot (elements, vision OCR, bundle ID) to ~/Library/Application Support/MacAgent/snapshots/YYYY-MM-DD/<hash>.json. Screenshots stripped by default (100× disk usage otherwise). Replay via: swift run MacAgentReplay --snapshot <hash>. Prune via: swift run MacAgentReplay --prune-snapshots --older-than 30.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: persistSnapshots) { _, newValue in
                UserDefaults.agentSuite.persistSnapshots = newValue
                // Next run picks up the new value via makeOrchestrator.
                // No retro-active write for already-completed runs.
            }
        } header: {
            Label("Forensics", systemImage: "doc.text.magnifyingglass")
        } footer: {
            Text("Default: off. Snapshot sidecars enable detailed dogfood-loop forensics but grow disk usage roughly 12–50× per action compared to receipts alone. Prune manually when needed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Form {
            apiKeySection
            modelSection
            autonomySection
            hotkeysSection
            interfaceSection
            workspaceSection
            approvalParkSection
            taskSafetySection
            forensicsSection
            rulesSection
            throughlineSection
            receiptSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .onAppear {
            loadSavedKey()
            Task { await loadReceipts() }
            Task { await loadThroughline() }
            Task { await loadCapabilityRules() }
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField("sk-ant-…", text: $rawKey)
                        } else {
                            SecureField("sk-ant-…", text: $rawKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { saveKey() }

                    Toggle(isOn: $showKey) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(showKey ? "Hide key" : "Show key")
                }

                HStack(spacing: 8) {
                    Button("Save Key") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Test Connection") { Task { await testKey() } }
                        .buttonStyle(.bordered)
                        .disabled(rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyStatus == .testing)

                    if keyStatus != .unknown {
                        HStack(spacing: 4) {
                            if keyStatus == .testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: keyStatus.icon)
                                    .foregroundStyle(keyStatus.color)
                            }
                            Text(keyStatus.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(keyStatus.color)
                        }
                    }
                }

                Text("Stored securely in macOS Keychain — never sent anywhere except Anthropic's API.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Label("Anthropic API Key", systemImage: "key.fill")
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $selectedModelID) {
                ForEach(AgentModel.all) { m in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.displayName).font(.system(size: 13, weight: .medium))
                        Text(m.note).font(.system(size: 11)).foregroundStyle(m.subtitleColor)
                    }
                    .tag(m.id)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selectedModelID) { _, newValue in
                UserDefaults.agentSuite.selectedModel = newValue
                model.applyModelChange(newValue)
            }

            Toggle(isOn: $useComputerUse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Computer Use mode")
                        .font(.system(size: 13, weight: .medium))
                    Text("Claude sees a screenshot each step and clicks by pixel coordinate. More capable on visual apps, slower, uses more tokens.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: useComputerUse) { _, newValue in
                UserDefaults.agentSuite.useComputerUse = newValue
                model.applyPerceptionModeChange(useComputerUse: newValue)
            }

            Picker("Computer Use model", selection: $selectedCUModelID) {
                ForEach(ComputerUseModel.all) { m in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.displayName).font(.system(size: 13, weight: .medium))
                        Text(m.note).font(.system(size: 11)).foregroundStyle(m.subtitleColor)
                    }
                    .tag(m.id)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!useComputerUse)
            .onChange(of: selectedCUModelID) { _, newValue in
                // Only persist + rebuild when the toggle is on. The picker is
                // .disabled in the UI, but the onChange could still fire from
                // programmatic state mutation; gate the write defensively.
                guard useComputerUse else { return }
                UserDefaults.agentSuite.computerUseModelID = newValue
                model.applyPerceptionModeChange(useComputerUse: true)
            }
            if !useComputerUse {
                Text("Toggle Computer Use mode on to select a CU model.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Model", systemImage: "cpu")
        } footer: {
            Text("Standard mode reads the AX element tree — fast and precise. Computer Use mode adds visual understanding for apps without AX support and requires the computer-use-2025-11-24 beta.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Autonomy default

    private var autonomySection: some View {
        Section {
            Picker("Default mode", selection: $selectedModeRaw) {
                ForEach(AutonomyMode.allCases, id: \.rawValue) { mode in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.displayName).font(.system(size: 13, weight: .medium))
                        Text(mode.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selectedModeRaw) { _, newValue in
                UserDefaults.agentSuite.defaultAutonomyMode = newValue
                if let mode = AutonomyMode(rawValue: newValue) {
                    model.setAutonomyMode(mode)
                }
            }
        } header: {
            Label("Default Autonomy Mode", systemImage: "dial.medium")
        } footer: {
            Text("You can still switch modes live from the hub during a run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Voice Control Hotkeys

    private var hotkeysSection: some View {
        Section {
            ForEach(GlobalHotkeyMonitor.bindingDescriptions, id: \.intent) { binding in
                HStack {
                    Text(binding.intent)
                        .font(.system(size: 13))
                    Spacer()
                    Text(binding.key)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(binding.intent) hotkey is \(binding.key)")
            }
        } header: {
            Label("Voice Control Hotkeys", systemImage: "keyboard")
        } footer: {
            Text("Active the whole time the app is open. Approve and Reject answer the current approval gate (a no-op when none is pending); Abort stops an in-progress run. Say “Press F13” (etc.) to use them hands-free. The cross-app keys (work while another app is frontmost) need Accessibility permission — without it, only the keys pressed while this window is frontmost respond.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Capability Rules

    private var rulesSection: some View {
        Section {
            if let err = rulePersistError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rules can't be saved to disk")
                            .font(.system(size: 12, weight: .semibold))
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Rules you create still work for this session but vanish on next launch.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if capabilityRules.isEmpty {
                Text("No rules yet. Use Approve/Reject buttons in the HUD and choose \"Always\" or \"Never\" to create rules.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(capabilityRules.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 8) {
                            Image(systemName: ruleIcon(rule.verdict))
                                .font(.system(size: 11))
                                .foregroundStyle(ruleColor(rule.verdict))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.humanDescription)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text("Created \(Self.historyDateFormatter.string(from: rule.createdAt))")
                                    if rule.triggerCount > 0 {
                                        Text("· triggered \(rule.triggerCount)×")
                                    }
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await revokeRule(rule.id) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Revoke this rule")
                        }
                        .padding(.vertical, 5)
                        if index < capabilityRules.count - 1 {
                            Divider()
                        }
                    }
                }
                Button("Reset All Rules") {
                    Task { await resetAllRules() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.system(size: 12))
            }
        } header: {
            Label("Action Rules", systemImage: "lock.shield")
        } footer: {
            Text("Rules created from HUD \"Always\" / \"Never\" buttons. Allow rules cannot bypass the safety floor for destructive or sensitive actions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func ruleIcon(_ verdict: CapabilityRule.Verdict) -> String {
        switch verdict {
        case .allow: return "checkmark.shield.fill"
        case .deny:  return "xmark.shield.fill"
        case .ask:   return "questionmark.circle.fill"
        }
    }

    private func ruleColor(_ verdict: CapabilityRule.Verdict) -> Color {
        switch verdict {
        case .allow: return .green
        case .deny:  return .red
        case .ask:   return .orange
        }
    }

    private func loadCapabilityRules() async {
        capabilityRules = await model.ruleStore.allRules()
        // Surface persistence failures so disk-full / sandbox-denied state is
        // visible to the operator before they wonder why their Always/Never
        // rules vanished on next launch.
        let err = await model.ruleStore.lastPersistError()
        rulePersistError = err?.localizedDescription
    }

    private func revokeRule(_ id: UUID) async {
        await model.ruleStore.remove(id: id)
        await loadCapabilityRules()
    }

    private func resetAllRules() async {
        await model.ruleStore.reset()
        await loadCapabilityRules()
    }

    // MARK: Agent Memory

    private var throughlineSection: some View {
        Section {
            // ── Hard Boundaries ──────────────────────────────────────────────
            Text("Persistent Rules")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)

            if hardBoundaries.isEmpty {
                Text("No rules yet. Add one below and the agent will never cross it, across all future sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(hardBoundaries, id: \.self) { rule in
                        HStack(spacing: 8) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                            Text(rule)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                            Button {
                                Task { await removeBoundaryAndRefresh(rule) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 5)
                        if rule != hardBoundaries.last {
                            Divider()
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("e.g. Never empty the Trash without asking", text: $newBoundary)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { Task { await addBoundaryAndRefresh() } }
                Button("Add") {
                    Task { await addBoundaryAndRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // Disabled when blank or already in the list (R7 — duplicate guard)
                .disabled(
                    newBoundary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || hardBoundaries.contains(
                        ClaudeLLMClient.sanitizeForPrompt(
                            newBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                )
            }

            Divider().padding(.vertical, 4)

            // ── Learned Facts ─────────────────────────────────────────────────
            Text("Learned Facts")
                .font(.system(size: 13, weight: .semibold))

            if positions.isEmpty {
                Text("No facts yet. Run tasks and the agent will establish context here automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                // Sort by key for stable ForEach id (R6 — dict iteration crash fix)
                VStack(spacing: 0) {
                    ForEach(positions.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(value)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                Task { await removePositionAndRefresh(key) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 5)
                        if key != positions.sorted(by: { $0.key < $1.key }).last?.key {
                            Divider()  // last?.key is O(n) but positions is small (<50 items)
                        }
                    }
                }
            }

            Divider().padding(.vertical, 4)

            // ── Task History ──────────────────────────────────────────────────
            Text("Task History")
                .font(.system(size: 13, weight: .semibold))

            if taskHistory.isEmpty {
                Text("No runs recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(taskHistory.prefix(10).enumerated()), id: \.offset) { index, record in
                        HStack(spacing: 8) {
                            Image(systemName: outcomeIcon(record.outcome))
                                .foregroundStyle(outcomeColor(record.outcome))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.task.count > 60
                                     ? String(record.task.prefix(60)) + "…"
                                     : record.task)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(record.outcome) · \(record.stepCount) steps · \(record.appBundleID)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(Self.historyDateFormatter.string(from: record.timestamp))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        if index < min(taskHistory.count, 10) - 1 {
                            Divider()
                        }
                    }
                }
                Button("Clear History") {
                    Task { await clearHistoryAndRefresh() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.system(size: 12))
            }
        } header: {
            Label("Agent Memory", systemImage: "brain.head.profile")
        } footer: {
            Text("Persistent rules are injected into every LLM prompt and never expire. Learned facts accumulate automatically from successful runs.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Receipt Viewer

    private var receiptSection: some View {
        Section {
            if let error = receiptLoadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if receiptRows.isEmpty {
                Text("No receipts yet. Run a task to start the audit trail.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(receiptRows.prefix(30)) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.approved ? .green : .red)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.action)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(row.result)  ·  \(row.tier.uppercased())  ·  \(row.date)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        if row.id != receiptRows.prefix(30).last?.id {
                            Divider()
                        }
                    }
                }
                Button("Refresh") { Task { await loadReceipts() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                Button("Open Receipts Folder") {
                    do {
                        let url = try ReceiptWriter.defaultBaseURL()
                        NSWorkspace.shared.open(url)
                    } catch {
                        receiptLoadError = "Could not locate receipts folder: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        } header: {
            HStack(spacing: 6) {
                Label("Recent Receipts (last 30)", systemImage: "doc.text.fill")
                if skippedReceiptCount > 0 {
                    Text("· \(skippedReceiptCount) unreadable")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Every action the agent takes is logged here for audit. Approved = green, rejected/error = red.")
                Text("⚠️ Receipts contain the **exact text** typed by the agent — including any passwords, 2FA codes, or payment details you approved during a run. The receipts folder is readable by any process running as your user account. Clear it if you record sensitive input.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "0.1.0 (beta)")
            LabeledContent("Receipts", value: "~/Library/Application Support/MacAgent/receipts/")
            LabeledContent("Throughline", value: "~/Library/Application Support/MacAgent/throughline.json")
            LabeledContent("Capability rules", value: "~/Library/Application Support/MacAgent/capability-rules.json")
            LabeledContent("API key", value: "macOS Keychain (com.southernreach.macos-agent-v0)")
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }

    // MARK: Helpers

    private func loadSavedKey() {
        // Env var takes priority over Keychain at runtime. Show the active key
        // (env var or Keychain) so the UI reflects what the agent actually uses.
        // IMPORTANT: we never DISPLAY the borrowed Anthropic CLI key in the text
        // field. ClaudeLLMClient.readKey can return a borrow value, but routing
        // that through the UI's "Save Key" button would silently promote a
        // different tool's secret into our Keychain — exactly the bug
        // Cluster A was meant to close (MANIFEST §API Key Handling).
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        if !envKey.isEmpty {
            rawKey = envKey
            keyStatus = .invalid("Read-only — key is set via environment variable (launchctl setenv or Xcode scheme). Edit it there, not here.")
        } else if let keychainKey = KeychainStore.read() {
            rawKey = keychainKey
            keyStatus = .unknown
        } else {
            rawKey = ""
            // Surface that the agent is running on a borrowed key so the operator
            // knows why no key is shown but the agent still works. Paste-then-Save
            // moves the borrowed (or any new) value into our Keychain explicitly.
            if ClaudeLLMClient.borrowAnthropicCLIKey() != nil {
                keyStatus = .invalid("Using ~/.anthropic/api_key (Anthropic CLI's key) for this session. Paste your own key here and Save to store it in the agent's Keychain.")
            }
        }
        selectedModelID = UserDefaults.agentSuite.selectedModel
        selectedModeRaw = UserDefaults.agentSuite.defaultAutonomyMode
    }

    private func saveKey() {
        // Block saving when the env var is set to a non-empty value — it would
        // override Keychain anyway. Empty env var is treated as absent (matches
        // loadSavedKey above) so Save still works in that edge case.
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        guard envKey.isEmpty else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try ClaudeLLMClient.saveKey(key)
            Task {
                await model.reconfigure()
                // After reconfigure() rebuilds the orchestrator, refresh rule
                // state so any prior persist-error banner reflects the post-
                // reconfigure store (could be the same actor instance, but
                // refreshing is cheap and the alternative is a stale banner).
                await loadCapabilityRules()
            }
            keyStatus = .unknown
        } catch {
            keyStatus = .invalid("Save failed: \(error.localizedDescription)")
        }
    }

    private func loadReceipts() async {
        do {
            let dir = try ReceiptWriter.defaultBaseURL()
            guard FileManager.default.fileExists(atPath: dir.path) else {
                receiptRows = []
                return
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }
                .sorted { lhs, rhs in
                    let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return l > r
                }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short

            let result = decodeReceipts(files: files, decoder: decoder, dateFormatter: df)
            receiptRows = result.rows
            skippedReceiptCount = result.skipped
            receiptLoadError = nil
        } catch {
            receiptLoadError = "Could not load receipts: \(error.localizedDescription)"
        }
    }

    // MARK: Throughline helpers

    private func loadThroughline() async {
        let t = await model.loadThroughline()
        hardBoundaries = t.hardBoundaries
        positions      = t.positions
        taskHistory    = t.taskHistory
    }

    private func addBoundaryAndRefresh() async {
        let trimmed = newBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await model.addBoundary(trimmed)
        newBoundary = ""
        await loadThroughline()
    }

    private func removeBoundaryAndRefresh(_ rule: String) async {
        await model.removeBoundary(rule)
        await loadThroughline()
    }

    private func removePositionAndRefresh(_ key: String) async {
        await model.removePosition(key: key)
        await loadThroughline()
    }

    private func clearHistoryAndRefresh() async {
        await model.clearTaskHistory()
        await loadThroughline()
    }

    private func outcomeIcon(_ outcome: String) -> String {
        switch outcome {
        case "success":  return "checkmark.circle.fill"
        case "rejected": return "xmark.circle.fill"
        case "aborted":  return "arrow.uturn.backward.circle.fill"
        default:         return "xmark.circle.fill"
        }
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "success":  return .green
        case "aborted":  return .orange
        default:         return .red
        }
    }

    private func testKey() async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .testing
        // Ping the models endpoint — costs no tokens and returns 200 for any valid key.
        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200: keyStatus = .valid
                case 401: keyStatus = .invalid("Invalid key (401 Unauthorized).")
                case 403: keyStatus = .invalid("Key lacks permission (403 Forbidden).")
                default:  keyStatus = .invalid("Unexpected status \(http.statusCode).")
                }
            } else {
                keyStatus = .invalid("No HTTP response.")
            }
        } catch {
            keyStatus = .invalid(error.localizedDescription)
        }
    }
}
