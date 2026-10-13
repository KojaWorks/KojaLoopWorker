import Foundation

public enum LogLevel: String, Sendable, Codable {
    case debug, info, warning, error
}

/// Where every component writes its log lines. The implementation redacts each line before
/// it reaches any output (file, stdout, status file), so callers may log raw script output.
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

extension LogSink {
    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }
}
