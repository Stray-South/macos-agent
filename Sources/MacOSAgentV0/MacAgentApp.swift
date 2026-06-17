import AppKit
import MacAgentCore
import SwiftUI

@main
struct MacAgentApp: App {
    @StateObject private var model = AppModel()
    // Persisted launcher size — read at scene construction. Initial values
    // come from the agent suite (default 480 × 640 when unset). The
    // NSWindow resize observer attached on `.onAppear` writes back to
    // these keys whenever the operator drags an edge.
    @State private var launcherWidth: CGFloat = CGFloat(UserDefaults.agentSuite.launcherWidth)
    @State private var launcherHeight: CGFloat = CGFloat(UserDefaults.agentSuite.launcherHeight)

    init() {
        // NSApp (NSApplication!) is nil during App.init() on macOS 26+.
        // NSApplication.shared initialises the instance if it doesn't exist yet.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // ── Main window: welcome → hub ───────────────────────────────────────
        WindowGroup("macOS Agent v0") {
            ZStack {
                if model.showWelcome {
                    WelcomeView()
                        .environmentObject(model)
                        .frame(
                            width:  WindowLayout.welcomeSize.width,
                            height: WindowLayout.welcomeSize.height
                        )
                        .transition(.opacity)
                } else {
                    LauncherView()
                        .environmentObject(model)
                        // D7: resizable launcher. minWidth/minHeight keep the
                        // composer + a couple message bubbles visible at the
                        // smallest reasonable size; idealWidth/idealHeight
                        // honor the operator's prior persisted choice;
                        // maxWidth/maxHeight = .infinity enables drag-to-
                        // resize in both axes once `.windowResizability` is
                        // `.contentMinSize` below.
                        .frame(
                            minWidth: 360, idealWidth: launcherWidth, maxWidth: .infinity,
                            minHeight: 480, idealHeight: launcherHeight, maxHeight: .infinity
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.showWelcome)
            .onAppear {
                // Bring the app window to front on launch.
                // Two-step: async to let SwiftUI finish laying out, then activate.
                // NSApplication.shared used throughout — NSApp (IUO) can be nil on macOS 26+
                // before the runloop is fully set up.
                DispatchQueue.main.async {
                    let app = NSApplication.shared
                    // Filter to the main WindowGroup window — exclude the MenuBarExtra window
                    // which is a panel and should not be centred/activated like a regular window.
                    let mainWindow = app.windows.first(where: { !($0 is NSPanel) })
                        ?? app.keyWindow ?? app.mainWindow
                    if let window = mainWindow {
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                        // D7: persist user's resize choices. Observer is
                        // filtered to this specific window so HUD overlay
                        // panels and MenuBarExtra resizes don't trigger a
                        // write.
                        LauncherResizePersister.attach(to: window)
                    }
                    app.activate()
                }
            }
            .task { await model.bootstrap() }
        }
        // `.contentMinSize` lets the user drag wider/taller than ideal while
        // still respecting the frame's minWidth/minHeight floor. Previously
        // `.contentSize` locked the window to the content frame exactly —
        // operators could not expand to read long agent narrations (D7).
        .windowResizability(.contentMinSize)

        // ── Settings (Cmd+,) ─────────────────────────────────────────────────
        Settings {
            SettingsView()
                .environmentObject(model)
        }

        // ── Menu bar status item ──────────────────────────────────────────────
        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(model)
        } label: {
            MenuBarIconLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// D7: persists launcher window size to `UserDefaults.agentSuite` on every
/// resize. Observer tokens are filtered to a specific window instance so
/// HUD `NSPanel`s and the MenuBarExtra panel don't trigger writes. On
/// window close the observer is removed AND the dict entry purged — without
/// the cleanup a recycled `ObjectIdentifier` (if SwiftUI ever rebuilds the
/// scene) could collide with a stale entry and silently skip re-attachment.
/// Cumulative-review sev-2 #2.
@MainActor
final class LauncherResizePersister {
    private struct Entry {
        let resizeToken: NSObjectProtocol
        let closeToken: NSObjectProtocol
    }
    private static var observers: [ObjectIdentifier: Entry] = [:]

    static func attach(to window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return } // idempotent
        let resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let resized = notification.object as? NSWindow else { return }
            // Read on main actor — this closure is delivered on .main queue.
            // Width / height are persisted via UserDefaults.agentSuite, which
            // clamps to a safe range (see SettingsView.swift launcher{Width,
            // Height}). `set` triggers UserDefaults synchronisation on next
            // runloop turn; no flush required for crash-safety because the
            // value is non-critical UI state.
            MainActor.assumeIsolated {
                UserDefaults.agentSuite.launcherWidth = Double(resized.frame.size.width)
                UserDefaults.agentSuite.launcherHeight = Double(resized.frame.size.height)
            }
        }
        let closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let closingWindow = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                detach(window: closingWindow)
            }
        }
        observers[id] = Entry(resizeToken: resizeToken, closeToken: closeToken)
    }

    /// Remove both observers and drop the dict entry for `window`. Idempotent.
    /// Called from the `willCloseNotification` handler; safe to call manually.
    static func detach(window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let entry = observers.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(entry.resizeToken)
        NotificationCenter.default.removeObserver(entry.closeToken)
    }
}
