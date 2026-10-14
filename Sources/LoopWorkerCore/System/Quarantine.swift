import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS's download quarantine on host tools. Gatekeeper asks the user before a quarantined
/// binary first runs; on a host where the Manager's user has no GUI session nobody can answer,
/// so macOS kills the process with SIGKILL.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// Why a quarantined tool dies, for a log line or a doctor detail.
    public static let why = "Gatekeeper can't show its first-launch prompt without a GUI session, so macOS kills the process"

    /// The command that clears the quarantine from `file`.
    public static func remedy(_ file: URL) -> String { "xattr -d \(attribute) \(file.path)" }

    /// True when `file` carries `com.apple.quarantine`. Reads the attribute of `file` itself,
    /// not of a symlink's target; resolve first. Always false off Darwin.
    @Sendable public static func isFlagged(_ file: URL) -> Bool {
        #if canImport(Darwin)
        getxattr(file.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        #else
        false
        #endif
    }

    /// The first executable `tool` in the colon-separated `path`, with symlinks resolved, or nil.
    public static func resolve(_ tool: String, path: String) -> URL? {
        path.split(separator: ":").lazy
            .map { URL(filePath: String($0)).appending(path: tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            .map { $0.resolvingSymlinksInPath() }
    }
}
