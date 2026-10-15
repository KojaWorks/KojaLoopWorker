import ArgumentParser
import Foundation
import LoopWorkerCore

struct Prompt: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prints instructions for a coding agent to set up LoopWorker on this host, with this host's context.")

    func run() {
        let environment = ProcessInfo.processInfo.environment
        let home = HostConfig.home(environment: environment)
        let context = PromptContext(
            version: loopworkerVersion, binary: invokedBinaryPath(), home: home,
            homeFromEnvironment: !(environment["LOOPWORKER_HOME"] ?? "").isEmpty, environment: environment,
            managerPid: ManagerLock.holder(at: ManagerLock.file(stateDir: home.appending(path: "state"))),
            credentialVariables: { try credentialVariables(config: $0) })
        print(context.render(), terminator: "")
    }
}

/// The facts about this host that `loopworker prompt` prints before its instructions (B200).
/// `render()` reads only `config.toml` and `secrets.env` under `home`, never throws, does no
/// network I/O and never prints a value from `secrets.env`.
struct PromptContext {
    var version: String
    /// The path of the running `loopworker` binary.
    var binary: String
    /// `$LOOPWORKER_HOME`, resolved.
    var home: URL
    /// Whether `home` came from `LOOPWORKER_HOME` rather than the default.
    var homeFromEnvironment: Bool
    /// The process environment; only consulted for whether a credential variable is set in it.
    var environment: [String: String]
    /// The pid of the Manager that holds the lock on `home`, 0 when one holds it without a
    /// readable pid, or nil when none does.
    var managerPid: Int32?
    /// The variables that the configured backends read their tokens from.
    var credentialVariables: (HostConfig) throws -> [String]

    func render() -> String {
        var lines = ["# Context, computed by loopworker \(version)", ""]
        lines.append("- Binary: \(binary)")
        lines.append("- LOOPWORKER_HOME: \(home.path) (\(homeFromEnvironment ? "from the environment" : "the default; LOOPWORKER_HOME is not set"))")

        let configFile = home.appending(path: "config.toml")
        var config: HostConfig?
        if !FileManager.default.fileExists(atPath: configFile.path) {
            lines.append("- config.toml: missing (\(configFile.path))")
        } else {
            do {
                let loaded = try HostConfig.load(home: home)
                config = loaded
                lines.append("- config.toml: valid (\(configFile.path)); backlog `\(loaded.backlogKind)`, forge `\(loaded.forgeKind)`")
                if loaded.projects.isEmpty { lines.append("  - no `[[project]]` yet") }
                for p in loaded.projects {
                    lines.append("  - project `\(p.path)`: \(p.slots) slot\(p.slots == 1 ? "" : "s"), \(p.hot ? "hot" : "cold")")
                }
            } catch {
                lines.append("- config.toml: invalid (\(configFile.path)): \(error)")
            }
        }

        lines += secretsLines(config: config)

        switch managerPid {
        case nil: lines.append("- Manager: none runs on this home")
        case 0?: lines.append("- Manager: one runs on this home (pid unknown); don't start another")
        case let pid?: lines.append("- Manager: one runs on this home, pid \(pid); don't start another")
        }
        return (lines + ["", ""]).joined(separator: "\n")
    }

    private func secretsLines(config: HostConfig?) -> [String] {
        let file = home.appending(path: "secrets.env")
        var lines: [String] = []
        var inFile: [String: Bool] = [:]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let octal = String(mode, radix: 8)
            lines.append(mode & 0o044 != 0
                ? "- secrets.env: mode \(octal) (\(file.path)); group or others can read it, so the Manager refuses to start. Run `chmod 600 \(file.path)`."
                : "- secrets.env: mode \(octal) (\(file.path))")
            do { inFile = Self.secretNames(try String(contentsOf: file, encoding: .utf8)) }
            catch { lines.append("  - can't read it: \(error.localizedDescription)") }
        } else {
            lines.append("- secrets.env: missing (\(file.path))")
        }

        var names: [String] = []
        switch config.map({ c in Result { try credentialVariables(c) } }) {
        case nil:
            lines.append("  - the backend token variables follow from config.toml, which isn't valid yet")
        case .failure(let error)?:
            lines.append("  - can't tell which variables the config needs: \(error)")
        case .success(let backend)?:
            names = backend
        }
        for name in Set(names).sorted() + ["CLAUDE_CODE_OAUTH_TOKEN"] {
            var state = switch inFile[name] {
            case true?: "set in secrets.env"
            case false?: "empty in secrets.env"
            case nil: "not in secrets.env"
            }
            if inFile[name] != true, !(environment[name] ?? "").isEmpty {
                state += "; set in this shell only, which a launchd service doesn't see"
            }
            lines.append("  - \(name): \(state)")
        }
        return lines
    }

    /// Each `NAME=value` line's name in `secrets.env` text, mapped to whether its value is
    /// non-empty, judged the way `Secrets.load` trims it. Values are not kept.
    static func secretNames(_ text: String) -> [String: Bool] {
        var names: [String: Bool] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            names[line[..<eq].trimmingCharacters(in: .whitespaces)] = !["", "\"\"", "''"].contains(rest)
        }
        return names
    }
}
