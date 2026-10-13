import ArgumentParser
import Foundation
import LoopWorkerCore

@main
struct LoopWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loopworker",
        abstract: "Claims cards from a backlog and runs one claude worker per card.",
        discussion: "State lives in $LOOPWORKER_HOME (default ~/.loopworker).",
        version: loopworkerVersion,
        subcommands: [Run.self, Status.self, Pause.self, Resume.self, Version.self],
        defaultSubcommand: Run.self)
}

/// Prints `message` to stderr and returns the failure exit code to throw.
func fail(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("loopworker: \(message)\n".utf8))
    return .failure
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the Manager (the default). SIGINT drains, a second SIGINT or SIGTERM force-stops, a third SIGINT exits at once.")

    func run() async throws {
        let process = ProcessInfo.processInfo.environment
        let home = HostConfig.home(environment: process)
        let manager: Manager
        do {
            let environment = try Secrets.overlay(process, with: home.appending(path: "secrets.env"))
            let config = try HostConfig.load(home: home)
            manager = Manager(config: config, dependencies: try makeDependencies(config: config, environment: environment))
        } catch {
            throw fail("\(error)")
        }
        let signals = SignalHandlers(manager)
        do { try await manager.run() }
        catch { throw fail("\(error)") }
        withExtendedLifetime(signals) {}
    }
}

/// Routes SIGINT and SIGTERM to the Manager instead of the default handlers, and ignores SIGPIPE.
final class SignalHandlers: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ manager: Manager) {
        let queue = DispatchQueue(label: "loopworker.signals")
        // A closed stdout (a dead `tee`, a closed terminal) must not kill the daemon mid-stop.
        signal(SIGPIPE, SIG_IGN)
        sources = [(SIGINT, StopRequest.interrupt), (SIGTERM, StopRequest.terminate)].map { signo, request in
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler {
                Task {
                    if await manager.handle(request) == .exitNow { exit(130) }
                }
            }
            source.resume()
            return source
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show what the Manager is doing. Exits 1 when no healthy Manager runs.")

    @Flag(help: "Print state/status.json as is.")
    var json = false

    func run() throws {
        let state = HostConfig.home().appending(path: "state")
        let file = ManagerStatus.file(stateDir: state)
        let holder = ManagerLock.holder(at: ManagerLock.file(stateDir: state))
        var status: ManagerStatus?
        if FileManager.default.fileExists(atPath: file.path) {
            do { status = try ManagerStatus.read(from: file) }
            catch { throw fail("\(file.path) is not a status file this version can read: \(error)") }
        }
        let report = StatusReport.render(status, lockHolder: holder, now: Date())
        guard json else {
            print(report.text, terminator: "")
            if !report.running { throw ExitCode.failure }
            return
        }
        if let data = FileManager.default.contents(atPath: file.path) { FileHandle.standardOutput.write(data) }
        if !report.running { throw fail(String(report.text.prefix { $0 != "\n" })) }
    }
}

/// The PAUSED file for `project` (a path or key from config.toml), or the host's when nil.
func killSwitch(_ project: String?) throws -> URL {
    let home = HostConfig.home()
    let state = home.appending(path: "state")
    guard let project else { return KillSwitch.file(stateDir: state) }
    let key = ProjectSpec(path: project).key
    let config: HostConfig
    do { config = try HostConfig.load(home: home) }
    catch { throw fail("\(error)") }
    guard config.projects.contains(where: { $0.key == key }) else {
        throw fail("no project \(project) in \(home.appending(path: "config.toml").path); configured: \(config.projects.map(\.path).joined(separator: ", "))")
    }
    return KillSwitch.file(stateDir: state, projectKey: key)
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop new claims for the host or one project. Running workers finish.")

    @Argument(help: "A project path from config.toml; omit to pause the whole host.")
    var project: String?

    func run() throws {
        let file = try killSwitch(project)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        } catch {
            throw fail("can't create \(file.path): \(error.localizedDescription)")
        }
        print("paused \(project ?? "the host"): no new claims until `loopworker resume\(project.map { " \($0)" } ?? "")`")
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo `loopworker pause`.")

    @Argument(help: "A project path from config.toml; omit to resume the whole host.")
    var project: String?

    func run() throws {
        let file = try killSwitch(project)
        guard FileManager.default.fileExists(atPath: file.path) else {
            print("\(project ?? "the host") was not paused")
            return
        }
        do { try FileManager.default.removeItem(at: file) }
        catch { throw fail("can't remove \(file.path): \(error.localizedDescription)") }
        print("resumed \(project ?? "the host")")
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the version.")
    func run() { print(loopworkerVersion) }
}
