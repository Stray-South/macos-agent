/// ComputerUseCoordRoundTripTests.swift
///
/// Integration coverage for the CU coordinate pipeline:
///   Anthropic-coord (in sent-image space)
///     → `descaleClickCoord` (per stored sent/logical sizes)
///       → `nearestElement` (in logical screen-points space)
///         → AgentAction.coordinate (logical screen-points, stored on the action)
///
/// Pure-math `ScreenScalerTests` cover the descale function in isolation;
/// this file catches a `lastSentImageSize` ↔ `lastLogicalSize` swap that the
/// isolation tests wouldn't see. ScreenCaptureKit is bypassed entirely via the
/// `setScaleStateForTesting` seed.
import CoreGraphics
@testable import MacAgentCore
import Testing

@Test
func cuCoord_descalesFromSentSpaceToLogicalSpace_endToEnd() async throws {
    // Sonnet 4.6 path: requiresScaling == true, sent < logical, descale must run.
    let client = ComputerUseClient(apiKey: "test", model: "claude-sonnet-4-6")
    await client.setScaleStateForTesting(
        sent: CGSize(width: 1568, height: 980),
        logical: CGSize(width: 3024, height: 1890)
    )
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.test",
        elements: [
            // Element centered near where (784, 490) descales to: (1512, 945).
            UIElement(index: 0, role: "AXButton", label: "Btn",
                      value: nil,
                      frame: CodableRect(.init(x: 1500, y: 935, width: 24, height: 24)),
                      isEnabled: true, isVisible: true),
        ]
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("left_click"),
        "coordinate": AnyCodable([784, 490] as [Any]),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .click)
    let p = action.coordinate?.cgPoint
    #expect(p != nil, "expected coordinate to be set on the AgentAction")
    // 784 * (3024/1568) = 1512; 490 * (1890/980) = 945. ±1 px tolerates float drift.
    #expect(abs((p?.x ?? 0) - 1512) <= 1,
            "x must descale 784 → 1512; got \(p?.x ?? .nan)")
    #expect(abs((p?.y ?? 0) - 945) <= 1,
            "y must descale 490 → 945; got \(p?.y ?? .nan)")
    // The AX-element matching consumes the descaled (logical) coord and sees
    // an element at (1512, 947) center, distance ~2pt → returns index 0.
    #expect(action.targetIndex == 0,
            "nearestElement must run AFTER descale — AX frames are in logical points")
}

@Test
func cuCursorPosition_seedsPendingToolResultAndReturnsWait() async throws {
    // cursor_position is a READ action — Claude asks where the cursor is.
    // The translator stores the answer in pendingToolResultText for the next
    // tool_result content block and returns a .wait so the loop advances.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("cursor_position"),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .wait,
            "cursor_position is a read; emits .wait to advance the loop")
    let pending = await client.pendingToolResultTextForTesting
    #expect(pending != nil)
    #expect(pending?.contains("cursor_position:") == true,
            "pending tool_result text must contain the cursor_position answer; got \(pending ?? "nil")")
}

@Test
func cuCoord_opus47NoScaling_passesCoordThrough() async throws {
    // Opus 4.7 path: requiresScaling == false, sent == logical, descale is no-op.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    await client.setScaleStateForTesting(
        sent: CGSize(width: 1440, height: 900),
        logical: CGSize(width: 1440, height: 900)
    )
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.test",
        elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("left_click"),
        "coordinate": AnyCodable([300, 200] as [Any]),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.coordinate?.cgPoint == CGPoint(x: 300, y: 200),
            "Opus 4.7 path must pass coord through unchanged")
}
