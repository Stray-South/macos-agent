import Testing
@testable import MacOSAgentV0

// Unit 28 — voice-reachable hotkey decode.
//
// The NSEvent monitor install itself needs a real HID tap (untestable in a
// unit test), but the keyCode → HotkeyIntent decode is the load-bearing
// logic and is a pure function. These tests pin the F13/F14/F15 bindings so
// a future keycode edit fails loud, and confirm unrelated keys never
// trigger an approve/reject/abort.

@Test
func hotkeyDecode_mapsF13ToApprove() {
    #expect(GlobalHotkeyMonitor.intent(forKeyCode: 105) == .approve,
            "F13 (keyCode 105) must decode to .approve")
}

@Test
func hotkeyDecode_mapsF14ToReject() {
    #expect(GlobalHotkeyMonitor.intent(forKeyCode: 107) == .reject,
            "F14 (keyCode 107) must decode to .reject")
}

@Test
func hotkeyDecode_mapsF15ToAbort() {
    #expect(GlobalHotkeyMonitor.intent(forKeyCode: 113) == .abort,
            "F15 (keyCode 113) must decode to .abort")
}

@Test
func hotkeyDecode_returnsNilForUnboundKeys() {
    // A spread of common keys that must NEVER trigger a gate decision:
    // Return(36), Escape(53), Space(49), 'A'(0), F1(122), F12(111).
    for keyCode in [UInt16(36), 53, 49, 0, 122, 111] {
        #expect(GlobalHotkeyMonitor.intent(forKeyCode: keyCode) == nil,
                "keyCode \(keyCode) must not decode to any hotkey intent")
    }
}

@Test
func hotkeyBindings_coverAllThreeIntentsForSettingsDisplay() {
    let keys = GlobalHotkeyMonitor.bindingDescriptions
    #expect(keys.count == 3, "Settings must list exactly the three bindings")
    #expect(keys.map(\.intent) == ["Approve", "Reject", "Abort"],
            "binding order must match gate-decision severity for the Settings list")
    #expect(keys.map(\.key) == ["F13", "F14", "F15"],
            "displayed keys must match the decode mapping")
}

// Unit 28a — the cross-app global brake must be gated on the Accessibility
// grant. `globalActive` reflects whether the global tap is installed; the
// NSEvent install itself can't be asserted in a unit test, but the gating
// decision (install global only when includeGlobal) is the load-bearing
// fix for the reviewer's "silently-dead emergency brake" risk.
@MainActor
@Test
func hotkeyMonitor_globalTapGatedOnIncludeGlobalFlag() {
    let monitor = GlobalHotkeyMonitor()
    #expect(monitor.globalActive == false, "fresh monitor has no global tap")

    // includeGlobal:false → cross-app brake NOT armed (the no-Accessibility case).
    monitor.start(includeGlobal: false) { _ in }
    #expect(monitor.globalActive == false,
            "start(includeGlobal: false) must NOT arm the cross-app global tap")

    // includeGlobal:true → attempts the global install (token presence
    // depends on the test process's TCC state; assert it doesn't crash and
    // that stop() clears the flag deterministically either way).
    monitor.start(includeGlobal: true) { _ in }
    monitor.stop()
    #expect(monitor.globalActive == false, "stop() clears globalActive")
}
