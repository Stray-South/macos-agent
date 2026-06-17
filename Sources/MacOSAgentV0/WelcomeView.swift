import AppKit
import SwiftUI

// Welcome sizes / positions
enum WindowLayout {
    static let welcomeSize  = CGSize(width: 680, height: 420)
    /// Default hub size when no persisted user choice exists. The launcher
    /// became resizable in D7 — operators can drag wider/taller and that
    /// choice persists to `UserDefaults.agentSuite`. `glideToCorner` honors
    /// the persisted size via `hubFrame(on:)`; this constant is the
    /// fallback when the keys are unset (first-ever launch).
    static let hubSize      = CGSize(width: 480, height: 640)
    static let hubMargin: CGFloat = 16  // gap from screen edge

    /// Compute the hub's landing frame on `screen`, honoring the operator's
    /// persisted launcher size. Sev-2 cumulative-review fix — the previous
    /// hardcoded `hubSize` would clobber a resized window's persisted
    /// dimensions if welcome ever re-showed after a resize (e.g. dev reset
    /// of `hasSeenWelcome`). Now: use the suite's `launcherWidth` /
    /// `launcherHeight` getters which themselves default to `hubSize` when
    /// unset, so first-launch behaviour is unchanged.
    /// `@MainActor` because the persisted launcher size lives in
    /// `UserDefaults.agentSuite` which is main-actor-isolated. Only caller
    /// is `WelcomeView.glideToCorner`, which itself runs from a SwiftUI
    /// button action on the main actor.
    @MainActor
    static func hubFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = CGFloat(UserDefaults.agentSuite.launcherWidth)
        let height = CGFloat(UserDefaults.agentSuite.launcherHeight)
        return NSRect(
            x: visible.maxX - width  - hubMargin,
            y: visible.minY          + hubMargin,
            width:  width,
            height: height
        )
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var launching     = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()
                headline
                Spacer()
                ctaButton
                    .padding(.bottom, 52)
            }
            .padding(.horizontal, 48)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sub-views

    private var background: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.10)
            RadialGradient(
                colors: [Color(red: 0.30, green: 0.20, blue: 0.60).opacity(0.35), .clear],
                center: .init(x: 0.5, y: 0.35),
                startRadius: 0,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }

    private var headline: some View {
        VStack(spacing: 10) {
            Text("HEY IT'S ME")
                .font(.system(size: 58, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .tracking(-1)

            Text("I'M READY TO GET SHIT DONE")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1)

            Text("macOS Agent v0  ·  powered by Claude")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 8)
        }
    }

    private var ctaButton: some View {
        Button(action: glideToCorner) {
            Text(launching ? "Heading over…" : "Yes let's")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .frame(width: 200)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.38, blue: 1.0),
                                 Color(red: 0.38, green: 0.25, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .scaleEffect(reduceMotion ? 1.0 : (launching ? 0.94 : 1.0))
        .disabled(launching)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: launching)
    }

    // MARK: Glide to corner
    //
    // The 520 ms window-position animation below is a one-shot transition
    // from the centered welcome size (680×420) to the hub size (480×640)
    // in the bottom-right corner. Per AGENTS.md §AuDHD-First Defaults, the
    // 200 ms cap has one explicit carve-out: a single one-shot window-
    // position animation on first launch, opt-out via reduceMotion. The
    // alternative (instant teleport) is more jarring for non-reduceMotion
    // operators than a smooth glide, and the window MUST move regardless.
    // Per `hasSeenWelcome` UserDefaults persistence, this fires once per
    // Keychain identity — never again after the first dismissal.
    //
    // Previous entrance fade-in animations (550 ms text + 550 ms button)
    // were decorative-only — text/button rendered identically before and
    // after — and were deleted in this PR. The glide is functional and
    // stays.
    private func glideToCorner() {
        launching = true
        // Persist dismissal so the welcome screen is skipped on all future launches.
        UserDefaults.agentSuite.hasSeenWelcome = true
        let app = NSApplication.shared
        guard let window = app.keyWindow ?? app.mainWindow ?? app.windows.first,
              let screen = window.screen ?? NSScreen.main else {
            model.showWelcome = false
            return
        }

        let target = WindowLayout.hubFrame(on: screen)

        if reduceMotion {
            // Skip the animation entirely — just jump to the hub position.
            window.setFrame(target, display: true)
            model.showWelcome = false
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.52
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
                window.animator().setFrame(target, display: true)
            }, completionHandler: {
                DispatchQueue.main.async {
                    model.showWelcome = false
                }
            })
        }
    }
}
