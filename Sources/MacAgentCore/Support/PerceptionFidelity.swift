import Foundation

/// H2 — perception fidelity analysis. Turns a real app's PerceptionSnapshot
/// into a structured "what does Accessibility expose here?" record. The whole
/// point of H2 is to replace the claim "perception works" with per-app
/// evidence: which app classes give a rich AX tree the agent can drive
/// directly, and which are AX-blind (empty tree → the run depends on the
/// Vision OCR fallback). Pure + Equatable so it is unit-tested without a
/// display or Accessibility permission; the live capture lives in the
/// MacOSAgentPerceptionHarness CLI.
public struct AppFidelity: Equatable, Sendable {
    public let label: String              // human name, e.g. "Notes"
    public let requestedBundleID: String  // what the harness asked to probe
    public let observedBundleID: String   // what AX actually walked (frontmost)
    public let elementCount: Int
    public let truncated: Bool            // > 300-element cap hit
    public let hasFocusedElement: Bool
    public let roleCounts: [String: Int]
    public let sampleLabels: [String]
    public let error: String?             // capture/activation failure, if any

    public init(label: String, requestedBundleID: String, observedBundleID: String,
                elementCount: Int, truncated: Bool, hasFocusedElement: Bool,
                roleCounts: [String: Int], sampleLabels: [String], error: String?) {
        self.label = label
        self.requestedBundleID = requestedBundleID
        self.observedBundleID = observedBundleID
        self.elementCount = elementCount
        self.truncated = truncated
        self.hasFocusedElement = hasFocusedElement
        self.roleCounts = roleCounts
        self.sampleLabels = sampleLabels
        self.error = error
    }

    /// AX-blind = a clean capture that returned zero elements. The agent would
    /// fall back to Vision OCR here (coordinate-only, no semantic roles).
    public var axBlind: Bool { error == nil && elementCount == 0 }
    /// The activated app did not become frontmost — the AX walk hit a
    /// different app, so this row's fidelity is about that app, not the target.
    public var bundleMismatch: Bool {
        error == nil && observedBundleID != requestedBundleID
    }
}

public enum PerceptionFidelity {
    public static func analyze(label: String, requestedBundleID: String,
                               snapshot: PerceptionSnapshot) -> AppFidelity {
        var roles: [String: Int] = [:]
        for e in snapshot.elements { roles[e.role, default: 0] += 1 }
        let samples = snapshot.elements
            .lazy.map(\.label).filter { !$0.isEmpty }
            .prefix(5).map { String($0.prefix(40)) }
        return AppFidelity(
            label: label, requestedBundleID: requestedBundleID,
            observedBundleID: snapshot.focusedAppBundleID,
            elementCount: snapshot.elements.count,
            truncated: snapshot.elementListTruncated,
            hasFocusedElement: snapshot.elements.contains(where: \.isFocused),
            roleCounts: roles, sampleLabels: Array(samples), error: nil)
    }

    public static func failure(label: String, requestedBundleID: String,
                               error: String) -> AppFidelity {
        AppFidelity(label: label, requestedBundleID: requestedBundleID,
                    observedBundleID: "", elementCount: 0, truncated: false,
                    hasFocusedElement: false, roleCounts: [:], sampleLabels: [], error: error)
    }

    public static func render(_ apps: [AppFidelity]) -> String {
        var out = "Perception fidelity report — \(apps.count) app(s) probed\n"
        out += "  \(String(repeating: "─", count: 56))\n"
        for a in apps {
            out += "  \(a.label.padded(to: 18))\(a.requestedBundleID.padded(to: 30))"
            if let err = a.error {
                out += "ERROR: \(err)\n"
                continue
            }
            let kind = a.axBlind ? "AX-blind  " : "AX-rich   "
            out += "\(kind)\(String(a.elementCount).padded(to: 5)) elements"
            out += a.hasFocusedElement ? "  (focus)" : ""
            out += a.truncated ? "  (truncated)" : ""
            if a.bundleMismatch { out += "  ⚠️ walked \(a.observedBundleID)" }
            out += "\n"
            if a.axBlind {
                out += "  \(String(repeating: " ", count: 48))→ vision-dependent (no AX tree)\n"
            } else {
                let roles = a.roleCounts.sorted { $0.value > $1.value }.prefix(5)
                    .map { "\($0.key) \($0.value)" }.joined(separator: "  ")
                out += "  \(String(repeating: " ", count: 4))roles: \(roles.isEmpty ? "—" : roles)\n"
                if !a.sampleLabels.isEmpty {
                    out += "  \(String(repeating: " ", count: 4))labels: \(a.sampleLabels.map { "\"\($0)\"" }.joined(separator: ", "))\n"
                }
            }
        }
        let probed = apps.filter { $0.error == nil }
        let rich = probed.filter { !$0.axBlind }.count
        let blind = probed.filter(\.axBlind).count
        let errored = apps.count - probed.count
        out += "  \(String(repeating: "─", count: 56))\n"
        out += "  Summary: \(rich) AX-rich, \(blind) AX-blind (vision-dependent), \(errored) error(s).\n"
        out += "  AX-rich apps drive via the Accessibility tree; AX-blind apps depend on the Vision OCR fallback (coordinate-only, no roles).\n"
        return out
    }
}

private extension String {
    /// Left-align to a column width, padding with spaces; never truncates
    /// (a long bundle id just pushes the next column).
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
