import AppKit
import MacAgentCore
import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var composerFocused: Bool
    @Environment(\.openSettings) private var openSettings
    private let conversationBottomID = "conversation-bottom"
    @State private var appsExpanded: Bool = false
    // Unit 34/34a — simple (chat-first) vs detailed interface. Persisted via
    // AppStorage so any future writer stays in sync. Safety surfaces render
    // in BOTH modes: gated proposals/questions/warnings/failures are .chat
    // (never fold), and the approval card panel appears in simple mode
    // whenever a decision is pending.
    @AppStorage("detailedInterface", store: UserDefaults.agentSuite) private var detailedInterface: Bool = false
    @State private var expandedActivityGroups: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            autonomyControls
            permissionsBanner
            if !model.modelReady {
                apiKeyBanner
            }
            conversationPanel
            if detailedInterface {
                presets
                transparencyPanel
                if !model.visibleApps.isEmpty {
                    visibleAppsPanel
                }
            } else if model.pendingApprovalAction != nil {
                // 34a (fleet Sev-1) — the approval card and its cmd-Return /
                // Escape shortcuts live in transparencyPanel; a parked gate
                // must surface an ACTIONABLE in-window approval card in BOTH
                // modes. Simple mode shows the panel only while a decision
                // is pending.
                transparencyPanel
            }
            composer
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [DT.Surface.backgroundTop, DT.Surface.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
        .onAppear {
            // 250ms delay lets SwiftUI finish laying out the TextField before
            // taking focus — focus set before layout settles is silently
            // dropped on macOS 14. Task @MainActor matches the project's
            // concurrency convention; DispatchQueue.main.asyncAfter (the prior
            // shape) bypassed the actor system and was the only such pattern
            // in this target.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                composerFocused = true
            }
            model.refreshVisibleApps()
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS Agent")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Desktop copilot demo")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Compact permission dots — one per permission; label only shown when not granted.
            // Full details appear in the banner below. Tapping opens the right Settings pane.
            compactPermissionDot(
                icon: "hand.raised.fill",
                label: "System Access",
                granted: model.permissions.accessibilityGranted,
                action: { Task { await model.grantAccessibility() } }
            )
            compactPermissionDot(
                icon: "eye.fill",
                label: "Screen & Remote Desktop",
                granted: model.permissions.screenRecordingGranted,
                action: { Permissions.openScreenRecordingSettings() }
            )
            permissionPill(title: "Model", granted: model.modelReady, action: { openSettings() })
            outcomeBadge
            receiptBadge
            Button {
                detailedInterface.toggle()
            } label: {
                Image(systemName: detailedInterface
                      ? "rectangle.compress.vertical"
                      : "rectangle.expand.vertical")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(detailedInterface
                  ? "Simple view: chat only — steps fold into expandable groups"
                  : "Detailed view: presets, plan, transparency panel, every step inline")
            .accessibilityLabel(detailedInterface ? "Switch to simple view" : "Switch to detailed view")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings  ⌘,")
        }
    }

    /// Banner shown when one or more permissions need attention.
    /// AX missing → orange/blocking. SR missing (but AX granted) → blue/advisory only.
    @ViewBuilder
    private var permissionsBanner: some View {
        // Only show the banner when something actually needs attention.
        if !model.permissions.allGranted || !model.permissions.screenRecordingGranted {
            let isBlocking = !model.permissions.allGranted   // AX missing → Send is disabled
            let bannerColor: Color = isBlocking ? .orange : .blue

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isBlocking ? "lock.shield" : "info.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(bannerColor)
                    Text(isBlocking
                         ? "Accessibility required to run tasks"
                         : "Screen Recording optional — enables vision fallback")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(bannerColor)
                    Spacer()
                    Button("Refresh") {
                        Task { await model.refreshPermissions() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.tccResetDetected {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permissions were reset")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                            Text("This happens when the app is updated/rebuilt, or monthly for Screen Recording on macOS Sequoia. Re-grant below — it's a one-tap fix.")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !model.permissions.accessibilityGranted {
                    permissionRow(
                        icon: "accessibility",
                        title: "Open System Settings → Accessibility",
                        detail: "Tap to open System Settings. Click + and add this app, or enable the toggle if it's already listed. Then click Refresh above.",
                        tint: .orange,
                        action: { Task { await model.grantAccessibility() } }
                    )
                }

                // Screen Recording is optional — AX-only mode works without it.
                // Show in blue so it's clearly non-blocking.
                if !model.permissions.screenRecordingGranted {
                    permissionRow(
                        icon: "eye.fill",
                        title: "Screen Recording & Remote Desktop",
                        detail: model.permissions.accessibilityGranted
                            ? "Optional — enables vision fallback for AX-sparse apps."
                            : "Recommended — enables vision fallback for apps without AX support.",
                        tint: model.permissions.accessibilityGranted ? .blue : .orange,
                        action: { Permissions.openScreenRecordingSettings() }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bannerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(bannerColor.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, tint: Color = .orange, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Compact single-row autonomy mode picker.
    /// Each mode label uses the shortLabel so the row fits at 480pt window width.
    private var autonomyControls: some View {
        HStack(spacing: 6) {
            Text("Autonomy:")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(AutonomyMode.allCases, id: \.self) { mode in
                Button {
                    model.setAutonomyMode(mode)
                } label: {
                    Text(mode.shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            model.autonomyMode == mode ? Color.purple.opacity(0.28) : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(model.autonomyMode == mode ? Color.purple : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(mode.explanation)
            }
            Spacer()
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Free-form chip — deselects any active preset so arbitrary tasks are allowed.
                Button {
                    model.clearPreset()
                    composerFocused = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Free-form")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Any app")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        model.selectedPreset == nil ? Color.blue.opacity(0.20) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                ForEach(DemoPreset.presets) { preset in
                    Button {
                        model.applyPreset(preset)
                        composerFocused = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(preset.supportedApp)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            (model.selectedPreset == preset ? Color.orange.opacity(0.20) : Color.white.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            liveActivityRow
            if detailedInterface {
                planProgressStrip
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField(
                    model.isClarifying
                        ? "Type your answer and press Return…"
                        : "Talk to the agent… Ask for one concrete desktop step.",
                    text: $model.task
                )
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .submitLabel(.send)
                .onSubmit {
                    Task { await model.runTask(); composerFocused = true }
                }
                .accessibilityLabel(model.isClarifying ? "Your answer to the agent's question" : "Message to the agent")
                .accessibilityHint("Type a task or message, then press Return to send")
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: 8) {
                    Button(model.isClarifying ? "Reply" : (model.isRunning ? "Note" : "Send")) {
                        Task { await model.runTask(); composerFocused = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isClarifying ? .orange : (model.isRunning ? .purple : .accentColor))
                    // During a run (note injection / clarify), only require non-empty text —
                    // the model is already running so permission/key checks don't apply.
                    .disabled(
                        model.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        (!model.isRunning && !model.isClarifying && (!model.permissions.allGranted || !model.modelReady))
                    )
                    .help(model.isRunning
                          ? "Note: inject a message into the running agent's context"
                          : model.isClarifying
                            ? "Reply: answer the agent's question"
                            : "Send: start a new task")
                    .accessibilityLabel(model.isClarifying ? "Reply to the agent" : (model.isRunning ? "Send a note to the running agent" : "Send task to the agent"))

                    if model.isRunning {
                        Button("Abort") {
                            Task { await model.abort(); composerFocused = true }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Abort the running task")
                        .accessibilityHint("Stops the agent immediately")
                    } else {
                        Button("Clear") {
                            Task { await model.clearContext(); composerFocused = true }
                        }
                        .buttonStyle(.bordered)
                        .help("Clear conversation context and plan history")
                        .accessibilityLabel("Clear the conversation")
                    }
                }
            }
            if !model.permissions.allGranted {
                Text("⚠ Grant Accessibility to enable the Send button — tap the orange lock above.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
            } else if !model.modelReady {
                Text("⚠ Add your Anthropic API key in Settings (⌘,) to enable the Send button.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
            } else {
                Text(model.status)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityLabel("Status: \(model.status)")
            }
        }
    }

    @ViewBuilder
    private var liveActivityRow: some View {
        if model.isRunning || model.liveActivity != .idle {
            HStack(spacing: 10) {
                PulsingDot(color: .orange, size: 8, duration: 0.9)
                Text(model.liveActivity.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if !model.focusedAppName.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("👁 \(model.focusedAppName)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                Spacer()
            }
            .padding(.horizontal, 2)
        }
    }

    /// Plan step checklist — shown while a multi-step plan is active.
    /// ✓ = completed step, ● = current step, ○ = upcoming step.
    @ViewBuilder
    private var planProgressStrip: some View {
        if !model.planSteps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.planSteps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 7) {
                        Image(
                            systemName: index < model.currentPlanStep
                                ? "checkmark.circle.fill"
                                : (index == model.currentPlanStep ? "circle.fill" : "circle")
                        )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            index < model.currentPlanStep ? Color.green
                                : (index == model.currentPlanStep ? Color.cyan : Color.secondary)
                        )
                        Text(step)
                            .font(.system(
                                size: 11,
                                weight: index == model.currentPlanStep ? .semibold : .regular,
                                design: .rounded
                            ))
                            .foregroundStyle(index == model.currentPlanStep ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        switch model.lastRunOutcome {
        case .idle:
            EmptyView()
        case .success:
            badge("Success", color: .green)
        case .failure:
            badge("Failed", color: .red)
        case .needsVerification:
            badge("Verify", color: .orange)
        }
    }

    @ViewBuilder
    private var transparencyPanel: some View {
        if let preview = model.latestActionPreview {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.pendingApprovalAction != nil ? "Approval Needed" : "Latest Planned Action")
                        .font(.headline)
                    Spacer()
                    badge(preview.tierLabel, color: preview.tierLabel == "AUTO" ? .green : (preview.tierLabel == "PREVIEW" ? .orange : .red))
                }
                Text("Action: \(preview.typeLabel)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text(preview.targetLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(preview.rationale)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)

                if model.pendingApprovalAction != nil {
                    approvalButtons
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // D8: copyable. .textSelection on the VStack propagates to every
            // Text descendant — operator can select rationale text, action
            // type, target label.
            .textSelection(.enabled)
        }
    }

    /// Approval card — renders only when an action is awaiting approval.
    /// Funnels through AppModel.approve/reject/etc, which route to the same
    /// OverlayModel.decide chokepoint the HUD buttons use. Either surface
    /// resumes the gate continuation exactly once; the second click is a
    /// no-op by `pendingApprovalAction == nil` guard.
    private var approvalButtons: some View {
        HStack(spacing: 8) {
            Button("Approve") { model.approve() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Approve this action once (⌘↩)")
                .accessibilityLabel("Approve this action once")
            Button("Always") { model.alwaysAllow() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .help("Always allow this action type in this app")
                .accessibilityLabel("Always allow this action type in this app")
            Button("Reject") { model.reject() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help("Reject this action once (⎋)")
                .accessibilityLabel("Reject this action once")
            Button("Never") { model.neverAllow() }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .help("Never allow this action type in this app")
                .accessibilityLabel("Never allow this action type in this app")
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval decision")
    }

    private var visibleAppsPanel: some View {
        DisclosureGroup(isExpanded: $appsExpanded) {
            VStack(spacing: 0) {
                ForEach(model.visibleApps, id: \.bundleID) { app in
                    HStack(spacing: 8) {
                        Image(systemName: "app.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(app.name)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        Spacer()
                        Text(app.bundleID)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    if app.bundleID != model.visibleApps.last?.bundleID {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                Text("Apps the agent can see (\(model.visibleApps.count))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversation")
                    .font(.headline)
                Spacer()
                if let preset = model.selectedPreset {
                    Text(preset.title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            // D8: textSelection at the panel level propagates to every
            // descendant Text (the bubble text already has its own modifier
            // at line 580; this adds robustness for the bubble headers,
            // timestamps, and the preset label).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(TranscriptBuilder.fold(model.messages, detailed: detailedInterface)) { item in
                            switch item {
                            case .message(let message):
                                conversationBubble(message)
                            case .activityGroup(let group):
                                activityGroupRow(group)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(conversationBottomID)
                    }
                }
                // D7: minimum height so even at the smallest window size the
                // conversation panel shows ~3 message bubbles. Without this
                // the live-activity row + composer + topbar could squeeze
                // the ScrollView to near-zero. `idealHeight` left unset so
                // the panel grows with the window.
                .frame(minHeight: 120, maxHeight: .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    proxy.scrollTo(conversationBottomID, anchor: .bottom)
                }
                .onChange(of: model.isClarifying) { _, clarifying in
                    if clarifying { composerFocused = true }
                }
                .onChange(of: model.messages.count) { oldCount, newCount in
                    // 34a — a shrinking transcript means a context reset;
                    // the stored group ids are orphaned, drop them.
                    if newCount < oldCount {
                        expandedActivityGroups.removeAll()
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(conversationBottomID, anchor: .bottom)
                    }
                }
                .onChange(of: model.liveActivity) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(conversationBottomID, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(DT.Surface.panel, in: RoundedRectangle(cornerRadius: DT.Radius.panel, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
    }

    private func conversationBubble(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label(for: message.role))
                    .font(DT.Font.bubbleHeader)
                    .foregroundStyle(color(for: message.role))
                Spacer()
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(DT.Font.timestamp)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(DT.Font.bubble)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(DT.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: message.role).opacity(0.10), in: RoundedRectangle(cornerRadius: DT.Radius.bubble, style: .continuous))
        // Unit 39 — read each bubble as one element: "<who>: <text>" so a
        // VoiceOver/voice operator hears the speaker and content together
        // instead of the label, timestamp, and body as three stops.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label(for: message.role)): \(message.text)")
    }

    /// Unit 34 — a folded run of .activity messages: one calm, persistent
    /// row ("N steps") that expands inline on click. No auto-collapse, no
    /// animation beyond the disclosure itself — AuDHD structural rules.
    private func activityGroupRow(_ group: [ConversationMessage]) -> some View {
        let groupID = group.first?.id ?? UUID()
        let isExpanded = expandedActivityGroups.contains(groupID)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    expandedActivityGroups.remove(groupID)
                } else {
                    expandedActivityGroups.insert(groupID)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(group.count) step\(group.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.count) agent steps, \(isExpanded ? "expanded" : "collapsed")")
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group) { message in
                        conversationBubble(message)
                    }
                }
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.Surface.activityFold, in: RoundedRectangle(cornerRadius: DT.Radius.chip, style: .continuous))
    }

    private func label(for role: ConversationMessage.Role) -> String {
        switch role {
        case .user: return "You"
        case .agent: return "Agent"
        case .agentSpeech: return "Agent says"
        case .system: return "System"
        }
    }

    private func color(for role: ConversationMessage.Role) -> Color {
        switch role {
        case .user: return DT.Role.user
        case .agent: return DT.Role.agent
        case .agentSpeech: return DT.Role.agentSpeech
        case .system: return DT.Role.system
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// Compact icon+dot — shows full label only when permission is missing.
    /// Keeps the top bar from overflowing the 480pt window width.
    private func compactPermissionDot(icon: String, label: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                if !granted {
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, granted ? 8 : 10)
            .padding(.vertical, 6)
            .background(
                granted ? Color.white.opacity(0.06) : Color.orange.opacity(0.10),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(granted ? Color.clear : Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(granted ? "\(label): granted" : "\(label): tap to open System Settings")
    }

    private func permissionPill(title: String, granted: Bool, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(granted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                if !granted {
                    Text("Tap to enable")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                granted ? Color.white.opacity(0.07) : Color.orange.opacity(0.10),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(granted ? Color.clear : Color.orange.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(granted ? "\(title): granted" : "\(title): tap to open System Settings")
        .disabled(action == nil)
    }

    /// Tappable receipt badge — opens the JSONL file in Finder.
    @ViewBuilder
    private var receiptBadge: some View {
        if let summary = model.latestReceiptSummary {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([summary.fileURL])
            } label: {
                badge("Receipt", color: .cyan)
            }
            .buttonStyle(.plain)
            .help("Open receipt in Finder: \(summary.fileURL.lastPathComponent)")
        }
    }

    /// Compact banner shown when no API key is configured.
    /// The full key entry form lives in Settings (⌘,).
    private var apiKeyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12, weight: .bold))
            Text("API key required —")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            Button("Open Settings  ⌘,") {
                openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// PulsingDot was a local view here; replaced by the shared MacAgentCore
// PulsingDot component to enforce AGENTS.md "single PulsingDot
// (opt-out safe)" structurally. See PulsingDot.swift.
