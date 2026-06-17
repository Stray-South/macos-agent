import Testing
import CoreGraphics
import Foundation
@testable import MacAgentCore

// H2 — pure analyzer behind the real-app perception harness. The live capture
// needs Accessibility + a real machine (MacOSAgentPerceptionHarness CLI); the
// fidelity classification it produces is tested here without either.
@Suite struct PerceptionFidelityTests {

    private func el(_ i: Int, role: String, label: String, focused: Bool = false) -> UIElement {
        UIElement(index: i, role: role, label: label, value: nil,
                  frame: CodableRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                  isEnabled: true, isVisible: true, isFocused: focused)
    }

    @Test func analyze_richSnapshot_reportsRolesFocusAndLabels() throws {
        let snap = try PerceptionSnapshot.make(
            timestamp: .now, focusedAppBundleID: "com.apple.Notes",
            elements: [el(0, role: "AXButton", label: "New Note", focused: true),
                       el(1, role: "AXButton", label: "Delete"),
                       el(2, role: "AXStaticText", label: "")])
        let f = PerceptionFidelity.analyze(label: "Notes", requestedBundleID: "com.apple.Notes", snapshot: snap)
        #expect(f.elementCount == 3)
        #expect(!f.axBlind)
        #expect(f.hasFocusedElement)
        #expect(f.roleCounts["AXButton"] == 2)
        #expect(f.sampleLabels.contains("New Note"))
        #expect(!f.sampleLabels.contains(""))   // empty labels filtered out
        #expect(!f.bundleMismatch)
    }

    @Test func analyze_emptySnapshot_isAxBlind() throws {
        let snap = try PerceptionSnapshot.make(
            timestamp: .now, focusedAppBundleID: "com.apple.systempreferences", elements: [])
        let f = PerceptionFidelity.analyze(label: "System Settings",
                                           requestedBundleID: "com.apple.systempreferences", snapshot: snap)
        #expect(f.axBlind)
        #expect(f.elementCount == 0)
    }

    @Test func analyze_frontmostMismatch_flagsBundleMismatch() throws {
        // Asked to probe Notes but the AX walk landed on Finder (Notes never
        // came frontmost) — the row must flag that its fidelity is not Notes'.
        let snap = try PerceptionSnapshot.make(
            timestamp: .now, focusedAppBundleID: "com.apple.finder",
            elements: [el(0, role: "AXButton", label: "x")])
        let f = PerceptionFidelity.analyze(label: "Notes", requestedBundleID: "com.apple.Notes", snapshot: snap)
        #expect(f.bundleMismatch)
    }

    @Test func failure_recordsError_andIsNotAxBlind() {
        let f = PerceptionFidelity.failure(label: "Mail", requestedBundleID: "com.apple.mail", error: "not installed")
        #expect(f.error == "not installed")
        #expect(!f.axBlind)   // an error is distinct from a clean-but-empty walk
    }

    @Test func render_summarizesRichBlindAndErrors() throws {
        let rich = PerceptionFidelity.analyze(label: "Notes", requestedBundleID: "com.apple.Notes",
            snapshot: try PerceptionSnapshot.make(timestamp: .now, focusedAppBundleID: "com.apple.Notes",
                elements: [el(0, role: "AXButton", label: "x")]))
        let blind = PerceptionFidelity.analyze(label: "Sys", requestedBundleID: "com.apple.systempreferences",
            snapshot: try PerceptionSnapshot.make(timestamp: .now,
                focusedAppBundleID: "com.apple.systempreferences", elements: []))
        let err = PerceptionFidelity.failure(label: "Mail", requestedBundleID: "com.apple.mail", error: "x")
        let out = PerceptionFidelity.render([rich, blind, err])
        #expect(out.contains("1 AX-rich, 1 AX-blind (vision-dependent), 1 error"))
        #expect(out.contains("vision-dependent"))
    }
}
