import Foundation
@testable import LoopWorkerCore

/// A tmux server in memory. `spawn` creates a live session with an empty pane; tests set the
/// pane text and liveness to simulate a worker.
final class FakeTmux: TmuxDriving, @unchecked Sendable {
    struct Session {
        var alive = true
        var pane = ""
    }
    struct Spawned: Equatable {
        var session: String
        var directory: URL
        var script: URL
    }
    struct State {
        var sessions: [String: Session] = [:]
        var spawned: [Spawned] = []
        var killed: [String] = []
        var entersSent: [String] = []
        var failSpawn = false
        var failIsAlive: Set<String> = []
        /// The pane a freshly spawned session shows.
        var spawnPane = ""
    }

    let state = Guarded(State())

    func set(_ session: String, alive: Bool? = nil, pane: String? = nil) {
        state {
            var s = $0.sessions[session] ?? Session()
            if let alive { s.alive = alive }
            if let pane { s.pane = pane }
            $0.sessions[session] = s
        }
    }
    var spawned: [Spawned] { state.get.spawned }
    var killed: [String] { state.get.killed }
    func exists(_ session: String) -> Bool { state.get.sessions[session] != nil }

    func sessions(prefix: String) async throws -> [String] {
        state { $0.sessions.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func spawn(session: String, directory: URL, script: URL) async throws {
        try state {
            if $0.failSpawn { throw FakeError("tmux new-session \(session) failed") }
            $0.spawned.append(Spawned(session: session, directory: directory, script: script))
            $0.sessions[session] = Session(pane: $0.spawnPane)
        }
    }

    func isAlive(_ session: String) async throws -> Bool {
        try state {
            if $0.failIsAlive.contains(session) { throw FakeError("tmux display-message \(session) timed out") }
            return $0.sessions[session]?.alive ?? false
        }
    }

    func capture(_ session: String, lines: Int) async throws -> String {
        state { $0.sessions[session]?.pane ?? "" }
    }

    func sendEnter(_ session: String) async throws {
        state {
            $0.entersSent.append(session)
            $0.sessions[session]?.pane = ""
        }
    }

    func kill(_ session: String) async throws {
        state {
            $0.killed.append(session)
            $0.sessions[session] = nil
        }
    }
}
