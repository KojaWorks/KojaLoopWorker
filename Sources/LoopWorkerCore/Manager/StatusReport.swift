import Foundation

/// What `loopworker status` prints.
public enum StatusReport {
    /// A status file older than this, while a Manager holds the lock, means it is wedged.
    public static let staleAfter: TimeInterval = 60

    /// Renders the status for a human.
    /// - Parameters:
    ///   - status: the decoded status file, or nil when it is missing or unreadable.
    ///   - lockHolder: `ManagerLock.holder(at:)`: the live Manager's pid, or nil when none runs.
    /// - Returns: the text, and whether a healthy Manager is running.
    public static func render(_ status: ManagerStatus?, lockHolder: Int32?, now: Date) -> (text: String, running: Bool) {
        var lines: [String] = []
        var running = true
        if lockHolder == nil {
            lines.append("The Manager is not running.")
            running = false
            if let status { lines.append("Its last status, from \(stamp(status.updated)):") }
        } else if let status, now.timeIntervalSince(status.updated) > staleAfter {
            lines.append("The Manager (pid \(lockHolder!)) looks wedged: its status was last updated at \(stamp(status.updated)), \(duration(now.timeIntervalSince(status.updated))) ago.")
            running = false
        } else if status == nil {
            lines.append("The Manager (pid \(lockHolder!)) has not written its status yet.")
        }
        if let status { lines += summary(status, now: now) }
        return (lines.joined(separator: "\n") + "\n", running)
    }

    static func summary(_ s: ManagerStatus, now: Date) -> [String] {
        var out: [String] = []
        let flags = (s.paused ? ", PAUSED" : "") + (s.draining ? ", draining" : "")
        out.append("LoopWorker \(s.version) on \(s.host), pid \(s.pid), up \(duration(s.updated.timeIntervalSince(s.started)))\(flags)")
        var auth = "auth: \(s.auth.state)"
        if let detail = s.auth.detail { auth += " (\(detail))" }
        if let until = s.auth.backoffUntil, until > now { auth += ", claims paused until \(stamp(until))" }
        out.append(auth)
        if s.projects.isEmpty { out.append("no projects configured") }
        for p in s.projects {
            var head = "\(p.path) (\(p.hot ? "hot" : "cold")"
            if !p.ready { head += ", not ready" }
            if p.paused { head += ", paused" }
            if p.removing { head += ", removing" }
            head += ")"
            if let error = p.error { head += ": \(error)" }
            out.append(head)
            for slot in p.slots {
                var line = "  slot \(slot.index): \(slot.state)"
                if let card = slot.card { line += " \(card)" }
                if let branch = slot.branch { line += " on \(branch)" }
                if let t = slot.runningFor { line += " for \(duration(t))" }
                if let task = slot.task { line += ", \(task)" }
                if slot.finishFailing { line += ", FINISH FAILING" }
                if slot.retiring { line += ", retiring" }
                out.append(line)
                if let error = slot.lastError { out.append("    last error: \(error)") }
                if let last = slot.pane.last { out.append("    > \(last)") }
            }
        }
        if let ci = s.ci, !ci.isEmpty {
            out.append("waiting for CI or merge:")
            for c in ci {
                out.append("  \(c.card) round \(c.round) at \(c.commit): \(c.state), pushed \(duration(now.timeIntervalSince(c.since))) ago, \(c.url.absoluteString)")
            }
        }
        if let held = s.held, !held.isEmpty {
            out.append("held by other Managers (if one is gone for good, move its cards back to ready):")
            for h in held { out.append("  \(h.card) (\(h.state)) held by \(h.holder)") }
        }
        if !s.log.isEmpty {
            out.append("recent log:")
            out += s.log.suffix(10).map { "  \($0)" }
        }
        return out
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        return "\(t / 3600)h \(String(format: "%02d", t % 3600 / 60))m"
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
