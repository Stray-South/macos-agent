import AppKit
import ApplicationServices
import Foundation

public protocol AXPerceiving: Sendable {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot
}

public struct RawAXElement: Equatable, Sendable {
    public let role: String
    public let label: String
    public let value: String?
    public let frame: CodableRect
    public let isEnabled: Bool
    public let isVisible: Bool
    public let depth: Int
    /// Walker-assigned ordinal — the key under which the live AXUIElement was
    /// stored in `walked.lookup`. Used by `AXPerception.capture` to rebuild the
    /// per-snapshot lookup after pruning so `Executor.resolveTarget` can map a
    /// post-prune `targetIndex` back to the correct AX element. Default 0 keeps
    /// test fixtures that don't exercise the lookup path source-compatible.
    public let walkerIndex: Int
    /// Unit 25 — true when this element is the focused AXUIElement at walk
    /// time. Populated by `walk` via `CFEqual` against the value returned by
    /// `kAXFocusedUIElementAttribute` on the app element. At most one walked
    /// element per snapshot has this true; all others false. When the focus
    /// query returns nothing (rare, e.g. between windows), every element is
    /// false. Default false keeps test fixtures that don't exercise the focus
    /// path source-compatible.
    public let isFocused: Bool

    public init(
        role: String,
        label: String,
        value: String?,
        frame: CodableRect,
        isEnabled: Bool,
        isVisible: Bool,
        depth: Int,
        walkerIndex: Int = 0,
        isFocused: Bool = false
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.depth = depth
        self.walkerIndex = walkerIndex
        self.isFocused = isFocused
    }
}

// @unchecked Sendable is safe: `storage` is immutable (let) after init and is only
// accessed read-only via element(at:). AXUIElement is not Sendable, but the class
// never mutates state or shares mutable references across threads.
public final class AXElementLookup: @unchecked Sendable {
    private let storage: [Int: AXUIElement]

    public init(storage: [Int: AXUIElement]) {
        self.storage = storage
    }

    public func element(at index: Int) -> AXUIElement? {
        storage[index]
    }
}

public struct ObservedSnapshot: Sendable {
    public let snapshot: PerceptionSnapshot
    public let lookup: AXElementLookup

    public init(snapshot: PerceptionSnapshot, lookup: AXElementLookup = AXElementLookup(storage: [:])) {
        self.snapshot = snapshot
        self.lookup = lookup
    }
}

public enum AXPerceptionError: Error, LocalizedError, Sendable {
    case noFrontmostApp
    case snapshotCreationFailed
    case permissionsRevoked
    /// Frontmost app is the agent itself. Walking the agent's own AX tree
    /// produces a snapshot of the launcher window — the LLM then anchors
    /// CU pixel clicks against agent UI elements, AX press succeeds on
    /// the agent's own buttons / static text, and the intended target app
    /// (Notes, Safari, etc.) never receives the action. See AXPerception
    /// §H3 (root cause), Sources/MacAgentCore/Perception/AXPerception.swift.
    case agentIsFrontmost(bundleID: String)

    public var errorDescription: String? {
        switch self {
        case .noFrontmostApp:
            return "No frontmost application is available for Accessibility capture."
        case .snapshotCreationFailed:
            return "Failed to build an Accessibility snapshot."
        case .permissionsRevoked:
            return "Accessibility permission was revoked. Re-grant it in System Settings > Privacy & Security > Accessibility."
        case .agentIsFrontmost(let bundleID):
            // Bundle ID stays in parens for diagnostic value. The message
            // covers both Unit 8 reachability paths:
            //   (a) cold start — operator launched the agent and submitted
            //       without activating any other app first.
            //   (b) tracked app quit between observe and walker — fallback
            //       PID went stale; we lost the target.
            // Either way the actionable instruction is the same: activate
            // a target app, then re-submit. "Activate" reads better than
            // "bring to the front" for cold-start (there might be nothing
            // visible to bring forward — operator needs to LAUNCH something).
            return "macOS Agent v0 is the frontmost app and no other app is currently tracked (\(bundleID)). Activate the app you want me to act on (Notes, Safari, etc.), then re-submit the task."
        }
    }
}

/// Lightweight tuple of macOS app identity fields used by `AXPerception
/// .defaultWalker` and the testable `resolveTargetApp` helper. `internal`
/// so tests can construct fakes directly without needing a real
/// `NSRunningApplication` (no public initializer there).
internal struct AppInfo: Sendable {
    let pid: pid_t
    let bundleID: String?
    let localizedName: String?
}

public actor AXPerception: AXPerceiving {
    /// Walker return contract.
    /// - `bundleID` / `raw` / `lookup`: AX walk output (same as pre-Unit-9).
    /// - `agentIsOverlaid`: Unit 9 — true when the walk operated on a
    ///   *fallback* app's AX tree because the agent itself was frontmost
    ///   (defaultWalker only). Custom walkers in tests can pass `false`
    ///   unless they want to exercise the LLM-prompt-warning path.
    public typealias Walker = @Sendable () async throws -> (bundleID: String, raw: [RawAXElement], lookup: [Int: AXUIElement], agentIsOverlaid: Bool)
    /// Unit 8 — provider closure that returns the PID of the most recent
    /// non-agent app to be frontmost. When the operator submits a task via
    /// the launcher, the agent itself is frontmost; without this fallback,
    /// `defaultWalker` would throw `agentIsFrontmost` and the operator
    /// would have no recovery path. With it, `defaultWalker` walks the
    /// fallback app's AX tree instead — the LLM sees "Notes is focused"
    /// (or whatever the operator was using) and proceeds normally.
    /// Async because AppModel reads its `lastNonAgentActivePID` on the
    /// MainActor; the closure hops there.
    public typealias FallbackFrontmostProvider = @Sendable () async -> pid_t?

    private let walker: Walker
    private var cached: ObservedSnapshot?
    private var cachedAt: Date?

    public init(
        walker: Walker? = nil,
        fallbackFrontmostProvider: FallbackFrontmostProvider? = nil
    ) {
        if let walker {
            // Custom walker (tests). Fallback provider is ignored — tests
            // that want to exercise the fallback path do so by configuring
            // their custom walker's behavior directly.
            self.walker = walker
        } else {
            // Production walker: bind the fallback provider into a closure
            // that defaultWalker can consume. Captured by reference so a
            // later AppModel reset (lastNonAgentActivePID changes) is
            // visible on the next observe.
            self.walker = {
                try await AXPerception.defaultWalker(
                    fallbackFrontmostProvider: fallbackFrontmostProvider
                )
            }
        }
    }

    public func capture(forceRefresh: Bool = false) async throws -> ObservedSnapshot {
        let now = Date()
        if !forceRefresh, let cached, let cachedAt, now.timeIntervalSince(cachedAt) <= 0.2 {
            return cached
        }

        let walked = try await walker()
        // pruneWithWalkerIndices returns the walker-counter for each surviving
        // post-prune element so we can rebuild the lookup keyed by the
        // POST-PRUNE index. Pre-fix: lookup was keyed by walker counter while
        // Executor.resolveTarget queried it with the post-prune index — any
        // pruned earlier element shifted indices and silently dispatched a
        // click to the wrong live AXUIElement.
        let (elements, walkerIndices, truncated) = Self.pruneWithWalkerIndices(rawElements: walked.raw)
        let snapshot = try PerceptionSnapshot.make(
            timestamp: now,
            focusedAppBundleID: walked.bundleID,
            elements: elements,
            elementListTruncated: truncated,
            agentIsOverlaid: walked.agentIsOverlaid
        )
        var rebuilt: [Int: AXUIElement] = [:]
        for (postPruneIndex, walkerIdx) in walkerIndices.enumerated() {
            if let ax = walked.lookup[walkerIdx] {
                rebuilt[postPruneIndex] = ax
            }
        }
        let lookup = AXElementLookup(storage: rebuilt)
        let observed = ObservedSnapshot(snapshot: snapshot, lookup: lookup)
        cached = observed
        cachedAt = now
        return observed
    }

    /// Returns the pruned element list and a flag indicating whether it was truncated.
    /// Public API kept stable across the Cluster E lookup-rebuild fix — delegates
    /// to `pruneWithWalkerIndices` and discards the walker-index column.
    public static func prune(rawElements: [RawAXElement]) -> (elements: [UIElement], truncated: Bool) {
        let (elements, _, truncated) = pruneWithWalkerIndices(rawElements: rawElements)
        return (elements, truncated)
    }

    /// Unit 5 / H3 guard: is the given PID this process? Extracted so tests can
    /// exercise the comparison logic deterministically without the `defaultWalker`
    /// path (which requires a real macOS frontmost app + AX permission).
    /// The `agentPID` parameter is injectable for testing; production callers
    /// rely on the shared `agentProcessID` constant (Support/AgentIdentity.swift)
    /// so AX and CU/Vision identity sources cannot diverge.
    internal static func isAgentProcess(
        _ pid: pid_t,
        agentPID: pid_t = agentProcessID
    ) -> Bool {
        pid == agentPID
    }

    /// Internal variant of `prune` that also returns each surviving element's
    /// original walker-counter index. `AXPerception.capture` uses this to rebuild
    /// `AXElementLookup` keyed by post-prune index so `Executor.resolveTarget`
    /// (which calls `lookup.element(at: snapshot.elements[i].index)`) resolves
    /// to the correct live AXUIElement after pruning shifts indices.
    internal static func pruneWithWalkerIndices(
        rawElements: [RawAXElement]
    ) -> (elements: [UIElement], walkerIndices: [Int], truncated: Bool) {
        let roleFiltered = rawElements.filter { element in
            let disallowedRoles = ["AXUnknown", "AXGroup", "AXSplitter", "AXScrollArea"]
            if !disallowedRoles.contains(element.role) {
                return true
            }
            return !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let visible = roleFiltered.filter { element in
            element.frame.width > 0 && element.frame.height > 0 && element.isVisible && element.depth <= 15
        }

        let collapsedSource: [RawAXElement]
        if visible.count > 300 {
            collapsedSource = visible.filter { $0.isEnabled || (($0.value?.isEmpty) == false) }
        } else {
            collapsedSource = visible
        }

        let capped = Array(collapsedSource.prefix(300))
        let truncated = collapsedSource.count > 300
        let walkerIndices = capped.map { $0.walkerIndex }
        let elements = capped.enumerated().map { index, element in
            UIElement(
                index: index,
                role: element.role,
                label: element.label,
                value: element.value,
                frame: element.frame,
                isEnabled: element.isEnabled,
                isVisible: element.isVisible,
                isFocused: element.isFocused
            )
        }
        return (elements, walkerIndices, truncated)
    }

    /// Unit 8/10 — testable resolver for "which app's AX tree should `defaultWalker`
    /// actually walk?" Pulled out of `defaultWalker` so tests can exercise the
    /// agent-frontmost branch with mocked fallback resolution (no real AX, no
    /// real NSRunningApplication). `internal` so `@testable import MacAgentCore`
    /// can call it.
    ///
    /// Resolution order:
    ///   1. If `frontmost` is NOT the agent → return frontmost as-is (normal path).
    ///   2. Agent IS frontmost AND `fallbackProvider` returns a live PID →
    ///      return the fallback AppInfo (Unit 8: walk the operator's previous app).
    ///   3. Agent IS frontmost AND fallback unavailable (cold start: no
    ///      activation event yet, OR fallback returned a stale PID) → return
    ///      `frontmost` (the agent's own info). The walker walks our own tree;
    ///      `agentIsOverlaid` is set true in the snapshot; the LLM prompt's
    ///      cold-start directive (Unit 10) tells the model to dispatch
    ///      `switchApp(text=<target>)` as its first action.
    ///
    /// Never returns nil. Unit 10 eliminated the throw path so the LLM is
    /// always called even on cold-start — matching Anthropic's reference
    /// computer-use loop, which trusts the system prompt to drive the
    /// first action rather than gating on a pre-LLM observation.
    internal static func resolveTargetApp(
        frontmost: AppInfo,
        fallbackProvider: FallbackFrontmostProvider?,
        resolveFallback: @Sendable (pid_t) async -> AppInfo? = AXPerception.productionResolveFallback
    ) async -> AppInfo {
        if !Self.isAgentProcess(frontmost.pid) {
            return frontmost
        }
        if let fallbackPID = await fallbackProvider?(),
           let fallbackInfo = await resolveFallback(fallbackPID) {
            return fallbackInfo
        }
        // Cold start — walk the agent's own tree. agentIsOverlaid will be true
        // (set in defaultWalker via isAgentProcess(info.pid)) and the LLM
        // prompt's cold-start directive will direct the model to switchApp.
        return frontmost
    }

    /// Production fallback-PID → AppInfo resolver. Reads NSRunningApplication
    /// on the MainActor (the AppKit class requires it under Swift 6 strict
    /// concurrency). Returns nil if the PID's app has terminated.
    internal static let productionResolveFallback: @Sendable (pid_t) async -> AppInfo? = { pid in
        await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else { return nil }
            return AppInfo(pid: pid, bundleID: app.bundleIdentifier, localizedName: app.localizedName)
        }
    }

    private static func defaultWalker(
        fallbackFrontmostProvider: FallbackFrontmostProvider? = nil
    ) async throws -> (bundleID: String, raw: [RawAXElement], lookup: [Int: AXUIElement], agentIsOverlaid: Bool) {
        // Check AX permission here (not in Orchestrator) so mock walkers in tests bypass it,
        // avoiding a crash inside HIServices when there is no NSApplication context.
        guard AXIsProcessTrustedWithOptions([:] as CFDictionary) else {
            throw AXPerceptionError.permissionsRevoked
        }
        // NSWorkspace.shared.frontmostApplication is @MainActor-isolated; hop
        // and snapshot the (pid, bundleID, name) tuple in one round-trip.
        let appInfo: AppInfo? = await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return AppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier, localizedName: app.localizedName)
        }
        guard let frontmost = appInfo else {
            throw AXPerceptionError.noFrontmostApp
        }

        // Unit 5/8/10 — when the agent is frontmost (typical at task
        // submission: the operator was just typing in the launcher), the
        // resolver picks the best target tree to walk:
        //   Unit 8: if AppModel tracked a "last non-agent frontmost" PID,
        //           walk that app's tree (operator's previous app).
        //   Unit 10: if no fallback is available (cold start — first task
        //           after launch, no activation events yet), walk the
        //           agent's own tree. agentIsOverlaid is set true and the
        //           LLM prompt's cold-start directive tells the model to
        //           dispatch switchApp as the first action.
        // resolveTargetApp never returns nil after Unit 10 — the cold-
        // start throw was eliminated to match Anthropic's reference
        // computer-use loop (let the system prompt drive the first action).
        let info = await Self.resolveTargetApp(
            frontmost: frontmost,
            fallbackProvider: fallbackFrontmostProvider
        )

        // Unit 9/10 — agentIsOverlaid is true in two cases:
        //   1. Cold start: info IS the agent's own process (walker walked
        //      its own tree because no fallback was available)
        //   2. Fallback fired: info is the fallback app's PID, but the
        //      agent overlay is still visually in front of it
        // Both cases mean "CGEvent clicks at the snapshot's coords would
        // hit the agent overlay" — the LLM prompt warns either way.
        let agentIsOverlaid = Self.isAgentProcess(info.pid) || info.pid != frontmost.pid

        let appElement = AXUIElementCreateApplication(info.pid)
        let windows = attributeArray(kAXWindowsAttribute as CFString, on: appElement)
        let roots = windows?.isEmpty == false ? windows! : [appElement]

        // Unit 25 — single app-level query for the focused element.
        // One IPC against the AX server, used to mark the matching walked
        // element with isFocused=true. Failure here (no focus, sandboxed
        // app, etc.) degrades gracefully: every element gets false, which
        // is what the agent saw before this unit.
        let focusedRef = attributeAXElement(kAXFocusedUIElementAttribute as CFString, on: appElement)

        var raw: [RawAXElement] = []
        var lookup: [Int: AXUIElement] = [:]
        var counter = 0
        for root in roots {
            walk(element: root, depth: 0, counter: &counter, raw: &raw, lookup: &lookup, focusedRef: focusedRef)
        }

        return (info.bundleID ?? info.localizedName ?? "unknown.app", raw, lookup, agentIsOverlaid)
    }

    private static func walk(
        element: AXUIElement,
        depth: Int,
        counter: inout Int,
        raw: inout [RawAXElement],
        lookup: inout [Int: AXUIElement],
        focusedRef: AXUIElement?
    ) {
        guard depth <= 15 else { return }

        let role = attributeString(kAXRoleAttribute as CFString, on: element) ?? "AXUnknown"
        let title = attributeString(kAXTitleAttribute as CFString, on: element)
        let description = attributeString(kAXDescriptionAttribute as CFString, on: element)
        let label = title ?? description ?? ""
        let value = attributeString(kAXValueAttribute as CFString, on: element)
        let frame = attributeFrame(on: element) ?? .zero
        let isEnabled = attributeBool(kAXEnabledAttribute as CFString, on: element) ?? true
        let isHidden = attributeBool(kAXHiddenAttribute as CFString, on: element) ?? false
        let isFocused: Bool
        if let focusedRef {
            isFocused = CFEqual(element, focusedRef)
        } else {
            isFocused = false
        }

        raw.append(
            RawAXElement(
                role: role,
                label: label,
                value: value,
                frame: CodableRect(frame),
                isEnabled: isEnabled,
                isVisible: !isHidden,
                depth: depth,
                walkerIndex: counter,
                isFocused: isFocused
            )
        )
        lookup[counter] = element
        counter += 1

        for child in attributeArray(kAXChildrenAttribute as CFString, on: element) ?? [] {
            walk(element: child, depth: depth + 1, counter: &counter, raw: &raw, lookup: &lookup, focusedRef: focusedRef)
        }
    }
}

private func attributeString(_ attribute: CFString, on element: AXUIElement) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let value else { return nil }
    return value as? String
}

private func attributeBool(_ attribute: CFString, on element: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let number = value as? NSNumber else { return nil }
    return number.boolValue
}

private func attributeArray(_ attribute: CFString, on element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let array = value as? [AXUIElement] else { return nil }
    return array
}

/// Unit 25 — query a single AXUIElement-valued attribute (e.g. the app-level
/// `kAXFocusedUIElementAttribute`). Returns nil on any failure; callers
/// treat nil as "attribute not available" and degrade gracefully. The
/// CFTypeRef → AXUIElement bridge mirrors AppModel.verifyNotesGoldenPath
/// (AppModel.swift:727). The CFGetTypeID guard ensures we only cast when
/// the AX server actually returned an AXUIElement; without it a malformed
/// response would crash on the unsafeDowncast.
private func attributeAXElement(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
}

private func attributeFrame(on element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
    let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
    guard positionResult == .success, sizeResult == .success,
          let positionValue,
          let sizeValue,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        return nil
    }
    let positionAX = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
    let sizeAX = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)

    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(positionAX) == .cgPoint,
          AXValueGetValue(positionAX, .cgPoint, &position),
          AXValueGetType(sizeAX) == .cgSize,
          AXValueGetValue(sizeAX, .cgSize, &size) else {
        return nil
    }

    return CGRect(origin: position, size: size)
}
