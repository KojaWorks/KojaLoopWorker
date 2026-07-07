import SwiftUI

/// "Check for Updates…" — the auto-update path that replaces the manual `git pull` + restart.
/// Sparkle is guarded by #if canImport, so a checkout without the package still builds; the button
/// simply doesn't appear until Sparkle is wired and an appcast (SUFeedURL) is configured.
///
/// The updater CONTROLLER is a single long-lived instance owned by AppState — creating one per View
/// render (a struct View is re-init'd constantly) would start duplicate updaters + background-check
/// schedulers. This button just triggers a manual check on that shared controller.
struct UpdateButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        #if canImport(Sparkle)
        Button("Check for Updates…") { appState.updaterController.updater.checkForUpdates() }
            .buttonStyle(.borderless).font(.caption)
        #else
        EmptyView()
        #endif
    }
}
