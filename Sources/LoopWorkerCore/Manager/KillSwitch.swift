import Foundation

/// The PAUSED files that stop new claims while running workers finish. A file may hold the
/// reason for the pause; `loopworker resume` deletes it.
public enum KillSwitch {
    /// `state/PAUSED` for the whole host, or `state/projects/<key>/PAUSED` for one project.
    public static func file(stateDir: URL, projectKey: String? = nil) -> URL {
        guard let key = projectKey else { return stateDir.appending(path: "PAUSED") }
        return stateDir.appending(path: "projects/\(key)/PAUSED")
    }

    /// Creates or overwrites the PAUSED file with `reason` (empty for none).
    /// - Throws: the file system error, when the file can't be written.
    public static func pause(_ file: URL, reason: String = "") throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(reason.utf8).write(to: file, options: .atomic)
    }

    /// The reason in the PAUSED file, trimmed; nil when the file is missing, unreadable or empty.
    public static func reason(_ file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
