import AppKit
import SwiftUI

/// Single shared pulsing-dot affordance for "agent is alive / running" UX.
/// Used by the HUD overlay (cyan, 6 pt, 0.8 s) and the launcher live-activity
/// row (orange, 8 pt, 0.9 s). Centralised here so the AGENTS.md "single
/// PulsingDot (opt-out safe)" rule is enforced structurally — only one
/// definition exists in the codebase. A SupplyChainTests grep guards that
/// invariant.
///
/// **AuDHD contract.** When the system-wide Reduce Motion setting is on,
/// the dot renders as a static (no animation, no opacity/scale oscillation).
/// Operators who opted out of motion don't get a flashing dot.
///
/// **Reduce-Motion source.** Reads `NSWorkspace.shared
/// .accessibilityDisplayShouldReduceMotion` directly rather than the
/// SwiftUI `@Environment(\.accessibilityReduceMotion)` value. The HUD
/// overlay path hosts this view via `NSHostingView` on a borderless
/// `NSPanel` — in that setup the SwiftUI Environment doesn't always
/// receive the system trait. The NSWorkspace API is the always-true
/// system value and matches `CursorFeedbackController`'s approach.
/// PR-4 adversarial review (sev-1) caught the Environment bridge gap.
///
/// **Animation duration.** Per AGENTS.md §AuDHD-First Defaults, repeating
/// animations >200 ms are forbidden EXCEPT the named `PulsingDot`
/// confirmation affordance — under the same reduceMotion contract.
public struct PulsingDot: View {
    public let color: Color
    public let size: CGFloat
    public let duration: Double

    @State private var animating = false

    /// `color` is required — defaults removed because the two call sites use
    /// different colors (HUD: cyan, Launcher: orange) and a silent default
    /// would silently produce the wrong color in a future third call site.
    /// `size` and `duration` retain defaults that match the more common
    /// (launcher) shape. Cumulative-review sev-2.
    public init(color: Color, size: CGFloat = 8, duration: Double = 0.9) {
        self.color = color
        self.size = size
        self.duration = duration
    }

    public var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1.0 : (animating ? 1.0 : 0.6))
            .opacity(reduceMotion ? 1.0 : (animating ? 1.0 : 0.4))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}
