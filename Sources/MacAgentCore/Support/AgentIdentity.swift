import Foundation
import ScreenCaptureKit

// MARK: - Canonical agent-process identity
//
// Unit 6 follow-up — single source of truth for "is this PID the agent?"
// Previously, AXPerception (Unit 5) and ComputerUseClient (Unit 6) each
// called `ProcessInfo.processInfo.processIdentifier` independently. A
// future change to what counts as "the agent" (e.g., a launch-agent
// wrapper using a different PID anchor) could silently update one site
// and not the other, leaving AX correctly blocked while screenshots
// still included agent pixels (or vice versa). Both sites now read this
// constant so they cannot diverge.
//
// `public` so the MacOSAgentV0 target (which imports MacAgentCore) can
// read this in AppModel's NSWorkspace observer — Unit 8 needs the same
// agent-identity source from outside MacAgentCore to skip the agent's
// own activations when tracking `lastNonAgentActivePID`. The Process ID
// is set at launch and immutable for the process lifetime.
public let agentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier

// Unit 10 — public agent bundle ID for cold-start prompt differentiation
// + Executor self-switch guard. Lookup at module load: prefer Bundle.main
// (the running .app's Info.plist); fall back to the hardcoded production
// string for swift-test / smoke-target contexts where Bundle.main is the
// xctest harness, not the agent. Same fallback pattern as Unit 5's
// AXPerception self-exclusion comment.
public let agentBundleID: String = Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0"

// MARK: - Protocol for PID-bearing types

/// Minimal protocol over the one `SCRunningApplication` attribute the
/// exclusion filter cares about. Extracted so tests can pass stub structs
/// (since `SCRunningApplication` has no public initializer).
internal protocol ProcessIdentifiable {
    var processID: pid_t { get }
}

extension SCRunningApplication: ProcessIdentifiable {}

// MARK: - Agent-app exclusion list builder

/// Returns the subset of `applications` that belong to the agent's own
/// process. Used by `ComputerUseClient.captureScreen` and `VisionPerception
/// .captureVisualContext` to populate `SCContentFilter(excludingApplications:)`
/// so the agent's launcher / HUD / panel windows are not pixels in the
/// screenshot the LLM sees. Pre-fix, both call sites passed `[]`, which
/// captured the agent overlay obscuring the target app — clicks at those
/// occluded coords hit the agent (CGEvent goes by coord; the overlay is
/// at that coord).
///
/// `agentPID` is injectable so tests can verify the filter logic without
/// being bound to the running process's actual PID. Production callers
/// omit the argument and pick up `agentProcessID`.
internal func agentAppsToExclude<App: ProcessIdentifiable>(
    in applications: [App],
    agentPID: pid_t = agentProcessID
) -> [App] {
    applications.filter { $0.processID == agentPID }
}
