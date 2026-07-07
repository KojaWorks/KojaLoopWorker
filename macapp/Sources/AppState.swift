import Combine
import Foundation
import SwiftUI

/// The app's single source of observed truth: the Manager supervisor plus the polled status
/// contract. Cheap /health + /json every few seconds; the heavier `doctor` sweep on a slow
/// cadence (it shells out to `claude -p`, so polling it fast would be wasteful — mirrors
/// AuthGate's own TTL rationale). Also the app delegate, so quitting never orphans the Manager.
@MainActor
final class AppState: NSObject, ObservableObject, NSApplicationDelegate {
    @Published var health: Health?
    @Published var snapshot: Snapshot?
    @Published var doctor: DoctorReport?
    @Published var doctorNote: String?
    @Published var statusNote: String?
    @Published var contractMismatch = false
    @Published var isConfigured = ConfigStore.isConfigured   // ~/.loopworker/config.toml exists
    @Published var showConnect = false                        // re-open onboarding when configured

    let controller: ManagerController
    private let client: StatusClient
    private var pollTask: Task<Void, Never>?
    private var lastDoctor = Date.distantPast
    private var healthFailures = 0
    private var cancellables = Set<AnyCancellable>()

    private let healthEverySeconds: TimeInterval = 3
    private let doctorEverySeconds: TimeInterval = 120
    private let failuresBeforeUnknown = 3   // keep last-known status through a blip; only clear after this many

    override init() {
        let path = LoopWorkerLocator.resolve()
        controller = ManagerController(loopworkerPath: path)
        client = StatusClient(loopworkerPath: path ?? "loopworker")
        super.init()
        // A nested ObservableObject's changes don't re-render our views on their own; forward
        // the controller's run-state changes so the icon + panel update live.
        controller.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        startPolling()  // poll in the background so the menu-bar icon is current before first open
    }

    // MARK: NSApplicationDelegate — quitting the app is the off switch; don't orphan the Manager.

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning else { return .terminateNow }
        controller.beginQuitDrain { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater   // stay alive (draining…) until the Manager actually exits
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.terminateChildIfRunning()   // belt-and-suspenders: a normal quit/logout never orphans
    }

    var loopworkerFound: Bool { controller.loopworkerPath != nil }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: UInt64(healthEverySeconds * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func runDoctorNow() {
        lastDoctor = .distantPast
        Task { await refreshDoctor() }
    }

    /// After the Connect sheet writes config: swap back to the status view and re-check readiness
    /// so the backlog check flips green immediately.
    func reloadAfterConnect() async {
        isConfigured = ConfigStore.isConfigured
        showConnect = false
        lastDoctor = .distantPast
        await refreshDoctor()
    }

    private func refresh() async {
        do {
            let h = try await client.health()
            health = h
            contractMismatch = h.contractVersion != supportedContractVersion
            snapshot = try? await client.snapshot()
            statusNote = nil
            healthFailures = 0
            controller.markRunning()   // first good read: the Manager's dashboard is up
        } catch {
            // Don't nuke the last-known status on a single blip — mirror the Manager's own
            // "keep the last-known set on a failed read" scar. Clear only when genuinely down.
            healthFailures += 1
            if case .stopped = controller.state {
                health = nil; snapshot = nil; statusNote = "Manager not running"
            } else if healthFailures >= failuresBeforeUnknown {
                health = nil; snapshot = nil
                statusNote = "Manager unreachable (\(healthFailures) failed polls)"
            } else {
                statusNote = "status momentarily unavailable…"   // keep last-known health/snapshot
            }
        }
        if Date().timeIntervalSince(lastDoctor) > doctorEverySeconds {
            await refreshDoctor()
        }
    }

    private func refreshDoctor() async {
        lastDoctor = Date()
        guard loopworkerFound else {
            doctor = nil
            doctorNote = "loopworker not found — install it (pipx) or set its path"
            return
        }
        do {
            doctor = try await client.doctor()
            doctorNote = nil
        } catch {
            doctorNote = "readiness check failed: \(error.localizedDescription)"
        }
    }

    // Fleet state the menu-bar icon draws from (see MenuBarIcon).
    var allSlots: [SlotSnapshot] { snapshot?.sections.flatMap { $0.slots } ?? [] }
    var anySlotBroken: Bool { allSlots.contains { $0.state == "broken" } }
    var needsAttention: Bool { contractMismatch || doctor?.ok == false || anySlotBroken }
}
