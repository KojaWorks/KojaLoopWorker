import AppKit
import SwiftUI

/// The Setup window: onboarding (connect to Patch) AND the health/fix-it checklist, unified into
/// one real macOS window (see the Setup-window card). Auto-opens on first launch and when a
/// required readiness check fails; also reachable from the popover's "Setup…". This is where the
/// checklist and the token form live now — the menu-bar popover stays minimal.
struct SetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ConnectionSection()
                Divider()
                ReadinessSection()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Koja Loops Manager").font(.title2).bold()
            Text("Set up once: connect your backlog, then clear any red checks.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connection (paste a Patch token)

private struct ConnectionSection: View {
    @EnvironmentObject var appState: AppState
    @State private var settings = ConnectSettings()
    @State private var showAdvanced = false
    @State private var showReplace = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connection", systemImage: "link").font(.headline)
            if appState.isConfigured && !showReplace {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected to Patch.").font(.callout)
                    Spacer()
                    Button("Replace token…") { showReplace = true }.buttonStyle(.borderless)
                }
            } else {
                form
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Koja Loops Manager needs a Patch token to read your backlog. Everything else is filled in for you.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Patch token").font(.callout).bold()
                Spacer()
                Button("Mint one…") { openURL(Instance.appBase) }.buttonStyle(.borderless)
            }
            SecureField("paste your token", text: $settings.token).textFieldStyle(.roundedBorder)
            Text("In Patch: Settings → Tokens → New token (backlog access is all it needs).")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    labeledField("Manager id", $settings.workerManager)
                    labeledField("Clones dir", $settings.clonesDir)
                    Stepper("Max slots: \(settings.maxSlots)", value: $settings.maxSlots, in: 1...16)
                    labeledField("API base", $settings.apiBase)
                }.padding(.top, 4)
            }.font(.callout)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if appState.isConfigured {
                    Button("Cancel") { showReplace = false; error = nil }.buttonStyle(.borderless)
                }
                Spacer()
                Button(buttonLabel) { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(settings.token.isEmpty || busy)
            }
        }
    }

    private var buttonLabel: String {
        busy ? "Connecting…" : (appState.isConfigured ? "Save" : "Connect")
    }

    private func connect() {
        busy = true; error = nil
        Task {
            do {
                try ConfigStore.write(settings)
                await appState.reloadAfterConnect()   // re-check config + re-run readiness
                busy = false; showReplace = false
            } catch {
                self.error = "Couldn't save config: \(error.localizedDescription)"
                busy = false
            }
        }
    }

    private func labeledField(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField("", text: binding).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Readiness (the loopworker doctor checklist, with fix-it actions)

private struct ReadinessSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Readiness", systemImage: "stethoscope").font(.headline)
                Spacer()
                if appState.doctorRunning { ProgressView().controlSize(.small) }
                Button("Re-check") { appState.runDoctorNow() }.disabled(appState.doctorRunning)
            }
            if let checks = appState.doctor?.checks {
                if checks.allSatisfy(\.ok) { allSet }
                ForEach(checks) { SetupCheckRow(check: $0) }
            } else {
                Text(appState.doctorNote ?? "Running host checks…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var allSet: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("You're all set — this host is ready to run workers.").font(.callout)
            Spacer()
            Button("Done") { appState.closeSetup() }.buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SetupCheckRow: View {
    let check: ReadinessCheck
    @EnvironmentObject var appState: AppState
    @State private var copied = false
    // Claude-only: the inline "paste your setup-token" form (LLM auth is the one check the app can
    // actually fix in place, by writing CLAUDE_CODE_OAUTH_TOKEN to .env).
    @State private var expanded = false
    @State private var token = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(check.name.capitalized).font(.callout).bold()
                        Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if !check.ok, !check.remedy.isEmpty {
                        Text(check.remedy).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                trailingButton
            }
            if isClaude, expanded { claudeForm }
        }
        .padding(.vertical, 2)
    }

    private var isClaude: Bool { check.name == "claude" }

    @ViewBuilder private var trailingButton: some View {
        if !check.ok {
            if isClaude {
                Button(expanded ? "Cancel" : "Set up login…") { expanded.toggle(); saveError = nil }
                    .buttonStyle(.bordered)
            } else if let action {
                Button(copied ? "Copied ✓" : action.label) { run(action) }.buttonStyle(.bordered)
            }
        }
    }

    // Guide the user through `claude setup-token` and persist its output. An interactive login
    // doesn't carry to headless workers, so this token (in .env) is what actually authorizes them.
    private var claudeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("1.").font(.caption).foregroundStyle(.secondary)
                Text("claude setup-token").font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Button(copied ? "Copied ✓" : "Copy") { copyCommand() }.buttonStyle(.borderless).font(.caption)
                Text("in a terminal; log in when prompted.").font(.caption).foregroundStyle(.secondary)
            }
            Text("2. Paste the token it prints (starts with sk-ant-oat…):")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("paste token", text: $token).textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            } else if appState.controller.isRunning {
                // Env is frozen at Manager launch, so a running Manager needs a restart to read it.
                Text("If the Manager is already running, restart it (Stop, then Start) after saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 24).padding(.top, 2)
    }

    private var symbol: String {
        check.ok ? "checkmark.circle.fill" : (check.required ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
    }
    private var tint: Color {
        check.ok ? .green : (check.required ? .red : .orange)
    }

    // A concrete next step per failing check: open Patch to mint a token, or copy the one-liner
    // that fixes it. Checks without a mechanical fix (tmux/git/config) just show their remedy text.
    // (claude is handled by claudeForm, not here.)
    private struct CheckAction { let label: String; let value: String; let isCopy: Bool }
    private var action: CheckAction? {
        switch check.name {
        case "backlog": return CheckAction(label: "Mint token…", value: Instance.appBase, isCopy: false)
        case "engine":  return CheckAction(label: "Copy start command", value: "orb start", isCopy: true)
        default:        return nil
        }
    }
    private func run(_ action: CheckAction) {
        if action.isCopy {
            copyToPasteboard(action.value)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } else {
            openURL(action.value)
        }
    }

    private func copyCommand() {
        copyToPasteboard("claude setup-token")
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }

    private func save() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        saveError = nil
        do {
            try ConfigStore.upsertEnvVar(key: "CLAUDE_CODE_OAUTH_TOKEN", value: value)
            token = ""; expanded = false
            appState.runDoctorNow()   // re-check reads the fresh .env → claude flips green
        } catch {
            saveError = "Couldn't save token: \(error.localizedDescription)"
        }
    }
}

// MARK: - AppKit helpers

private func openURL(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
