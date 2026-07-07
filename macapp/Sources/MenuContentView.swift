import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header()
            if let reason = appState.stopReason {
                Banner(text: reason, symbol: "exclamationmark.triangle.fill", tint: .red)
            }
            if appState.contractMismatch {
                Banner(text: "This app is too old for the running Manager. Update the app.",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if !appState.loopworkerFound {
                Banner(text: "loopworker not found on PATH. Install it (pipx) or set its path.",
                       symbol: "questionmark.folder", tint: .orange)
            }
            Divider()
            ReadinessPanel()
            Divider()
            SlotsPanel()
            Divider()
            Controls()
            Footer()
        }
        .padding(12)
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Koja Loops Manager").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StateChip(text: appState.controller.stateLabel, tint: appState.controller.stateTint)
        }
    }

    private var subtitle: String {
        guard let h = appState.health else { return appState.statusNote ?? "—" }
        let who = h.workerManager ?? "?"
        let paused = h.paused ? " · paused" : ""
        return "\(who) · v\(h.loopworkerVersion) · \(h.busy)/\(h.slots) busy\(paused)"
    }
}

// MARK: - Readiness (loopworker doctor)

private struct ReadinessPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Readiness").font(.subheadline).bold()
                Spacer()
                Button("Re-check") { appState.runDoctorNow() }
                    .buttonStyle(.borderless).font(.caption)
            }
            if let checks = appState.doctor?.checks {
                ForEach(checks) { CheckRow(check: $0) }
            } else {
                Text(appState.doctorNote ?? "Running host checks…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CheckRow: View {
    let check: ReadinessCheck

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(check.name).font(.caption).bold()
                    Text(check.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !check.ok, !check.remedy.isEmpty {
                    Text("→ \(check.remedy)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    // A failed REQUIRED check is a red blocker; a failed recommended one is an orange warning.
    private var symbol: String {
        check.ok ? "checkmark.circle.fill" : (check.required ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
    }
    private var tint: Color {
        check.ok ? .green : (check.required ? .red : .orange)
    }
}

// MARK: - Slots (/json)

private struct SlotsPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Slots").font(.subheadline).bold()
            if let sections = appState.snapshot?.sections, !sections.isEmpty {
                ForEach(sections, id: \.project) { section in
                    Text(section.project).font(.caption2).foregroundStyle(.secondary)
                    ForEach(section.slots) { SlotRow(slot: $0) }
                }
            } else {
                Text(appState.controller.isRunning ? "No slots reported yet." : "Manager not running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SlotRow: View {
    let slot: SlotSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("slot \(slot.index)").font(.caption).monospaced()
            Text(slot.card.map { "~\($0)" } ?? "—").font(.caption).foregroundStyle(.secondary)
            Text(slot.activity ?? slot.state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
    }

    private var color: Color {
        switch slot.state {
        case "busy": return .green
        case "broken": return .red
        case "idle": return .blue
        default: return .gray            // cold
        }
    }
}

// MARK: - Controls (start / drain / force-stop)

private struct Controls: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            if appState.controller.isRunning {
                Button("Stop (drain)") { appState.controller.drain() }
                Button("Force stop") { appState.controller.forceStop() }
                    .foregroundStyle(.red)
            } else {
                Button("Start Manager") { appState.controller.startFresh() }
                    .disabled(!appState.loopworkerFound)
            }
            Spacer()
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Button("Dashboard") {
                if let url = URL(string: "http://127.0.0.1:8787") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.borderless).font(.caption)
            Button("Connect…") { appState.showConnect = true }.buttonStyle(.borderless).font(.caption)
            UpdateButton()
            Spacer()
            // Quit routes through applicationShouldTerminate, which drains the Manager and holds
            // termination until it actually exits (see AppState) — no orphaned headless Manager.
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
    }
}

// MARK: - small reusables

private struct StateChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ManagerController {
    var stateLabel: String {
        switch state {
        case .stopped: return "STOPPED"
        case .starting: return "STARTING"
        case .running: return "RUNNING"
        case .draining: return "DRAINING"
        }
    }
    var stateTint: Color {
        switch state {
        case .stopped: return .gray
        case .starting, .draining: return .orange
        case .running: return .green
        }
    }
}
