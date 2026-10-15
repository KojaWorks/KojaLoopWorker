import Foundation

/// `state/status.json`: the Manager's state, rewritten atomically every tick. `loopworker
/// status` and any future app decode this type. Every string in it is redacted.
public struct ManagerStatus: Codable, Sendable, Equatable {
    public var version: String
    public var pid: Int32
    public var host: String
    public var started: Date
    public var updated: Date
    /// `state/PAUSED` exists: no new claims host-wide.
    public var paused: Bool
    /// The first SIGINT arrived: no new claims, exit when no worker runs.
    public var draining: Bool
    public var auth: Auth
    public var projects: [Project]
    /// Cards in `verifying` whose CI the Manager watches, oldest push first. Nil from a
    /// Manager that predates CI watching.
    public var ci: [CI]?
    /// The most recent log lines, oldest first.
    public var log: [String]

    public struct Auth: Codable, Sendable, Equatable {
        /// `unknown` before the first preflight, then `ok` or `failing`.
        public var state: String
        /// Why the last preflight failed or was inconclusive, how many in a row, and when the
        /// next check runs; nil after an ok.
        public var detail: String?
        /// Dispatch is paused until then after auth releases (the circuit breaker).
        public var backoffUntil: Date?

        public init(state: String, detail: String? = nil, backoffUntil: Date? = nil) {
            self.state = state
            self.detail = detail
            self.backoffUntil = backoffUntil
        }
    }

    public struct Project: Codable, Sendable, Equatable {
        public var path: String
        public var key: String
        public var hot: Bool
        /// Cloned, contract loaded and base branch resolved.
        public var ready: Bool
        /// Why the project is not ready, or the last refresh failure.
        public var error: String?
        /// `state/projects/<key>/PAUSED` exists.
        public var paused: Bool
        /// Removed from the config; it serves no new cards and retires once its slots are idle.
        public var removing: Bool
        public var slots: [Slot]

        public init(path: String, key: String, hot: Bool, ready: Bool, error: String?, paused: Bool, removing: Bool, slots: [Slot]) {
            self.path = path
            self.key = key
            self.hot = hot
            self.ready = ready
            self.error = error
            self.paused = paused
            self.removing = removing
            self.slots = slots
        }
    }

    public struct Slot: Codable, Sendable, Equatable {
        public var index: Int
        /// `idle`, `busy` or `broken`.
        public var state: String
        /// The task running on the slot (`preparing`, `starting`, `finishing`, `releasing`,
        /// `recycling`, `retiring`), or nil.
        public var task: String?
        public var card: String?
        public var cardURL: URL?
        public var branch: String?
        /// Seconds since the worker was spawned.
        public var runningFor: Double?
        public var lastError: String?
        public var port: Int
        /// The last lines of the worker's pane.
        public var pane: [String]
        /// Three or more finish attempts in a row failed; a human should look at the log.
        public var finishFailing: Bool
        /// Shrunk out of its pool; retired after its card.
        public var retiring: Bool

        public init(
            index: Int, state: String, task: String? = nil, card: String? = nil, cardURL: URL? = nil,
            branch: String? = nil, runningFor: Double? = nil, lastError: String? = nil, port: Int,
            pane: [String] = [], finishFailing: Bool = false, retiring: Bool = false
        ) {
            self.index = index
            self.state = state
            self.task = task
            self.card = card
            self.cardURL = cardURL
            self.branch = branch
            self.runningFor = runningFor
            self.lastError = lastError
            self.port = port
            self.pane = pane
            self.finishFailing = finishFailing
            self.retiring = retiring
        }
    }

    public struct CI: Codable, Sendable, Equatable {
        public var card: String
        public var cardURL: URL?
        /// 0 for the first push, n after the n-th fix round.
        public var round: Int
        /// The first 12 characters of the pushed commit.
        public var commit: String
        /// `no pipeline yet`, `running`, `passed`, `failed`, `canceled`, `fix queued`, `fix starting`,
        /// `merging` (a merge is in flight or due), `merge pending: <the forge's reason>`,
        /// `rebase queued` or `rebase starting`.
        public var state: String
        /// When the commit was pushed.
        public var since: Date
        /// The pipeline, or the review request while no pipeline is known.
        public var url: URL

        public init(card: String, cardURL: URL?, round: Int, commit: String, state: String, since: Date, url: URL) {
            self.card = card
            self.cardURL = cardURL
            self.round = round
            self.commit = commit
            self.state = state
            self.since = since
            self.url = url
        }
    }

    public init(
        version: String = loopworkerVersion, pid: Int32, host: String, started: Date, updated: Date,
        paused: Bool, draining: Bool, auth: Auth, projects: [Project], ci: [CI]? = nil, log: [String]
    ) {
        self.version = version
        self.pid = pid
        self.host = host
        self.started = started
        self.updated = updated
        self.paused = paused
        self.draining = draining
        self.auth = auth
        self.projects = projects
        self.ci = ci
        self.log = log
    }

    public static func file(stateDir: URL) -> URL { stateDir.appending(path: "status.json") }

    /// Writes to a temporary file in the same directory, then renames it over `file`, so a
    /// reader never sees a partial file.
    public func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = file.deletingLastPathComponent().appending(path: ".status.json.\(getpid()).tmp")
        try data.write(to: temp)
        if rename(temp.path, file.path) != 0 {
            throw ConfigError("can't rename \(temp.path) to \(file.path): \(String(cString: strerror(errno)))")
        }
    }

    public static func read(from file: URL) throws -> ManagerStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ManagerStatus.self, from: Data(contentsOf: file))
    }
}
