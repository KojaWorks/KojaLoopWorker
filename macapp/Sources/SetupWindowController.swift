import AppKit
import SwiftUI

/// Hosts the Setup window as a REAL macOS window, not the menu-bar popover. A menu-bar agent runs
/// as `.accessory` (no Dock icon, and its windows can't take focus), so we flip to `.regular`
/// while the window is open — it comes to the front, is Cmd-Tabbable, shows a Dock icon — and
/// back to `.accessory` when it closes. One reused NSWindow hosting the SwiftUI SetupView; this
/// is what fixes the old "Connect… does nothing" (that was a popover-content swap that never
/// surfaced). See the Setup-window card.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let host = NSHostingController(rootView: SetupView().environmentObject(appState))
            let w = NSWindow(contentViewController: host)
            w.title = "Koja Loops Manager"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false     // reuse one window across opens
            w.setContentSize(NSSize(width: 480, height: 560))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)    // agent → app: focusable, front-most, Dock icon
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // back to a menu-bar-only agent
    }
}
