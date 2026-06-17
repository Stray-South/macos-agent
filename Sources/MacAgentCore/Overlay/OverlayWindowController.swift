import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

/// Decision returned by the 4-button approval card.
/// Backwards-compatible: the old `completion: (Bool)` path maps to `.approveOnce`/`.rejectOnce`.
public enum ApprovalDecision: Sendable {
    case approveOnce
    case alwaysAllow          // creates an allow rule scoped to this (type, app, label)
    case rejectOnce
    case neverAllow           // creates a deny rule scoped to this (type, app, label)
}

@MainActor
public protocol OverlayControlling: AnyObject, Sendable {
    func highlight(frame: CGRect)
    func clearHighlight()
    /// Four-outcome approval callback. New conformers implement this.
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void)
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool)
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void)
    /// Show a phase label ("Observing…", "Thinking…") in the HUD when no action is pending.
    func updatePhase(_ phase: String?)
    /// Forward an approval decision from an external surface (e.g. LauncherView's
    /// in-window approval card). Funnels through the same OverlayModel.decide
    /// chokepoint as HUD button clicks, so the gate continuation resumes exactly
    /// once regardless of which surface the user picked. Idempotent: second call
    /// after the continuation already resumed is a no-op.
    func applyDecision(_ decision: ApprovalDecision)
    /// Subscribe to a fire-and-forget signal that any approval decision (from
    /// either HUD or external surface) has just been dispatched. AppModel uses
    /// this to clear its `pendingApprovalAction` mirror synchronously, closing
    /// the race window where a HUD click resolved the gate but the orchestrator
    /// hadn't yet emitted `.executionFinished` to clear AppModel.
    func setApprovalResolvedHandler(_ handler: @escaping @Sendable () -> Void)
}

public extension OverlayControlling {
    func updatePhase(_ phase: String?) {}
    /// Default no-op so the 12 test mocks of `OverlayControlling` compile unchanged
    /// when this method ships. Real conformers (OverlayWindowController) override.
    func applyDecision(_ decision: ApprovalDecision) {}
    /// Default no-op so mocks that don't care about HUD-AppModel sync compile unchanged.
    func setApprovalResolvedHandler(_ handler: @escaping @Sendable () -> Void) {}
    /// Legacy two-outcome shim — maps Bool to approveOnce/rejectOnce so existing test mocks
    /// that only implement the old signature continue to compile unchanged.
    func setPendingAction(_ action: AgentAction, completion: @escaping (Bool) -> Void) {
        setPendingAction(action) { decision in
            completion(decision == .approveOnce || decision == .alwaysAllow)
        }
    }
}

// @unchecked Sendable is safe: the class is @MainActor-isolated, which serializes all
// access to the main thread. NSPanel and NSWindow are not Sendable, but main-thread
// confinement guarantees no concurrent mutation.
@MainActor
public final class OverlayWindowController: NSObject, @unchecked Sendable {
    private let model = OverlayModel()
    private var hudPanel: NSPanel?
    private var highlightWindow: NSWindow?

    public override init() {
        super.init()
        configureHUD()
        configureHighlightWindow()
    }

    public func highlight(frame: CGRect) {
        model.highlightedFrame = frame
        // Move the highlight window to the screen that contains the highlighted element
        // and bring it forward on first use — deferred from init to avoid ordering a window
        // before the window server connection is ready.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            highlightWindow?.setFrame(screen.frame, display: false)
        }
        highlightWindow?.orderFrontRegardless()
    }

    public func clearHighlight() {
        model.highlightedFrame = nil
        highlightWindow?.orderOut(nil)
    }

    public func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        model.pendingAction = action
        model.onDecision = completion
        hudPanel?.orderFrontRegardless()
    }

    public func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {
        model.currentTask = task
        model.safetyTier = tier
        model.isRunning = isRunning
        if isRunning {
            repositionHUDToFrontmostAppScreen()
            hudPanel?.orderFrontRegardless()
        } else {
            model.currentPhase = nil
            model.reject()
            hudPanel?.orderOut(nil)
        }
    }

    public func updatePhase(_ phase: String?) {
        model.currentPhase = phase
        if phase != nil {
            repositionHUDToFrontmostAppScreen()
            hudPanel?.orderFrontRegardless()
        }
    }

    /// Moves the HUD panel to the screen that contains the frontmost app's window.
    /// Uses the AX-reported window origin to determine the correct screen.
    /// Falls back to NSScreen.main if detection fails.
    private func repositionHUDToFrontmostAppScreen() {
        let targetScreen = screenForFrontmostApp() ?? NSScreen.main
        guard let screen = targetScreen else { return }
        // visibleFrame excludes the menu bar and reserved-notch area; using .frame
        // would place the HUD's top 16 pts under the menu bar on every Mac, and
        // sit the centred title under the camera housing on notched MacBook Pros.
        let frame = CGRect(x: screen.visibleFrame.midX - 340, y: screen.visibleFrame.maxY - 84, width: 680, height: 68)
        hudPanel?.setFrame(frame, display: false)
    }

    private func screenForFrontmostApp() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Unit 11 — when the agent itself is frontmost (cold-start, or
        // operator just clicked back into the launcher), walking our own
        // window positions is non-informative for "where is the operator
        // looking?" Return nil and let the caller's `?? NSScreen.main`
        // fallback land the HUD on the primary display.
        if app.processIdentifier == agentProcessID { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else { return nil }
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(firstWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        var origin = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &origin) else { return nil }
        return NSScreen.screens.first(where: { $0.frame.contains(origin) })
    }

    public func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {
        model.onAbort = handler
    }

    /// Routes an external approval decision through the same OverlayModel.decide
    /// chokepoint the HUD buttons use. If the gate has already resumed (e.g. HUD
    /// click won the race), `onDecision` is nil and this becomes a no-op.
    public func applyDecision(_ decision: ApprovalDecision) {
        model.apply(decision)
    }

    public func setApprovalResolvedHandler(_ handler: @escaping @Sendable () -> Void) {
        model.onApprovalResolved = handler
    }

    private func configureHUD() {
        // Use .zero if NSScreen.main is unavailable at init time — repositionHUDToFrontmostAppScreen()
        // corrects the frame before the panel is ever shown.
        // visibleFrame (not frame) so the HUD clears the menu bar / notch reservation;
        // .frame would put the top 16 pts behind the system menu bar.
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Position near the top-centre — visible area above the main hub.
        let frame = CGRect(x: screen.midX - 340, y: screen.maxY - 84, width: 680, height: 68)
        let panel = HUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = true
        panel.contentView = NSHostingView(rootView: HUDStripView().environmentObject(model))
        // Do NOT show the panel on init — only reveal it when the agent is active.
        hudPanel = panel
    }

    private func configureHighlightWindow() {
        // Must use .frame (not .visibleFrame): HighlightLayerView's y-flip math
        // (proxy.size.height - frame.midY) assumes a full-screen canvas. Switching
        // to visibleFrame would mis-position highlight rings for elements in the
        // upper ~28 pts of the screen.
        let frame = NSScreen.main?.frame ?? .zero
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: HighlightLayerView().environmentObject(model))
        // Do NOT show on init — only bring forward when a highlight is actually set.
        highlightWindow = window
    }
}

extension OverlayWindowController: OverlayControlling {}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var currentTask = ""
    @Published var safetyTier: SafetyTier = .auto
    @Published var isRunning = false
    @Published var pendingAction: AgentAction?
    @Published var highlightedFrame: CGRect?
    /// Current loop phase ("Observing…", "Thinking…"), shown when no action is pending.
    @Published var currentPhase: String?

    var onDecision: ((ApprovalDecision) -> Void)?
    var onAbort: (@Sendable () -> Void)?
    /// Fires after every decision dispatch (HUD or external surface). Lets
    /// observers (AppModel) clear their mirror state synchronously, before the
    /// orchestrator's downstream events arrive.
    var onApprovalResolved: (@Sendable () -> Void)?

    func approve() { decide(.approveOnce) }
    func alwaysAllow() { decide(.alwaysAllow) }
    func reject() { decide(.rejectOnce) }
    func neverAllow() { decide(.neverAllow) }
    /// External-surface entry point — same nil-callback safety as HUD button taps.
    func apply(_ decision: ApprovalDecision) { decide(decision) }

    private func decide(_ decision: ApprovalDecision) {
        let callback = onDecision
        pendingAction = nil
        onDecision = nil
        callback?(decision)
        // Fire the resolved-handler regardless of whether callback was non-nil:
        // a no-op decide (second click after gate already resumed) still wants
        // to tell observers "approval state is settled, clear your mirrors."
        onApprovalResolved?()
    }

    func abort() {
        onAbort?()
    }
}

private struct HUDStripView: View {
    @EnvironmentObject private var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.currentTask.isEmpty ? "Idle" : String(model.currentTask.prefix(60)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let action = model.pendingAction {
                    Text(action.rationale)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // 36a — informed confirm for writeFile: the operator must
                    // see WHICH path and WHAT bytes they're approving, not
                    // just the LLM-controlled rationale. Path + a short
                    // content preview, on the card before any write.
                    if action.type == .writeFile {
                        Text("→ workspace/\(action.filePath ?? "?")")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        if let body = action.text, !body.isEmpty {
                            Text(body.count > 80 ? String(body.prefix(77)) + "…" : body)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else if let phase = model.currentPhase {
                    // No pending action — show current loop phase during observe/think windows.
                    HStack(spacing: 6) {
                        PulsingDot(color: .cyan, size: 6, duration: 0.8)
                        Text(phase)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(badgeTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(badgeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(badgeColor)

            if model.safetyTier != .auto || model.pendingAction != nil {
                // 36a — writeFile gets no standing allow rule (a confirm-tier
                // disk write is approved every time), so hide Always/Never
                // for it: showing them implied a persistent grant the
                // orchestrator silently drops.
                let allowsStandingRule = model.pendingAction?.type != .writeFile
                Button("Approve") { model.approve() }
                    .buttonStyle(.borderedProminent)
                    .help("Approve this action once")
                if allowsStandingRule {
                    Button("Always") { model.alwaysAllow() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .help("Always allow this action type in this app")
                }
                Button("Reject") { model.reject() }
                    .buttonStyle(.bordered)
                    .help("Reject this action once")
                if allowsStandingRule {
                    Button("Never") { model.neverAllow() }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .help("Never allow this action type in this app")
                }
            }

            if model.isRunning {
                Button("Abort") { model.abort() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var badgeTitle: String {
        switch model.safetyTier {
        case .auto: return "AUTO"
        case .preview: return "PREVIEW"
        case .confirm: return "CONFIRM"
        }
    }

    private var badgeColor: Color {
        switch model.safetyTier {
        case .auto: return .green
        case .preview: return .orange
        case .confirm: return .red
        }
    }
}

// PulsingCircle was the HUD-overlay-local pulsing dot; replaced by the
// shared MacAgentCore PulsingDot component. See PulsingDot.swift.

private struct HighlightLayerView: View {
    @EnvironmentObject private var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let frame = model.highlightedFrame {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.cyan, lineWidth: 3)
                        .frame(width: frame.width, height: frame.height)
                        .position(
                            x: frame.midX,
                            y: proxy.size.height - frame.midY
                        )
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: frame)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
    }
}
