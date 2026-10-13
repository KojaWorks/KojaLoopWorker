import Foundation
import GitHubBackend
import GitLabBackend
import LoopWorkerCore
import PatchBackend

struct CompositionError: Error, CustomStringConvertible {
    var description: String
}

/// Builds the Manager's dependencies from the host config.
/// - Parameter environment: the process environment with `secrets.env` overlaid; the backends
///   read their tokens from it, and it becomes `ManagerDependencies.environment`.
func makeDependencies(config: HostConfig, environment: [String: String]) throws -> ManagerDependencies {
    let secretNames = environment.keys.filter(looksSecret).sorted()
    let secrets = secretNames.compactMap { environment[$0] }.filter { $0.count >= 12 }
    try FileManager.default.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
    let fileLog = FileLogSink(file: config.stateDir.appending(path: "manager.log"), echo: true, secrets: secrets)
    let runner = ProcessRunner(secrets: secrets)

    let (backlog, forge) = try makeBackends(config: config, log: fileLog, environment: environment)
    let leaked = config.projects.flatMap { p in p.workerEnv.filter { secretNames.contains($0) && $0 != "CLAUDE_CODE_OAUTH_TOKEN" }.map { "\(p.path): \($0)" } }
    guard leaked.isEmpty else {
        throw CompositionError(description: "worker_env must not forward backlog or forge credentials to workers: \(leaked.joined(separator: ", "))")
    }

    let git = Git(runner: runner, log: fileLog)
    let notifier = Notifier(command: config.notifyCommand, runner: runner, log: fileLog)
    return ManagerDependencies(
        backlog: backlog,
        forge: forge,
        runner: runner,
        tmux: Tmux(runner: runner, socket: config.stateDir.appending(path: "tmux"), scrubbedVariables: secretNames),
        git: git,
        lifecycle: ScriptedSlotLifecycle(runner: runner, git: git, log: fileLog, gitRemote: { (forge.cloneURL(for: $0), forge.gitEnvironment()) }),
        engine: EngineRecovery(config: config.engine, runner: runner, log: fileLog,
                               notify: { message in Task { await notifier.send(key: "engine", message) } }),
        log: fileLog,
        recentLines: { fileLog.recentLines() },
        redact: { Redactor.redact($0, literals: secrets) },
        pane: PaneReading(showsAuthFailure: Pane.showsAuthFailure, showsTrustPrompt: Pane.showsTrustPrompt),
        environment: environment)
}

private func makeBackends(config: HostConfig, log: LogSink, environment: [String: String]) throws -> (any Backlog, any Forge) {
    let gitlab: (backlog: GitLabBacklog?, forge: GitLabForge?) = (config.backlogKind == "gitlab" || config.forgeKind == "gitlab")
        ? try GitLabBackend.make(config: config, log: log, environment: environment) : (nil, nil)
    let backlog: any Backlog
    switch config.backlogKind {
    case "gitlab": backlog = gitlab.backlog!
    case "patch": backlog = try PatchBackend.makeBacklog(config: config, log: log, environment: environment)
    default: throw CompositionError(description: "config.toml: unknown [backlog] kind \"\(config.backlogKind)\" (known: gitlab, patch)")
    }
    let forge: any Forge
    switch config.forgeKind {
    case "gitlab": forge = gitlab.forge!
    case "github": forge = try GitHubBackend.makeForge(config: config, log: log, environment: environment)
    default: throw CompositionError(description: "config.toml: unknown [forge] kind \"\(config.forgeKind)\" (known: gitlab, github)")
    }
    return (backlog, forge)
}

/// Variable names that carry credentials: they are redacted from every output and kept out
/// of the tmux server's environment.
private func looksSecret(_ name: String) -> Bool {
    let n = name.uppercased()
    return ["TOKEN", "SECRET", "PASSWORD", "_PAT", "_KEY"].contains { n.hasSuffix($0) || n.contains($0 + "_") }
        || n == "PATCH_PAT"
}
