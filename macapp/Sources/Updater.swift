import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// "Check for Updates…" — the auto-update path that replaces the manual `git pull` + restart.
/// Sparkle is added on demand (see macapp/README.md) and guarded by #if canImport, so a fresh
/// checkout without the package still builds; the button simply doesn't appear until Sparkle
/// is wired and an appcast (SUFeedURL) is configured.
struct UpdateButton: View {
    #if canImport(Sparkle)
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some View {
        Button("Check for Updates…") { updater.updater.checkForUpdates() }
            .buttonStyle(.borderless).font(.caption)
    }
    #else
    var body: some View { EmptyView() }
    #endif
}
