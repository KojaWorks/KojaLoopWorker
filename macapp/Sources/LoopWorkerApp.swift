import SwiftUI

@main
struct LoopWorkerApp: App {
    // AppState is also the NSApplicationDelegate, so applicationShouldTerminate can drain the
    // Manager before the app dies. The adaptor observes it (ObservableObject), so the icon updates.
    @NSApplicationDelegateAdaptor(AppState.self) private var appState

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(appState)
                .frame(width: 340)
        } label: {
            MenuBarIcon(app: appState)
        }
        .menuBarExtraStyle(.window)   // a real popover panel, not a plain menu
    }
}

/// Onboarding until there's a config, status once there is (or when the user re-opens Connect).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        if appState.isConfigured && !appState.showConnect {
            MenuContentView()
        } else {
            ConnectView()
        }
    }
}
