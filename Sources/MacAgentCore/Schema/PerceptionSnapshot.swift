import CoreGraphics
import Foundation

public struct CodableRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CodableSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public static let zero = CodableSize(.zero)
}


public struct UIElement: Codable, Equatable, Sendable {
    public let index: Int
    public let role: String
    public let label: String
    public let value: String?
    public let frame: CodableRect
    public let isEnabled: Bool
    public let isVisible: Bool
    /// Unit 25 — true when this element holds keyboard focus at observe
    /// time, populated from the AX server's `kAXFocusedUIElementAttribute`
    /// on the focused app. At most one element per snapshot has this true.
    /// Init default is false so the 95 existing UIElement construction
    /// sites stay source-compatible; only the production AX walker and
    /// fixtures that explicitly model post-click focus need to set it.
    public let isFocused: Bool

    public init(
        index: Int,
        role: String,
        label: String,
        value: String?,
        frame: CodableRect,
        isEnabled: Bool,
        isVisible: Bool,
        isFocused: Bool = false
    ) {
        self.index = index
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.isFocused = isFocused
    }

    // Unit 25 — custom Codable so JSON written before this field existed
    // (snapshot sidecars in `~/Library/Application Support/MacAgent/snapshots/`)
    // still decodes cleanly. Missing `isFocused` key defaults to false.
    // Encode path is automatic (synthesized would also work, but explicit
    // matches the decode for symmetry and locks the JSON key name).
    private enum CodingKeys: String, CodingKey {
        case index, role, label, value, frame, isEnabled, isVisible, isFocused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try c.decode(Int.self, forKey: .index)
        self.role = try c.decode(String.self, forKey: .role)
        self.label = try c.decode(String.self, forKey: .label)
        self.value = try c.decodeIfPresent(String.self, forKey: .value)
        self.frame = try c.decode(CodableRect.self, forKey: .frame)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.isVisible = try c.decode(Bool.self, forKey: .isVisible)
        self.isFocused = try c.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(role, forKey: .role)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encode(frame, forKey: .frame)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(isVisible, forKey: .isVisible)
        try c.encode(isFocused, forKey: .isFocused)
    }
}

public struct VisionObservation: Codable, Equatable, Sendable {
    public let text: String
    public let boundingBox: CodableRect

    public init(text: String, boundingBox: CodableRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

public struct PerceptionSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let focusedAppBundleID: String
    public let elements: [UIElement]
    public let hash: String
    public let visionObservations: [VisionObservation]
    /// True when Vision fell back to capturing the full display rather than
    /// the frontmost app's windows only. The LLM should be informed so it
    /// can discount text observed outside the target app.
    public let visionUsedFullScreenFallback: Bool
    /// True when the UI had more elements than the 300-element cap and the
    /// list was truncated. The LLM should prefer menuSelect or keyCombo for
    /// targets that may not appear in the snapshot.
    public let elementListTruncated: Bool
    /// The first targetIndex the LLM should use for vision elements.
    /// Equals min(elements.count, 80) — the number of AX lines shown in the prompt.
    /// Single source of truth consumed by both LLMClient (prompt) and Executor (dispatch).
    /// Defaults to elements.count so callers that don't pass vision observations get a
    /// safe boundary (no vision indices available).
    public let visionIndexOffset: Int
    /// Screen-point origin of the top-left corner of the captured region.
    /// .zero for full-screen fallback. Window union rect origin for app-scoped captures.
    /// Used by Executor to convert vision pixel coordinates to screen points.
    public let captureOrigin: CodablePoint
    /// PNG screenshot at logical resolution. Populated by ComputerUseClient for visual
    /// context; nil in standard AX-only mode. Excluded from the snapshot hash so that
    /// identical UI states always produce the same hash regardless of screenshot content.
    public let screenshotPNG: Data?
    /// Logical (point) size of the screen at the moment `screenshotPNG` was captured.
    /// nil when no screenshot is attached. Used by ComputerUseClient to map Anthropic
    /// pixel coords back to logical screen points without depending on the live
    /// NSScreen.main — display geometry can shift between capture and send (monitor
    /// switch, resolution change, scaling toggle). Excluded from the snapshot hash
    /// for the same reason `screenshotPNG` is — pure UI state shouldn't perturb hash
    /// stability across hardware reconfigs.
    public let screenshotLogicalSize: CodableSize?
    /// Unit 9 — true when AXPerception's defaultWalker fell back to walking
    /// a non-frontmost app's AX tree because the agent itself was frontmost
    /// at observe-time (see AXPerception.resolveTargetApp). The fallback
    /// snapshot reports `focusedAppBundleID = <fallback app>` (e.g.
    /// "com.apple.notes") but the actual macOS frontmost is still the
    /// agent overlay — so CGEvent clicks at the snapshot's coords would
    /// hit the agent UI, not the fallback app. The LLM prompt warns when
    /// this flag is true and instructs the model to dispatch switchApp
    /// before any click. Excluded from the snapshot hash so that whether
    /// a step happens via fallback or direct walk doesn't perturb hash
    /// stability across iterations.
    public let agentIsOverlaid: Bool

    public init(
        timestamp: Date,
        focusedAppBundleID: String,
        elements: [UIElement],
        hash: String,
        visionObservations: [VisionObservation] = [],
        visionUsedFullScreenFallback: Bool = false,
        elementListTruncated: Bool = false,
        visionIndexOffset: Int = 0,
        captureOrigin: CodablePoint = .zero,
        screenshotPNG: Data? = nil,
        screenshotLogicalSize: CodableSize? = nil,
        agentIsOverlaid: Bool = false
    ) {
        self.timestamp = timestamp
        self.focusedAppBundleID = focusedAppBundleID
        self.elements = elements
        self.hash = hash
        self.visionObservations = visionObservations
        self.visionUsedFullScreenFallback = visionUsedFullScreenFallback
        self.elementListTruncated = elementListTruncated
        self.visionIndexOffset = visionIndexOffset
        self.captureOrigin = captureOrigin
        self.screenshotPNG = screenshotPNG
        self.screenshotLogicalSize = screenshotLogicalSize
        self.agentIsOverlaid = agentIsOverlaid
    }

    public static func make(
        timestamp: Date,
        focusedAppBundleID: String,
        elements: [UIElement],
        visionObservations: [VisionObservation] = [],
        visionUsedFullScreenFallback: Bool = false,
        elementListTruncated: Bool = false,
        captureOrigin: CGPoint = .zero,
        screenshotPNG: Data? = nil,
        screenshotLogicalSize: CodableSize? = nil,
        agentIsOverlaid: Bool = false
    ) throws -> PerceptionSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // sortedKeys ensures the hash is deterministic regardless of dictionary or
        // struct field ordering across Swift/Foundation versions.
        encoder.outputFormatting = [.sortedKeys]
        // visionIndexOffset = number of AX lines the LLM will see (capped at 80).
        // This is the boundary between AX and vision indices in both the prompt and Executor.
        let visionIndexOffset = min(elements.count, 80)
        let codableOrigin = CodablePoint(captureOrigin)
        let payload = SnapshotHashPayload(
            timestamp: timestamp,
            focusedAppBundleID: focusedAppBundleID,
            elements: elements,
            visionObservations: visionObservations,
            visionIndexOffset: visionIndexOffset,
            captureOrigin: codableOrigin
        )
        let data = try encoder.encode(payload)
        return PerceptionSnapshot(
            timestamp: timestamp,
            focusedAppBundleID: focusedAppBundleID,
            elements: elements,
            hash: Hashing.sha256Hex(data),
            visionObservations: visionObservations,
            visionUsedFullScreenFallback: visionUsedFullScreenFallback,
            elementListTruncated: elementListTruncated,
            visionIndexOffset: visionIndexOffset,
            captureOrigin: codableOrigin,
            screenshotPNG: screenshotPNG,                  // excluded from hash — see SnapshotHashPayload
            screenshotLogicalSize: screenshotLogicalSize,  // also excluded — hardware geometry, not UI state
            agentIsOverlaid: agentIsOverlaid               // also excluded — diagnostic flag, not UI state
        )
    }
}

private struct SnapshotHashPayload: Codable {
    let timestamp: Date
    let focusedAppBundleID: String
    let elements: [UIElement]
    let visionObservations: [VisionObservation]
    let visionIndexOffset: Int
    let captureOrigin: CodablePoint
}
