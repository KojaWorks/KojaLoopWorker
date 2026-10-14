import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS's download quarantine on host tools. Gatekeeper asks the user before a quarantined
/// binary first runs; on a host where the Manager's user has no GUI session nobody can answer,
/// so macOS kills the process with SIGKILL. Once a user approves the binary, Gatekeeper keeps
/// the attribute and sets `approvedFlag` in its value (`0181;...` becomes `01c3;...`).
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"
    /// The bit in the attribute's leading hex flags that marks a user-approved binary.
    public static let approvedFlag: UInt32 = 0x40

    /// Why a quarantined tool dies, for a log line or a doctor detail.
    public static let why = "Gatekeeper can't show its first-launch prompt without a GUI session, so macOS kills the process"

    /// The command that clears the quarantine from `file`.
    public static func remedy(_ file: URL) -> String { "xattr -d \(attribute) \(file.path)" }

    /// True when `file` carries `com.apple.quarantine` without `approvedFlag`, so macOS would
    /// ask before it runs. A value that can't be read or parsed counts as flagged. Reads the
    /// attribute of `file` itself, not of a symlink's target; resolve first. Always false off
    /// Darwin.
    @Sendable public static func isFlagged(_ file: URL) -> Bool {
        #if canImport(Darwin)
        let size = getxattr(file.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return false }
        var value = [UInt8](repeating: 0, count: size)
        let read = getxattr(file.path, attribute, &value, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else { return true }
        return blocksLaunch(String(decoding: value.prefix(read), as: UTF8.self))
        #else
        false
        #endif
    }

    /// False only when `value`, a `com.apple.quarantine` value such as `01c3;...`, starts with
    /// hex flags that have `approvedFlag` set.
    public static func blocksLaunch(_ value: String) -> Bool {
        guard let flags = value.split(separator: ";", omittingEmptySubsequences: false).first.flatMap({ UInt32($0, radix: 16) }) else {
            return true
        }
        return flags & approvedFlag == 0
    }

    /// The first executable `tool` in the colon-separated `path`, with symlinks resolved, or nil.
    public static func resolve(_ tool: String, path: String) -> URL? {
        path.split(separator: ":").lazy
            .map { URL(filePath: String($0)).appending(path: tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            .map { $0.resolvingSymlinksInPath() }
    }
}
