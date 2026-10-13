import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `state/manager.lock`: one Manager per home. The file holds the owner's pid and an
/// exclusive `flock` for the owner's lifetime, so the kernel drops the lock when the owner
/// dies however it dies, and a reused pid can't keep a dead Manager's lock alive. The file
/// itself stays after release: unlinking it would let a second Manager lock a fresh file
/// while a third still holds the old inode.
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

    /// `state/manager.lock` under `stateDir`.
    public static func file(stateDir: URL) -> URL { stateDir.appending(path: "manager.lock") }
    private var fd: Int32

    private init(file: URL, fd: Int32) {
        self.file = file
        self.fd = fd
    }

    /// Takes the lock and writes this process's pid into it. A lock file left by a Manager
    /// that has exited is normal and is taken over with an info line. Retries for up to 1 s,
    /// so a concurrent `holder(at:)` probe can't make a starting Manager fail.
    /// - Throws: `Held` naming the holder's pid and the file when a live Manager holds it,
    ///   or `ConfigError` when the file can't be opened.
    public static func acquire(at file: URL, log: any LogSink) throws -> ManagerLock {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // CLOEXEC: a child that inherits the fd (a tmux server lives on) would hold the lock.
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ConfigError("can't open \(file.path): \(String(cString: strerror(errno)))") }
        var locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        for _ in 0..<20 where !locked {
            usleep(50_000)
            locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        guard locked else {
            let pid = readPid(fd)
            close(fd)
            throw Held(pid: pid, file: file)
        }
        if let old = readPid(fd), old != getpid() {
            log.info("previous Manager pid \(old) has exited; taking over \(file.path)")
        }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return ManagerLock(file: file, fd: fd)
    }

    /// The pid of the Manager holding the lock at `file`, or nil when no live Manager holds
    /// it. Returns 0 when it is held but the file has no readable pid.
    public static func holder(at file: URL) -> Int32? {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Shared, so two probes don't collide; acquire retries past a probe that holds it.
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return readPid(fd) ?? 0
    }

    /// Drops the lock, leaving the file. Safe to call more than once and from a signal
    /// handler's queue.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
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
