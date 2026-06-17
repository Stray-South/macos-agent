import AppKit
import SwiftUI

/// Displays a brief ripple circle at the screen point where the agent clicks.
/// The overlay window is full-screen, transparent, and never intercepts mouse events.
// @unchecked Sendable is safe: the class is @MainActor-isolated, which serializes all
// access to mutable state (window, model). No cross-actor mutation is possible.
@MainActor
public final class CursorFeedbackController: @unchecked Sendable {
    private var window: NSWindow?
    private let model = CursorFeedbackModel()

    public init() {
        configureWindow()
    }

    /// Show a ripple at `point` (CGEvent / AppKit screen coordinates, bottom-left origin).
    public func showRipple(at point: CGPoint) {
        guard let window else { return }
        model.addRipple(at: point, windowHeight: window.frame.height) { [weak self] in
            // Called when the last ripple drains — hide the window so it doesn't sit
            // as a floating invisible layer over other apps.
            self?.window?.orderOut(nil)
        }
        window.orderFrontRegardless()
    }

    private func configureWindow() {
        let frame = NSScreen.main?.frame ?? .zero
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: CursorRippleView().environmentObject(model))
        window = w
        // Not shown at init — ordered front only when a ripple is requested.
    }
}

// MARK: - Model

@MainActor
private final class CursorFeedbackModel: ObservableObject {
    @Published var ripples: [RippleItem] = []

    struct RippleItem: Identifiable {
        let id = UUID()
        // SwiftUI position (top-left origin).
        let position: CGPoint
    }

    func addRipple(at screenPoint: CGPoint, windowHeight: CGFloat, onDrained: @escaping @MainActor () -> Void) {
        // PR-4: AuDHD opt-out. When system Reduce Motion is on, skip the
        // ripple entirely — the inner RippleCircle view's animation guard
        // wasn't enough because the parent still appended a static dot that
        // flashed in and out for 0.65 s. Per AGENTS.md §AuDHD-First Defaults,
        // the cursor click ripple is a named ephemeral confirmation
        // affordance allowed under the reduceMotion contract: when
        // reduceMotion is on, the affordance does NOT appear at all.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Only call onDrained() when no other ripples are in flight.
            // If a ripple Task is still counting down from a click before
            // the user toggled Reduce Motion on, calling onDrained() here
            // would `orderOut(nil)` the panel while the in-flight item is
            // still in `self.ripples`. When its drain check finally fires,
            // `isEmpty` is true and `onDrained()` fires again — but the
            // window is already hidden. Worse: if a new click arrives
            // between the early-drain and the in-flight item's removal,
            // the next ripple is appended to a non-empty list and never
            // drains, leaking the overlay window. PR-4 adversarial sev-2.
            if ripples.isEmpty {
                onDrained()
            }
            return
        }
        // Convert AppKit/CGEvent bottom-left origin to SwiftUI top-left origin.
        let pos = CGPoint(x: screenPoint.x, y: windowHeight - screenPoint.y)
        let item = RippleItem(position: pos)
        ripples.append(item)
        let id = item.id
        // Use Task rather than DispatchQueue so the closure is properly @MainActor-isolated.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.65))
            self?.ripples.removeAll { $0.id == id }
            if self?.ripples.isEmpty == true {
                onDrained()
            }
        }
    }
}

// MARK: - Views

private struct CursorRippleView: View {
    @EnvironmentObject private var model: CursorFeedbackModel

    var body: some View {
        ZStack {
            ForEach(model.ripples) { ripple in
                RippleCircle()
                    .position(ripple.position)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

private struct RippleCircle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 0.25
    @State private var opacity: Double = 0.9

    var body: some View {
        ZStack {
            // Outer expanding ring
            Circle()
                .stroke(Color.cyan.opacity(0.7), lineWidth: 2)
                .frame(width: 48, height: 48)
                .scaleEffect(scale)
                .opacity(opacity)
            // Solid centre dot
            Circle()
                .fill(Color.cyan.opacity(0.4))
                .frame(width: 10, height: 10)
                .opacity(opacity)
        }
        .onAppear {
            if reduceMotion {
                scale = 1.0
                opacity = 0
            } else {
                withAnimation(.easeOut(duration: 0.45)) {
                    scale = 1.0
                    opacity = 0
                }
            }
        }
    }
}
