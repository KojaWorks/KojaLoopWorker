import Foundation

/// A value guarded by a lock, so fakes can be configured synchronously from tests and still
/// be `Sendable`.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func callAsFunction<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var get: Value { self { $0 } }
}

struct FakeError: Error, CustomStringConvertible, Equatable {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Holds every `wait()` until `open()`, so a test can stop a fake mid-call.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0

    /// How many calls have reached `wait()`.
    var waiting: Int { lock.withLock { arrived } }

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            arrived += 1
            if isOpen { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }
}

/// Yields until `condition` holds, failing the test after `tries` yields.
func until(_ tries: Int = 10_000, _ condition: () -> Bool) async throws {
    for _ in 0..<tries where !condition() { await Task.yield() }
    if !condition() { throw FakeError("condition never held") }
}
