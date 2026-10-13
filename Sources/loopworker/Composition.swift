import Foundation
import LoopWorkerCore

struct BackendsNotWired: Error, CustomStringConvertible {
    var description: String { "backends are not wired into this build" }
}

/// Builds the Manager's dependencies from the host config.
/// - Parameter environment: the process environment with `secrets.env` overlaid; the backends
///   read their tokens from it, and it becomes `ManagerDependencies.environment`.
func makeDependencies(config: HostConfig, environment: [String: String]) throws -> ManagerDependencies {
    throw BackendsNotWired()
}
