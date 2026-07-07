import SwiftUI

@main
struct LoopWorkerApp: App {
    // AppState is also the NSApplicationDelegate, so applicationShouldTerminate can drain the
    // Manager before the app dies. The adaptor observes it (ObservableObject), so the icon updates.
    @NSApplicationDelegateAdaptor(AppState.self) private var appState

    var body: some Scene {
        // The popover is always the minimal status view; onboarding + fix-it is the Setup window
        // (opened automatically on first launch / required-check failure — see AppState).
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
                .frame(width: 320)
        } label: {
            MenuBarIcon(app: appState)
        }
        .menuBarExtraStyle(.window)   // a real popover panel, not a plain menu
    }
}
