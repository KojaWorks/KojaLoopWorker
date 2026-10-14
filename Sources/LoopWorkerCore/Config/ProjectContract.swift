import Foundation
import TOMLDecoder

/// A project contract: the `.loopworker/` directory that says how to build a slot's stack.
/// It lives in the repo, or in a host-local overlay named by `ProjectSpec.contract`, which
/// then replaces the repo's copy entirely. Scheduling (slots, hot, weight, model) is host
/// config, never contract.
public struct ProjectContract: Sendable, Equatable {
    public var directory: URL
    public var scripts: Scripts
    public var wallclockCapMinutes: Double
    /// MCP config file (relative to `directory`) passed with `--strict-mcp-config`; nil means
    /// the worker gets no MCP servers.
    public var mcpConfig: String?
    /// Ask the worker for a review guide (`storygrafter`) to attach to the review request.
    public var reviewGuide: Bool
    /// `BRIEF.md` content, appended to the built-in worker brief; nil when absent.
    public var brief: String?
    /// Card branch name template; must contain `{number}`. `{number}` is `Card.number` (or the
    /// first 8 hex characters of a SHA-256 of the card id when nil) and `{slug}` the title as
    /// lowercase ASCII words joined by `-`, at most 40 characters. Projects whose hooks parse
    /// branch names override it.
    public var branchTemplate: String
    /// How the Manager pulls Git LFS content into a slot.
    public var lfs: LFS

    public static let defaultBranchTemplate = "loopworker-{number}-{slug}"

    public struct Scripts: Sendable, Equatable {
        public var provision = "provision.sh"
        public var reset = "reset.sh"
        public var verify = "verify.sh"
        public var teardown = "teardown.sh"
        public var provisionTimeout: Duration = .seconds(45 * 60)
        public var resetTimeout: Duration = .seconds(15 * 60)
        public var teardownTimeout: Duration = .seconds(10 * 60)
        public init() {}
    }

    /// The `[lfs]` table. The Manager pulls LFS content with the forge credentials before the
    /// slot's first lifecycle script, because the scripts have none.
    public struct LFS: Sendable, Equatable {
        /// Pull whenever the repo uses Git LFS; false leaves pointer files in the worktree.
        public var pull = true
        /// git-lfs path patterns to pull; empty means all.
        public var include: [String] = []
        /// git-lfs path patterns not to pull.
        public var exclude: [String] = []
        public var pullTimeout: Duration = .seconds(60 * 60)
        public init() {}
    }

    public init(
        directory: URL, scripts: Scripts = Scripts(),
        wallclockCapMinutes: Double = 90, mcpConfig: String? = nil, reviewGuide: Bool = false,
        brief: String? = nil, branchTemplate: String = ProjectContract.defaultBranchTemplate, lfs: LFS = LFS()
    ) {
        self.directory = directory
        self.scripts = scripts
        self.wallclockCapMinutes = wallclockCapMinutes
        self.mcpConfig = mcpConfig
        self.reviewGuide = reviewGuide
        self.brief = brief
        self.branchTemplate = branchTemplate
        self.lfs = lfs
    }

    /// The directory to read for `project` with its clone at `clone`.
    public static func directory(for project: ProjectSpec, clone: URL) -> URL {
        if let overlay = project.contract { return URL(filePath: overlay) }
        return clone.appending(path: ".loopworker")
    }

    /// Loads `directory/manifest.toml` and `BRIEF.md`. A missing manifest is an error that
    /// names the path, so the operator knows which contract to add.
    public static func load(from directory: URL) throws -> ProjectContract {
        let file = directory.appending(path: "manifest.toml")
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) }
        catch { throw ConfigError("no project contract at \(file.path): \(error.localizedDescription)") }
        let raw: Raw
        do { raw = try TOMLDecoder().decode(Raw.self, from: text) }
        catch { throw ConfigError("\(file.path): \(error)") }

        var scripts = Scripts()
        if let s = raw.scripts {
            scripts.provision = s.provision ?? scripts.provision
            scripts.reset = s.reset ?? scripts.reset
            scripts.verify = s.verify ?? scripts.verify
            scripts.teardown = s.teardown ?? scripts.teardown
            for (name, minutes) in [("provision", s.provision_timeout_minutes),
                                    ("reset", s.reset_timeout_minutes),
                                    ("teardown", s.teardown_timeout_minutes)] {
                if let m = minutes, m <= 0 {
                    throw ConfigError("\(file.path): \(name)_timeout_minutes must be > 0")
                }
            }
            if let m = s.provision_timeout_minutes { scripts.provisionTimeout = .seconds(m * 60) }
            if let m = s.reset_timeout_minutes { scripts.resetTimeout = .seconds(m * 60) }
            if let m = s.teardown_timeout_minutes { scripts.teardownTimeout = .seconds(m * 60) }
        }
        var lfs = LFS()
        if let l = raw.lfs {
            lfs.pull = l.pull ?? lfs.pull
            lfs.include = l.include ?? []
            lfs.exclude = l.exclude ?? []
            // git-lfs takes each list comma-separated.
            if let bad = (lfs.include + lfs.exclude).first(where: { $0.contains(",") }) {
                throw ConfigError("\(file.path): [lfs] pattern \"\(bad)\" contains a comma, which git-lfs reads as a separator")
            }
            if let m = l.pull_timeout_minutes {
                guard m > 0 else { throw ConfigError("\(file.path): [lfs] pull_timeout_minutes must be > 0") }
                lfs.pullTimeout = .seconds(m * 60)
            }
        }
        let brief = try? String(contentsOf: directory.appending(path: "BRIEF.md"), encoding: .utf8)
        let branch = raw.worker?.branch ?? defaultBranchTemplate
        guard branch.contains("{number}") else {
            throw ConfigError("\(file.path): [worker] branch must contain {number}; without it two cards with the same title share a branch")
        }
        let cap = raw.worker?.wallclock_cap_minutes ?? 90
        guard cap > 0 else { throw ConfigError("\(file.path): wallclock_cap_minutes must be > 0") }
        return ProjectContract(
            directory: directory,
            scripts: scripts,
            wallclockCapMinutes: cap,
            mcpConfig: raw.worker?.mcp_config,
            reviewGuide: raw.review?.guide ?? false,
            brief: brief,
            branchTemplate: branch,
            lfs: lfs)
    }

    // Field names mirror the TOML keys.
    private struct Raw: Decodable {
        var scripts: RawScripts?
        var worker: RawWorker?
        var review: RawReview?
        var lfs: RawLFS?
    }
    private struct RawScripts: Decodable {
        var provision: String?
        var reset: String?
        var verify: String?
        var teardown: String?
        var provision_timeout_minutes: Double?
        var reset_timeout_minutes: Double?
        var teardown_timeout_minutes: Double?
    }
    private struct RawWorker: Decodable {
        var wallclock_cap_minutes: Double?
        var mcp_config: String?
        var branch: String?
    }
    private struct RawReview: Decodable { var guide: Bool? }
    private struct RawLFS: Decodable {
        var pull: Bool?
        var include: [String]?
        var exclude: [String]?
        var pull_timeout_minutes: Double?
    }
}
