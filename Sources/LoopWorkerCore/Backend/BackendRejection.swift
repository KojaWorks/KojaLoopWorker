import Foundation

/// A backlog or forge refused a request in a way that retrying won't fix (an HTTP 4xx other
/// than 401, 403, 408 and 429: a title too long, a branch that doesn't exist). Backends throw
/// it so that the Manager can turn a finish that will never succeed into a stuck card instead
/// of retrying forever. Everything else that a backend throws is treated as transient.
public struct BackendRejection: Error, CustomStringConvertible, Equatable {
    /// What was refused and why, e.g. "POST /projects/12/merge_requests: 422 title is too long".
    public var description: String
    public init(_ description: String) { self.description = description }
}
