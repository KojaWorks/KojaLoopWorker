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
