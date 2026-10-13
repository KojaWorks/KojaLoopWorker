import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `state/manager.lock`: one Manager per home. The file holds the owner's pid and an
/// exclusive `flock` for the owner's lifetime, so the kernel drops the lock when the owner
/// dies however it dies, and a reused pid can't keep a dead Manager's lock alive.
public final class ManagerLock: @unchecked Sendable {
    public struct Held: Error, CustomStringConvertible {
        public var pid: Int32?
        public var file: URL
        public var description: String {
            "another Manager (pid \(pid.map(String.init) ?? "unknown")) holds \(file.path); stop it first"
        }
    }

    public let file: URL
    private let lock = NSLock()
    private var fd: Int32

    private init(file: URL, fd: Int32) {
        self.file = file
        self.fd = fd
    }

    /// Takes the lock and writes this process's pid into it. A lock file left by a Manager
    /// that is no longer running is taken over with a warning.
    /// - Throws: `Held` naming the holder's pid and the file when a live Manager holds it,
    ///   or `ConfigError` when the file can't be opened.
    public static func acquire(at file: URL, log: any LogSink) throws -> ManagerLock {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw ConfigError("can't open \(file.path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let pid = readPid(fd)
            close(fd)
            throw Held(pid: pid, file: file)
        }
        if let old = readPid(fd), old != getpid() {
            log.warning("took over \(file.path) from pid \(old), which no longer holds it")
        }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return ManagerLock(file: file, fd: fd)
    }

    /// The pid of the Manager holding the lock at `file`, or nil when no live Manager holds
    /// it. Returns 0 when it is held but the file has no readable pid.
    public static func holder(at file: URL) -> Int32? {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return readPid(fd) ?? 0
    }

    /// Removes the file and drops the lock. Safe to call more than once and from a signal
    /// handler's queue.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        unlink(file.path)
        close(fd)
        fd = -1
    }

    deinit { release() }

    private static func readPid(_ fd: Int32) -> Int32? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        return Int32(String(decoding: buf[..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
