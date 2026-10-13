import Foundation

/// The Manager's log: `<ISO 8601 UTC time> <LEVEL> <message>` lines, redacted, appended to a
/// rotating file and optionally echoed to stdout. A multi-line message becomes one prefixed
/// line per message line.
public final class FileLogSink: LogSink, @unchecked Sendable {
    private let file: URL
    private let echo: Bool
    private let secrets: [String]
    private let maxBytes: Int
    private let backups: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private var recent: [String] = []
    private var reportedFailure = false

    /// - Parameters:
    ///   - file: The log file, typically `state/manager.log`. Parent directories are created.
    ///     When a write would grow it past `maxBytes`, it is renamed to `<file>.1` (shifting
    ///     older backups up and dropping the one past `backups`) and a new file is started.
    ///   - echo: Also write each line to stdout, unbuffered.
    ///   - secrets: Literal values (the configured backlog and forge tokens) to redact in
    ///     addition to `Redactor`'s patterns.
    ///   - maxBytes: Rotation threshold, 10 MB by default.
    ///   - backups: How many rotated files to keep, 5 by default.
    public init(file: URL, echo: Bool, secrets: [String] = [], maxBytes: Int = 10 << 20, backups: Int = 5) {
        self.file = file
        self.echo = echo
        self.secrets = secrets
        self.maxBytes = maxBytes
        self.backups = backups
    }

    /// Writes `message` at `level`. Never throws: the first file write failure goes to stderr,
    /// later ones are silent, and every write retries opening the file.
    public func log(_ level: LogLevel, _ message: String) {
        let prefix = "\(Date().formatted(.iso8601)) \(level.rawValue.uppercased()) "
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map {
            prefix + Redactor.redact(String($0), literals: secrets)
        }
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        lock.withLock {
            recent.append(contentsOf: lines)
            if recent.count > 200 { recent.removeFirst(recent.count - 200) }
            if echo { FileHandle.standardOutput.write(data) }
            do {
                try write(data)
            } catch {
                handle = nil
                if !reportedFailure {
                    reportedFailure = true
                    FileHandle.standardError.write(Data("loopworker: can't write log file \(file.path): \(error)\n".utf8))
                }
            }
        }
    }

    /// The last 200 lines written, redacted and prefixed, oldest first. For the status file.
    public func recentLines() -> [String] {
        lock.withLock { recent }
    }

    private func write(_ data: Data) throws {
        if handle == nil { try openFile() }
        if size > 0 && size + data.count > maxBytes {
            try handle?.close()
            handle = nil
            try rotate()
            try openFile()
        }
        try handle?.write(contentsOf: data)
        size += data.count
    }

    private func openFile() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    }

    private func rotate() throws {
        let manager = FileManager.default
        func backup(_ n: Int) -> String { "\(file.path).\(n)" }
        if manager.fileExists(atPath: backup(backups)) { try manager.removeItem(atPath: backup(backups)) }
        for n in stride(from: backups - 1, through: 1, by: -1) where manager.fileExists(atPath: backup(n)) {
            try manager.moveItem(atPath: backup(n), toPath: backup(n + 1))
        }
        try manager.moveItem(atPath: file.path, toPath: backup(1))
    }
}
