import SwiftUI

/// The menu-bar popover — deliberately minimal (see the minimal-popover card): run state, slots,
/// Start/Stop, Quit. The readiness checklist, the token form, and the Dashboard link all moved to
/// the Setup window; a failing check shows here only as a one-line "Needs attention → Open Setup".
struct MenuContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header()
            if case .draining = appState.controller.state {
                DrainingBanner()
            }
            if let reason = appState.stopReason {
                Banner(text: reason, symbol: "exclamationmark.triangle.fill", tint: .red)
            }
            if appState.contractMismatch {
                Banner(text: "This app is too old for the running Manager. Update the app.",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            AttentionLine()
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

// MARK: - Draining (the visible, legible Quit/Stop drain — see the drain card)

private struct DrainingBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.controller.isQuitting
                     ? "Quitting — workers are finishing. No new work starts."
                     : "Draining — workers are finishing. No new work starts.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button(appState.controller.isQuitting ? "Quit now" : "Stop now") {
                    appState.controller.forceStop()
                }
                .controlSize(.small).foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Attention (readiness lives in Setup; here it's one line that opens it)

private struct AttentionLine: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !appState.isConfigured {
            line("Not connected — open Setup", tint: .orange)
        } else if !appState.loopworkerFound {
            line("loopworker not found — open Setup", tint: .orange)
        } else if appState.doctorHasFailure {
            line("Needs attention — open Setup", tint: appState.doctorHasRequiredFailure ? .red : .orange)
        }
    }

    private func line(_ text: String, tint: Color) -> some View {
        Button { appState.openSetup() } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
                Text(text).font(.caption).foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("slot \(slot.index)").font(.caption).monospaced()
                Text(slot.card.map { "~\($0)" } ?? "—").font(.caption).foregroundStyle(.secondary)
                Text(slot.activity ?? slot.state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            // Persisted failure reason: survives the retry loop that overwrites `activity`,
            // so a slot stuck re-provisioning still shows WHY it last failed.
            if let err = slot.lastError {
                Text(failureText(err)).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    .padding(.leading, 13)
            }
        }
    }

    private func failureText(_ err: String) -> String {
        var s = "⚠ \(err)"
        if let n = slot.retryCount, n > 0 { s += " · retry \(n)" }
        if let secs = slot.retryIn {
            s += secs >= 60 ? " · next in \(Int(secs / 60))m" : " · next in \(Int(secs))s"
        }
        return s
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
            switch appState.controller.state {
            case .draining:
                EmptyView()                 // the draining banner owns the stop affordance
            case .running, .starting:
                Button("Stop (drain)") { appState.controller.drain() }
                Button("Force stop") { appState.controller.forceStop() }.foregroundStyle(.red)
            case .stopped:
                Button("Start Manager") { appState.controller.startFresh() }
                    .disabled(!appState.loopworkerFound || !appState.isConfigured)
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
            Button("Setup…") { appState.openSetup() }.buttonStyle(.borderless).font(.caption)
            UpdateButton()
            Spacer()
            // Quit routes through applicationShouldTerminate, which drains the Manager and holds
            // termination until it exits (see AppState). While draining, the banner above owns the
            // messaging + the "Quit now" fast path, so we drop Quit here to avoid a dead button.
            if case .draining = appState.controller.state {
                EmptyView()
            } else {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption)
            }
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
