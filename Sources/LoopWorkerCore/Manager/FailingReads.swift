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

/// The backlog reads that are failing, per read and project, and the alerts open for them.
/// Pure: the Manager feeds it every read's result and sends the alerts that it returns.
///
/// Failures with the same error text share one alert, since one root cause (a rejected query,
/// a revoked token) fails every read and project at once.
struct FailingReads {
    /// A read that has failed for this long without a success is alerted. A failure that comes
    /// longer than this after the previous one starts a new run, since the read wasn't retried
    /// meanwhile (fill skips reads while paused, draining or at capacity).
    static let alertAfter: TimeInterval = 600

    struct Key: Hashable, Comparable {
        var read: BacklogRead
        var project: String
        static func < (a: Key, b: Key) -> Bool { (a.read.rawValue, a.project) < (b.read.rawValue, b.project) }
    }

    struct Failure: Equatable {
        /// The first failure of the current run of failures.
        var since: Date
        var lastFailed: Date
        /// The latest failure's error, redacted.
        var error: String
        /// The failure belongs to an open alert.
        var alerted = false
    }

    /// One alert for the failures that had `error` when it opened, and those that later fail
    /// with the same error.
    struct Alert: Equatable {
        var error: String
        /// The earliest `since` of its failures.
        var since: Date
        /// The failures that it covers and that haven't recovered.
        var keys: Set<Key>
        /// Every failure that it ever covered, for the recovery message.
        var covered: Set<Key>
    }

    private(set) var failing: [Key: Failure] = [:]
    /// Open alerts by error text.
    private(set) var alerts: [String: Alert] = [:]

    /// Records that `read` failed for `projects`. A failure that has now failed for
    /// `alertAfter` joins the open alert for its error, or opens one that covers every
    /// unalerted failure with that error.
    /// - Returns: The alert that opened just now, or nil.
    mutating func failed(_ read: BacklogRead, projects: [String], error: String, at now: Date) -> Alert? {
        var opened: Alert?
        for project in projects {
            let key = Key(read: read, project: project)
            var f = failing[key] ?? Failure(since: now, lastFailed: now, error: error)
            if !f.alerted && now.timeIntervalSince(f.lastFailed) > Self.alertAfter { f.since = now }
            f.lastFailed = now
            f.error = error
            failing[key] = f
            guard !f.alerted, now.timeIntervalSince(f.since) >= Self.alertAfter else { continue }
            if alerts[error] != nil {
                cover([key], by: error)
            } else {
                let keys = failing.filter { !$0.value.alerted && $0.value.error == error }.map(\.key)
                alerts[error] = Alert(error: error, since: keys.map { failing[$0]!.since }.min()!, keys: [], covered: [])
                cover(keys, by: error)
                opened = alerts[error]
            }
        }
        return opened
    }

    /// Clears the failures of `read` for `projects`.
    /// - Returns: The alerts whose failures have now all recovered.
    mutating func succeeded(_ read: BacklogRead, projects: [String]) -> [Alert] {
        for project in projects { failing[Key(read: read, project: project)] = nil }
        return closeRecovered()
    }

    /// Forgets the failures of projects that are no longer configured, which no read clears.
    /// - Returns: The forgotten projects, and the alerts that closed because of it.
    mutating func prune(keeping projects: Set<String>) -> (gone: Set<String>, closed: [Alert]) {
        let gone = Set(failing.keys.map(\.project)).subtracting(projects)
        failing = failing.filter { !gone.contains($0.key.project) }
        return (gone, closeRecovered())
    }

    private mutating func cover(_ keys: [Key], by error: String) {
        for key in keys {
            failing[key]!.alerted = true
            alerts[error]!.keys.insert(key)
            alerts[error]!.covered.insert(key)
            alerts[error]!.since = min(alerts[error]!.since, failing[key]!.since)
        }
    }

    private mutating func closeRecovered() -> [Alert] {
        var closed: [Alert] = []
        for (error, var alert) in alerts {
            alert.keys = alert.keys.filter { failing[$0] != nil }
            alerts[error] = alert
            if alert.keys.isEmpty {
                alerts[error] = nil
                closed.append(alert)
            }
        }
        return closed.sorted { $0.since < $1.since }
    }

    /// `workable for g/app, g/lib; working for g/app`.
    static func describe(_ keys: Set<Key>) -> String {
        Dictionary(grouping: keys.sorted(), by: \.read).sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) for \($0.value.map(\.project).joined(separator: ", "))" }
            .joined(separator: "; ")
    }
}

extension Manager {
    /// Records a failed backlog read and sends the alert that it opens, if any.
    func readFailed(_ read: BacklogRead, _ specs: [ProjectSpec], _ error: any Error) {
        let now = clock.now()
        guard let alert = failingReads.failed(read, projects: specs.map(\.path), error: deps.redact("\(error)"), at: now) else { return }
        let summary = "backlog reads failing since \(StatusReport.stamp(alert.since)) (\(StatusReport.duration(now.timeIntervalSince(alert.since)))): \(FailingReads.describe(alert.keys)): \(alert.error)"
        log.error("\(summary); retrying, and alerting again only after they recover")
        notify(key: "backlog-read \(alert.error)", "LoopWorker on \(hostName): \(summary). Run `loopworker doctor` to see which project's query fails.")
    }

    /// Clears a backlog read's failures for `specs` and sends a recovery for each alert that closes.
    func readSucceeded(_ read: BacklogRead, _ specs: [ProjectSpec]) {
        for alert in failingReads.succeeded(read, projects: specs.map(\.path)) {
            let summary = "backlog reads recovered after failing for \(StatusReport.duration(clock.now().timeIntervalSince(alert.since))): \(FailingReads.describe(alert.covered))"
            log.info(summary)
            notify(key: "backlog-read-recovered \(alert.error)", "LoopWorker on \(hostName): \(summary)")
        }
    }

    /// Drops failing reads of projects that left the config, since no read clears them any more.
    func pruneFailingReads() {
        let (gone, closed) = failingReads.prune(keeping: Set(order.compactMap { projects[$0]?.spec.path }))
        guard !gone.isEmpty else { return }
        log.info("stopped tracking failing backlog reads of \(gone.sorted().joined(separator: ", ")): no longer configured")
        for alert in closed {
            log.warning("closed the backlog read alert for \"\(alert.error)\" without a recovery: its failing projects left the config")
        }
    }
}
