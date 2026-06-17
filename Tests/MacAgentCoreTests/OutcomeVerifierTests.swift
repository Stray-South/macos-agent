import Testing
import CoreGraphics
import Foundation
@testable import MacAgentCore

// H1 — closed-loop outcome verification. Pure verdict logic, no display.

private func snap(app: String, elements: [UIElement]) throws -> PerceptionSnapshot {
    try PerceptionSnapshot.make(
        timestamp: Date(timeIntervalSince1970: 0),
        focusedAppBundleID: app,
        elements: elements)
}

private func el(_ i: Int, label: String, value: String? = nil, focused: Bool = false) -> UIElement {
    UIElement(index: i, role: "AXButton", label: label, value: value,
              frame: CodableRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
              isEnabled: true, isVisible: true, isFocused: focused)
}

private func act(_ type: ActionType, text: String? = nil, targetIndex: Int? = nil) -> AgentAction {
    AgentAction(type: type, targetIndex: targetIndex, text: text,
                confidence: 0.9, requiresConfirmation: false, rationale: "t")
}

@Suite struct OutcomeVerifierTests {

    @Test func isVerifiable_coversInteractiveTypes_excludesNonUI() {
        #expect(OutcomeVerifier.isVerifiable(.click))
        #expect(OutcomeVerifier.isVerifiable(.typeText))
        #expect(OutcomeVerifier.isVerifiable(.switchApp))
        #expect(OutcomeVerifier.isVerifiable(.scroll))
        #expect(!OutcomeVerifier.isVerifiable(.wait))
        #expect(!OutcomeVerifier.isVerifiable(.say))
        #expect(!OutcomeVerifier.isVerifiable(.keyCombo))
        #expect(!OutcomeVerifier.isVerifiable(.complete))
    }

    @Test func click_noPerceptibleChange_marksUnverified() throws {
        // The H1 DoD case: a click that changes nothing on screen is flagged.
        let els = [el(0, label: "Button")]
        let pre = try snap(app: "com.x", elements: els)
        let post = try snap(app: "com.x", elements: els)
        let check = OutcomeVerifier.verify(action: act(.click, targetIndex: 0), pre: pre, post: post)
        #expect(check.verified == false)
    }

    @Test func click_screenChanged_verifies() throws {
        let pre = try snap(app: "com.x", elements: [el(0, label: "Button")])
        let post = try snap(app: "com.x", elements: [el(0, label: "Button"), el(1, label: "Dialog")])
        let check = OutcomeVerifier.verify(action: act(.click, targetIndex: 0), pre: pre, post: post)
        #expect(check.verified == true)
    }

    @Test func click_axBlindEitherSide_isUnknown() throws {
        let blank = try snap(app: "com.x", elements: [])
        let full = try snap(app: "com.x", elements: [el(0, label: "B")])
        #expect(OutcomeVerifier.verify(action: act(.click), pre: blank, post: blank).verified == nil)
        #expect(OutcomeVerifier.verify(action: act(.click), pre: full, post: blank).verified == nil)
        #expect(OutcomeVerifier.verify(action: act(.click), pre: blank, post: full).verified == nil)
    }

    @Test func switchApp_matchVerifies_mismatchFails() throws {
        let pre = try snap(app: "com.a", elements: [el(0, label: "x")])
        let matched = try snap(app: "com.b", elements: [el(0, label: "y")])
        let missed = try snap(app: "com.a", elements: [el(0, label: "x")])
        #expect(OutcomeVerifier.verify(action: act(.switchApp, text: "com.b"), pre: pre, post: matched).verified == true)
        #expect(OutcomeVerifier.verify(action: act(.switchApp, text: "com.b"), pre: pre, post: missed).verified == false)
        // Case-insensitive, matching the codebase's bundle-id normalization.
        let mixed = try snap(app: "com.apple.Notes", elements: [el(0, label: "y")])
        #expect(OutcomeVerifier.verify(action: act(.switchApp, text: "com.apple.notes"), pre: pre, post: mixed).verified == true)
    }

    @Test func switchApp_noTarget_isUnknown() throws {
        let pre = try snap(app: "com.a", elements: [])
        let post = try snap(app: "com.b", elements: [])
        #expect(OutcomeVerifier.verify(action: act(.switchApp, text: nil), pre: pre, post: post).verified == nil)
    }

    @Test func typeText_valuePresent_verifies_andDetailHidesText() throws {
        let pre = try snap(app: "com.x", elements: [el(0, label: "Field", value: "")])
        let post = try snap(app: "com.x", elements: [el(0, label: "Field", value: "hello world", focused: true)])
        let check = OutcomeVerifier.verify(action: act(.typeText, text: "hello world", targetIndex: 0), pre: pre, post: post)
        #expect(check.verified == true)
        #expect(!check.detail.contains("hello world"))
    }

    @Test func typeText_notFound_isUnknownNotFalse() throws {
        // Masked or AX-unexposed values must not read as a confident failure.
        let pre = try snap(app: "com.x", elements: [el(0, label: "Pwd", value: "")])
        let post = try snap(app: "com.x", elements: [el(0, label: "Pwd", value: "••••")])
        let check = OutcomeVerifier.verify(action: act(.typeText, text: "secret", targetIndex: 0), pre: pre, post: post)
        #expect(check.verified == nil)
    }

    @Test func nonVerifiableType_isUnknown() throws {
        let s = try snap(app: "com.x", elements: [el(0, label: "x")])
        #expect(OutcomeVerifier.verify(action: act(.wait), pre: s, post: s).verified == nil)
    }
}

@Suite struct OutcomeReportTests {

    private func entry(_ type: ActionType, verified: Bool?) -> ActionLogEntry {
        ActionLogEntry(
            action: AgentAction(type: type, confidence: 0.9, requiresConfirmation: false, rationale: "t"),
            tier: "auto", approved: true, executionResult: "ok", durationMs: 1, snapshotHash: "h",
            outcomeVerified: verified, outcomeDetail: verified == false ? "no-op" : nil)
    }

    @Test func report_countsVerifiedTriState() {
        let entries = [
            entry(.click, verified: true),
            entry(.click, verified: false),
            entry(.click, verified: nil),
            entry(.switchApp, verified: true),
        ]
        let r = ReceiptReplayFormatter.confidenceReport(entries)
        #expect(r.verified == 2)
        #expect(r.unverified == 1)
        #expect(r.verifyUnknown == 1)
    }

    @Test func report_renderShowsVerifiedSuccessRate() {
        let entries = [
            entry(.click, verified: true),
            entry(.click, verified: true),
            entry(.click, verified: false),
        ]
        let out = ReceiptReplayFormatter.renderConfidenceReport(
            ReceiptReplayFormatter.confidenceReport(entries), scope: "test")
        #expect(out.contains("verified success: 67% of 3 checked actions"))
    }

    @Test func actionLogEntry_preH1Receipt_decodesOutcomeAsNil() throws {
        // Append-only back-compat: a receipt written before H1 (no outcome
        // keys) must decode with nil outcome fields, not fail.
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":"2026-01-01T00:00:00Z",\
        "action":{"type":"click","confidence":0.9,"requiresConfirmation":false,"rationale":"x"},\
        "tier":"auto","approved":true,"executionResult":"ok","durationMs":1,"snapshotHash":"h"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(ActionLogEntry.self, from: Data(json.utf8))
        #expect(entry.outcomeVerified == nil)
        #expect(entry.outcomeDetail == nil)
    }
}
