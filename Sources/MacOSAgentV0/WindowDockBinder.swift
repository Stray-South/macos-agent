import AppKit
import SwiftUI

struct WindowDockBinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        // Normal level so the window behaves like a standard app window
        // (activates on click, shows in Cmd+Tab, has standard traffic-light chrome).
        window.level = .normal
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.95)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        // Keep the title bar visible — it provides the close (×), minimise, and
        // zoom buttons the user expects from a real macOS app.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.title = "macOS Agent v0"

        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Only move the origin — never override the size that SwiftUI computed.
        let origin = CGPoint(
            x: visible.midX - (window.frame.width / 2),
            y: visible.minY + 8
        )
        if abs(window.frame.origin.x - origin.x) > 2 || abs(window.frame.origin.y - origin.y) > 2 {
            window.setFrameOrigin(origin)
        }
    }
}
