import SwiftUI

/// First-run onboarding — so nobody edits a config file or reads a README. Everything but the
/// Patch token is pre-filled (see Instance/ConfigStore); the token is one paste, with a button
/// that opens Patch to mint one. Writes ~/.loopworker/config.toml + .env, then hands back to
/// the status view.
struct ConnectView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings = ConnectSettings()
    @State private var showAdvanced = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Patch").font(.headline)
            Text("Koja Loops Manager needs a Patch token to read your backlog. Everything else is filled in for you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Patch token").font(.caption).bold()
                    Spacer()
                    Button("Mint one…") {
                        if let url = URL(string: Instance.appBase) { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.borderless).font(.caption)
                }
                SecureField("paste your token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
                Text("In Patch: Settings → Tokens → New token (backlog access is all it needs).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    field("Manager id", $settings.workerManager)
                    field("Clones dir", $settings.clonesDir)
                    Stepper("Max slots: \(settings.maxSlots)", value: $settings.maxSlots, in: 1...16)
                    field("API base", $settings.apiBase)
                }.padding(.top, 4)
            }.font(.caption)

            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                if appState.isConfigured {
                    Button("Cancel") { appState.showConnect = false }.buttonStyle(.borderless)
                }
                Spacer()
                Button(busy ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(settings.token.isEmpty || busy)
            }
        }
        .padding(14)
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            do {
                try ConfigStore.write(settings)
                await appState.reloadAfterConnect()   // re-check config + re-run readiness
                busy = false
            } catch {
                self.error = "Couldn't save config: \(error.localizedDescription)"
                busy = false
            }
        }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            TextField("", text: binding).textFieldStyle(.roundedBorder)
        }
    }
}
