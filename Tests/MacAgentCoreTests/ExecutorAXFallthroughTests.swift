import ApplicationServices
import Foundation
@testable import MacAgentCore
import Testing

// `Executor.axPressFallthroughSafe(code:)` decides whether a failed
// `AXUIElementPerformAction(_, kAXPressAction)` is safe to recover from with
// a CGEvent click at the element's last-known frame. The decision splits the
// AXError space into two classes:
//
//   - element exists, press isn't supported (actionUnsupported, noValue,
//     attributeUnsupported): CGEvent fallthrough OK, frame is valid coords
//   - element is stale or unknown state (cannotComplete, invalidUIElement,
//     failure, notImplemented, etc.): refuse fallthrough — CGEvent at the
//     last-known frame might hit reflowed UI
//
// PR-3 originally gated `.attributeUnsupported` on `snapshotAge < 200ms` as
// defense against a hypothetical future macOS semantic shift. Live 2026-05-25
// production use showed the gate never fired the fallthrough because the
// snapshot is captured at observe(), think() then takes 2-5s, and act()
// reads `snapshot.timestamp` only AFTER think — so the gate always rejected.
// D8 dropped the gate; `.attributeUnsupported` falls through unconditionally
// just like `.actionUnsupported`.

@Test
func axPressFallthrough_allowsActionUnsupported() {
    #expect(Executor.axPressFallthroughSafe(code: .actionUnsupported))
}

@Test
func axPressFallthrough_allowsNoValue() {
    #expect(Executor.axPressFallthroughSafe(code: .noValue))
}

@Test
func axPressFallthrough_allowsAttributeUnsupported() {
    // -25205. Empirically equivalent to -25208 (.actionUnsupported) for
    // PerformAction. The pre-D8 design wrongly gated this on snapshot age.
    #expect(Executor.axPressFallthroughSafe(code: .attributeUnsupported))
}

@Test
func axPressFallthrough_refusesStaleHandleCodes() {
    // -25204 / -25202 / -25200 / -25201 all indicate stale or unknown state.
    // A CGEvent click at the last-known frame could land on a reflowed UI
    // element. Refuse fallthrough.
    #expect(!Executor.axPressFallthroughSafe(code: .cannotComplete))
    #expect(!Executor.axPressFallthroughSafe(code: .invalidUIElement))
    #expect(!Executor.axPressFallthroughSafe(code: .failure))
    #expect(!Executor.axPressFallthroughSafe(code: .notImplemented))
}

@Test
func axPressFallthrough_refusesSuccess() {
    // .success means the press WORKED — caller should already have returned;
    // it's a logic error to ever ask this predicate about success. Predicate
    // still falls through correctly: success is not in the safe-set, so
    // returns false, callers never throw because they check `result == .success`
    // before consulting the predicate.
    #expect(!Executor.axPressFallthroughSafe(code: .success))
}
