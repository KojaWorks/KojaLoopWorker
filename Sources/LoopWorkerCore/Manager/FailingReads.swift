import Foundation

/// A backlog list read that the Manager makes on a schedule.
public enum BacklogRead: String, Sendable, Codable, CaseIterable {
    /// `Backlog.workable`, at each fill.
    case workable
    /// `Backlog.working`, at each stranded-card sweep.
    case working
    /// `Backlog.verifying`, at each CI sweep.
    case verifying
}

/// The backlog reads that are failing, per read and project, and when each one is due an alert.
/// Pure: the Manager feeds it every read's result and sends the alerts that it returns.
struct FailingReads {
    /// A read that has failed for this long without a success is alerted.
    static let alertAfter: TimeInterval = 600

    struct Key: Hashable {
        var read: BacklogRead
        var project: String
    }

    struct Failure: Equatable {
        /// The first failure of the current run of failures.
        var since: Date
        /// The latest failure's error, redacted.
        var error: String
        var alerted = false
    }

    private(set) var failing: [Key: Failure] = [:]

    /// Records that `read` failed for `projects`, and marks those that have now failed for
    /// `alertAfter` as alerted.
    /// - Returns: The newly alerted failures; empty when none crossed the threshold just now.
    mutating func failed(_ read: BacklogRead, projects: [String], error: String, at now: Date) -> [Key: Failure] {
        var due: [Key: Failure] = [:]
        for project in projects {
            let key = Key(read: read, project: project)
            var f = failing[key] ?? Failure(since: now, error: error)
            f.error = error
            if !f.alerted && now.timeIntervalSince(f.since) >= Self.alertAfter {
                f.alerted = true
                due[key] = f
            }
            failing[key] = f
        }
        return due
    }

    /// Clears the failures of `read` for `projects`.
    /// - Returns: The cleared failures that had been alerted, so their recovery is alerted too.
    mutating func succeeded(_ read: BacklogRead, projects: [String]) -> [Key: Failure] {
        var recovered: [Key: Failure] = [:]
        for project in projects {
            let key = Key(read: read, project: project)
            if let f = failing.removeValue(forKey: key), f.alerted { recovered[key] = f }
        }
        return recovered
    }

    /// Forgets the failures of projects that are no longer configured, which no read clears.
    /// - Returns: The forgotten projects.
    mutating func prune(keeping projects: Set<String>) -> Set<String> {
        let gone = Set(failing.keys.map(\.project)).subtracting(projects)
        failing = failing.filter { !gone.contains($0.key.project) }
        return gone
    }
}

extension Manager {
    /// Records a failed backlog read; alerts once when it has failed for `FailingReads.alertAfter`.
    func readFailed(_ read: BacklogRead, _ specs: [ProjectSpec], _ error: any Error) {
        let now = clock.now()
        let message = deps.redact("\(error)")
        let due = failingReads.failed(read, projects: specs.map(\.path), error: message, at: now)
        guard let since = due.values.map(\.since).min() else { return }
        let projects = due.keys.map(\.project).sorted().joined(separator: ", ")
        let summary = "can't read \(read.rawValue) cards for \(projects) since \(StatusReport.stamp(since)) (\(StatusReport.duration(now.timeIntervalSince(since)))): \(message)"
        log.error("backlog read failing: \(summary); retrying, and alerting again only after it recovers")
        notify(key: "backlog-read-\(read.rawValue)", "LoopWorker on \(hostName): \(summary)")
    }

    /// Clears a backlog read's failures for `specs`; alerts once for each read that had alerted.
    func readSucceeded(_ read: BacklogRead, _ specs: [ProjectSpec]) {
        let recovered = failingReads.succeeded(read, projects: specs.map(\.path))
        guard let since = recovered.values.map(\.since).min() else { return }
        let projects = recovered.keys.map(\.project).sorted().joined(separator: ", ")
        let summary = "reading \(read.rawValue) cards for \(projects) recovered after failing for \(StatusReport.duration(clock.now().timeIntervalSince(since)))"
        log.info("backlog read \(summary)")
        notify(key: "backlog-read-\(read.rawValue)-recovered", "LoopWorker on \(hostName): \(summary)")
    }

    /// Drops failing reads of projects that left the config, since no read clears them any more.
    func pruneFailingReads() {
        let gone = failingReads.prune(keeping: Set(order.compactMap { projects[$0]?.spec.path }))
        if !gone.isEmpty { log.info("stopped tracking failing backlog reads of \(gone.sorted().joined(separator: ", ")): no longer configured") }
    }
}
