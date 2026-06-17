import Testing
import CoreGraphics
@testable import MacAgentCore

// G1 — the executor's pure geometry/parse logic, formerly trapped inside
// display-bound methods (no behavioral coverage). A wrong descale would only
// have surfaced as a misplaced live click; these pin it.
@Suite struct ExecutorPureMathTests {

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CodableRect {
        CodableRect(CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func scale1_originZero_centreIsBoxCentre() {
        let (pt, rect) = Executor.visionBoxToScreen(
            box: box(100, 200, 40, 20), captureOrigin: .zero, scale: 1)
        #expect(pt == CGPoint(x: 120, y: 210))
        #expect(rect == CGRect(x: 100, y: 200, width: 40, height: 20))
    }

    @Test func scale2_retina_halvesPixels() {
        // A 2x display: 200px vision coord → 100pt screen.
        let (pt, rect) = Executor.visionBoxToScreen(
            box: box(200, 400, 80, 40), captureOrigin: .zero, scale: 2)
        #expect(rect == CGRect(x: 100, y: 200, width: 40, height: 20))
        #expect(pt == CGPoint(x: 120, y: 210))
    }

    @Test func scale3_thirdsPixels() {
        let (pt, _) = Executor.visionBoxToScreen(
            box: box(300, 0, 60, 0), captureOrigin: .zero, scale: 3)
        #expect(pt == CGPoint(x: 110, y: 0))  // 300/3=100 + (60/3)/2=10
    }

    @Test func nonZeroCaptureOrigin_offsetsAfterDescale() {
        // App-scoped capture: box is relative to the window-union origin.
        let (pt, rect) = Executor.visionBoxToScreen(
            box: box(40, 20, 20, 10), captureOrigin: CGPoint(x: 500, y: 300), scale: 2)
        // 40/2=20 +500 = 520 ; 20/2=10 +300 = 310 ; centre +(10/2, 5/2)
        #expect(rect == CGRect(x: 520, y: 310, width: 10, height: 5))
        #expect(pt == CGPoint(x: 525, y: 312.5))
    }

    @Test func zeroScale_treatedAsOne_noDivideByZero() {
        let (pt, _) = Executor.visionBoxToScreen(
            box: box(10, 10, 4, 4), captureOrigin: .zero, scale: 0)
        #expect(pt == CGPoint(x: 12, y: 12))
    }

    @Test func modifierFlags_parsesEachToken() {
        #expect(Executor.modifierFlags(for: ["cmd"]).contains(.maskCommand))
        #expect(Executor.modifierFlags(for: ["command"]).contains(.maskCommand))
        #expect(Executor.modifierFlags(for: ["shift"]).contains(.maskShift))
        #expect(Executor.modifierFlags(for: ["ctrl"]).contains(.maskControl))
        #expect(Executor.modifierFlags(for: ["control"]).contains(.maskControl))
        #expect(Executor.modifierFlags(for: ["option"]).contains(.maskAlternate))
        #expect(Executor.modifierFlags(for: ["alt"]).contains(.maskAlternate))
        #expect(Executor.modifierFlags(for: ["fn"]).contains(.maskSecondaryFn))
    }

    @Test func modifierFlags_combinesAndIgnoresKeyToken() {
        let flags = Executor.modifierFlags(for: ["cmd", "shift", "a"])
        #expect(flags.contains(.maskCommand) && flags.contains(.maskShift))
        // "a" is the key, not a modifier — must not set a flag.
        #expect(!flags.contains(.maskControl) && !flags.contains(.maskAlternate))
    }

    @Test func modifierFlags_emptyIsNoFlags() {
        #expect(Executor.modifierFlags(for: []) == CGEventFlags())
    }
}
