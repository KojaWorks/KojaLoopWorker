import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The process could not be started at all (missing binary, bad working directory).
public struct ProcessStartError: Error, CustomStringConvertible {
    public var executable: String
    public var workingDirectory: URL?
    /// The `errno` value that `posix_spawnp` (or the pipe setup before it) returned.
    public var code: Int32

    public var description: String {
        let directory = workingDirectory.map { " in \($0.path)" } ?? ""
        return "could not start \(executable)\(directory): \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// `ProcessRunning` on `posix_spawnp`, which (unlike Foundation's `Process`) can put the child
/// in its own process group.
///
/// The executable is looked up on the Manager's own `PATH`, not on a `PATH` set in
/// `ProcessSpec.environment`. Output lines go to `onLine` on a private serial queue.
public struct ProcessRunner: ProcessRunning {
    private let secrets: [String]
    /// How long `run` keeps reading after the child exits, for output still in the pipe.
    let drainLimit: Duration

    /// - Parameter secrets: Literal values (the configured backlog and forge tokens) that
    ///   `Redactor` scrubs from `onLine` lines in addition to its patterns.
    public init(secrets: [String] = []) {
        self.init(secrets: secrets, drainLimit: .seconds(5))
    }

    init(secrets: [String] = [], drainLimit: Duration) {
        self.secrets = secrets
        self.drainLimit = drainLimit
    }

    public func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        try Task.checkCancellation()
        let (pid, fd) = try spawn(spec)
        let execution = Execution(pid: pid, fd: fd, spec: spec, secrets: secrets, drainLimit: drainLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: {
            execution.cancel()
        }
    }

    private func spawn(_ spec: ProcessSpec) throws -> (pid_t, Int32) {
        let fail = { (code: Int32) in
            ProcessStartError(executable: spec.executable, workingDirectory: spec.workingDirectory, code: code)
        }
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
        // No pipe2 on Darwin; POSIX_SPAWN_CLOEXEC_DEFAULT below keeps these out of other children.
        guard pipe(&fds) == 0 else { throw fail(errno) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        #else
        guard pipe2(&fds, O_CLOEXEC) == 0 else { throw fail(errno) }
        #endif
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(writeEnd) }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        if let directory = spec.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Ignored signals survive exec; the Manager ignores SIGINT for its own signal handling.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var environment = ProcessInfo.processInfo.environment
        for (name, value) in spec.environment { environment[name] = value }
        environment["GIT_TERMINAL_PROMPT"] = "0"

        let argv = CStrings([spec.executable] + spec.arguments)
        let envp = CStrings(environment.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let code = withExtendedLifetime((argv, envp)) {
            posix_spawnp(&pid, spec.executable, &actions, &attributes, argv.pointers, envp.pointers)
        }
        guard code == 0 else {
            close(readEnd)
            throw fail(code)
        }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
        return (pid, readEnd)
    }
}

/// A NULL-terminated `char *[]` that lives as long as this object.
private final class CStrings {
    let pointers: [UnsafeMutablePointer<CChar>?]
    init(_ strings: [String]) { pointers = strings.map { strdup($0) } + [nil] }
    deinit { pointers.forEach { free($0) } }
}

/// One running child. Every mutable property is touched only on `queue`.
private final class Execution: @unchecked Sendable {
    let pid: pid_t
    let fd: Int32
    let spec: ProcessSpec
    let secrets: [String]
    let drainLimit: Duration
    let queue = DispatchQueue(label: "loopworker.process")

    var continuation: CheckedContinuation<ProcessResult, Error>?
    var source: DispatchSourceRead?
    var timeout: DispatchWorkItem?
    var output = Data()
    var partialLine = Data()
    var status: Int32?
    var reachedEOF = false
    var timedOut = false
    var cancelled = false
    var finished = false

    init(pid: pid_t, fd: Int32, spec: ProcessSpec, secrets: [String], drainLimit: Duration) {
        self.pid = pid
        self.fd = fd
        self.spec = spec
        self.secrets = secrets
        self.drainLimit = drainLimit
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()

            let timeout = DispatchWorkItem { [self] in
                guard status == nil, !finished else { return }
                timedOut = true
                killpg(pid, SIGKILL)
            }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + spec.timeout.timeInterval, execute: timeout)

            // waitpid blocks, so it gets its own thread rather than a cooperative-pool one.
            Thread { [self] in
                let status = waitForExit()
                queue.async { [self] in exited(status) }
            }.start()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            cancelled = true
            killpg(pid, SIGKILL)
            if status != nil { finish() }
        }
    }

    private func waitForExit() -> Int32 {
        var raw: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR
        guard result == pid else { return -1 }
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : -signal
    }

    private func exited(_ status: Int32) {
        self.status = status
        if reachedEOF || cancelled {
            finish()
        } else {
            // A grandchild may hold the pipe open indefinitely; stop reading after the drain.
            queue.asyncAfter(deadline: .now() + drainLimit.timeInterval) { [self] in finish() }
        }
    }

    private func readAvailable() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                consume(buffer[0..<count])
            } else if count == -1 && errno == EINTR {
                continue
            } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                reachedEOF = true
                source?.cancel()
                if status != nil { finish() }
                return
            }
        }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        output.append(contentsOf: bytes)
        guard spec.onLine != nil else { return }
        partialLine.append(contentsOf: bytes)
        while let newline = partialLine.firstIndex(of: 0x0A) {
            deliver(partialLine[partialLine.startIndex..<newline])
            partialLine = Data(partialLine[(newline + 1)...])
        }
    }

    private func deliver(_ line: Data) {
        var text = String(decoding: line, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        spec.onLine?(Redactor.redact(text, literals: secrets))
    }

    private func finish() {
        guard !finished, let status, let continuation else { return }
        finished = true
        timeout?.cancel()
        source?.cancel()
        if !partialLine.isEmpty && !cancelled { deliver(partialLine) }
        self.continuation = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(returning: ProcessResult(
                status: status, output: String(decoding: output, as: UTF8.self), timedOut: timedOut))
        }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
