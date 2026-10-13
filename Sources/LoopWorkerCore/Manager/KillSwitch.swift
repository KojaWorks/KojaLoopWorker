import Foundation

/// The PAUSED files that stop new claims while running workers finish.
public enum KillSwitch {
    /// `state/PAUSED` for the whole host, or `state/projects/<key>/PAUSED` for one project.
    public static func file(stateDir: URL, projectKey: String? = nil) -> URL {
        guard let key = projectKey else { return stateDir.appending(path: "PAUSED") }
        return stateDir.appending(path: "projects/\(key)/PAUSED")
    }
}
