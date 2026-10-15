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
        print(context.render() + Self.instructions(version: loopworkerVersion, home: home), terminator: "")
    }

    /// The repository's file URL prefix for `version`: its release tag, or `main` for a development build.
    static func docs(version: String) -> String {
        "https://github.com/KojaWorks/KojaLoopWorker/blob/\(version.hasPrefix("0.0.0") ? "main" : "v\(version)")/"
    }

    /// The setup instructions that follow the context (B201). They ship in the binary because
    /// the release is one signed executable without a resource bundle.
    static func instructions(version: String, home: URL) -> String {
        let docs = docs(version: version)
        let secrets = home.appending(path: "secrets.env").path
        return #"""
        # Setting up LoopWorker on this host

        The context above is what `loopworker prompt` found on this host. Skip each step that the context shows as done. Run `loopworker prompt` again to see the context after you change something.

        ## 1. What LoopWorker is

        LoopWorker is a Manager daemon that claims cards from a backlog and starts one disposable worker, a `claude` session in tmux, for each card. The worker implements the card in its own slot (a worktree of the project's repository), commits, and writes an outcome file; it holds no backlog or forge credentials. The Manager then pushes the branch to the forge, opens a review request and moves the card on; the backlog (GitLab issues, a Notion database or Patch) and the forge (GitLab or GitHub) are configured separately.

        ## 2. Rules for you

        - Never read, print or write the value of a token. Don't open or print `secrets.env`, and don't put a token on a command line. The user adds each token value to `secrets.env` themselves. You may create the file with empty `NAME=` lines and mode 600, or append an empty `NAME=` line to it without reading it, so that the user only has to paste the values.
        - Ask the user before you change a backlog that other people use, such as GitLab labels or Notion database properties.
        - Ask the user before you commit to their repository.
        - Never start a Manager on a home where one already runs. The context above says whether one runs.
        - Keep `config.toml` and every other config file 7-bit ASCII, comments included: no em-dashes, curly quotes or other non-ASCII characters.

        ## 3. Ask the user

        Ask these questions in one message, and don't guess the answers:

        1. Which backlog holds the cards: GitLab issues, a Notion database, or Patch?
        2. Which forge hosts the code: GitLab or GitHub? If it is self-hosted, what is its base URL?
        3. Which projects should LoopWorker serve? For each project, ask for its path on the forge (`group/app` on GitLab, `owner/repo` on GitHub), its base branch (the default is the forge's default branch), how many slots it gets (one slot runs one worker at a time; the default is 1), whether its slots are hot or cold, and the claude model for its workers (such as `opus`; the default is claude's own default). With a Notion backlog, also ask for the URL of the database that holds the project's cards.
        4. Who may vouch for cards?

        Explain hot and cold slots to the user: a hot slot keeps its stack and build caches between cards and uses memory all the time; a cold slot builds its stack for each card and tears it down afterwards.

        Explain what vouching means for their backlog, because the answer to question 4 depends on it. The Manager claims only cards that a person vouched for, and only content that the person vouched for reaches the worker.

        - GitLab: the person who owns the GitLab token vouches for an issue by assigning it to themselves and adding the `loopworker::next` label. That vouches for the title, description and comments as they are at that moment. Later edits and comments by anyone else are withheld from the worker. Only the token's owner can vouch, so the token must belong to the person who vouches.
        - Notion: the trusted users vouch. A card is ready when its state property is `next` and a trusted user was the last to edit the page. Any edit by a trusted user to a card in `next` counts as vouching for it, even a typo fix. Only body blocks and comments that a trusted user wrote or edited last reach the worker. If people who are not trusted can edit the database, warn the user that a trusted user's edit vouches for whatever else is on the page.
        - Patch: see the Patch backend's documentation (\#(docs)Sources/PatchBackend/PatchBackend.swift).

        For Notion, ask for the trusted users' names or email addresses. Look up their Notion user ids with your own Notion tools. If you have no Notion tools, write the ids that you have into `trusted_users`; if you have none, write the placeholder `00000000-0000-0000-0000-000000000000`. In step 8, `loopworker doctor` checks each trusted user, and when one fails, its remedy lists the workspace's people with their ids. Take the ids from there and replace the placeholder.

        ## 4. Write config.toml

        Write `config.toml` in `$LOOPWORKER_HOME`; the context above names the path. If the file exists, extend it: add the new `[[project]]` sections and keep everything else. One home serves one backlog and one forge. If the user wants a different backlog or forge than the existing file names, tell the user that this needs a second home (another `LOOPWORKER_HOME`) with its own Manager, and ask how to proceed.

        Build the file from the parts below. Keys that are not shown have working defaults.

        Host settings, always:

        ```toml
        clones_dir   = "~/Dev/loopworker"   # where the Manager clones projects and makes slot worktrees
        max_slots    = 2                    # host budget; each slot counts its project's weight (default 1)
        max_attempts = 3                    # crashes per card before the card is marked stuck
        ```

        A GitLab backlog:

        ```toml
        [backlog]
        kind = "gitlab"

        [backlog.gitlab]
        base_url  = "https://gitlab.com"
        token_env = "LOOPWORKER_GITLAB_TOKEN"
        allowed   = ["mygroup/"]            # project path prefixes; issues anywhere else are ignored
        # status_mode = "work_item_status"  # also set GitLab's status field (Premium and up)
        ```

        A Notion backlog:

        ```toml
        [backlog]
        kind = "notion"

        [backlog.notion]
        token_env         = "LOOPWORKER_NOTION_TOKEN"   # an internal integration's secret
        trusted_users     = ["<notion user id>"]        # the people whose edits vouch for cards
        state_property    = "LoopWorker"                # a select with next, working, ci, review, stuck
        # priority_property = "Priority"                # optional: number, select or multi_select
        # model_property    = "Model"                   # optional: select or text with a claude model alias

        [backlog.notion.projects]                       # one database per [[project]]
        "mygroup/myapp" = "https://www.notion.so/<workspace>/<title>-<32 hex digits>"   # or the bare id
        ```

        A Patch backlog: copy the `[backlog.patch]` section from the Patch backend's documentation (\#(docs)Sources/PatchBackend/PatchBackend.swift).

        A GitLab forge:

        ```toml
        [forge]
        kind = "gitlab"
        # With a backlog other than GitLab, a self-hosted GitLab needs its connection here:
        # [forge.gitlab]
        # base_url  = "https://gitlab.example.com"
        # token_env = "LOOPWORKER_GITLAB_TOKEN"
        ```

        A GitHub forge:

        ```toml
        [forge]
        kind = "github"

        [forge.github]
        token_env = "LOOPWORKER_GITHUB_TOKEN"
        # api_base = "https://ghe.example.com/api/v3"   # GitHub Enterprise only
        ```

        One section per project:

        ```toml
        [[project]]
        path        = "mygroup/myapp"   # the forge path; with a GitLab backlog, also the backlog's project
        slots       = 1
        hot         = false
        model       = "opus"            # optional
        base_branch = "main"            # optional; the default is the forge's default branch
        ```

        ## 5. Secrets

        Tokens live in `$LOOPWORKER_HOME/secrets.env`, one `NAME=value` line each. The Manager refuses to start when group or others can read the file. A token in the user's shell counts only when `secrets.env` doesn't set it, and a launchd service has no shell environment, so every token goes in the file. Tell the user which lines to add, with the variable names that `config.toml` uses, and how to get each token:

        - `LOOPWORKER_GITLAB_TOKEN`, for a GitLab backlog or forge: a GitLab personal access token with the `api` scope (User settings, then Access tokens). Never use the OAuth token that `glab auth login` stores: it expires after about two hours, and the Manager can't refresh it.
        - `LOOPWORKER_GITHUB_TOKEN`, for a GitHub forge: a GitHub token that can push to the projects' repositories and open pull requests. A fine-grained token needs Contents and Pull requests with read and write access on those repositories.
        - `LOOPWORKER_NOTION_TOKEN`, for a Notion backlog: the secret of a Notion internal integration. The user creates the integration in Notion's integration settings (https://www.notion.so/profile/integrations) as an internal integration in the workspace that holds the databases, with the capabilities Read content, Update content, Insert content, Read comments, Insert comments, and Read user information without email addresses. The secret is on the integration's configuration page. A personal token is refused.
        - The variable that `[backlog.patch] token_env` names, for a Patch backlog: see the Patch backend's documentation.
        - `CLAUDE_CODE_OAUTH_TOKEN`, on every host: the user runs `claude setup-token` and pastes the token that it prints. Without it, workers use the host's interactive claude login, which a launchd service can't reach and which concurrent workers can log out.

        Create the file, or have the user create it, so that only the user can read it:

        ```bash
        touch '\#(secrets)' && chmod 600 '\#(secrets)'
        ```

        Then the user copies each token and appends it with this command, one variable at a time. The token comes from the clipboard, so it stays out of the shell history, and the append keeps the file's mode. An editor that saves by replacing the file can reset the mode to 644.

        ```bash
        printf 'LOOPWORKER_GITLAB_TOKEN=%s\n' "$(pbpaste)" >> '\#(secrets)'
        ```

        To check the result, run `loopworker prompt` again: the context says which variables are set, and which lines lack a `NAME=`, without showing any value. Never print the file or any part of a line from it to check it yourself.
        ```

        ## 6. Prepare the backlog

        GitLab: the Manager moves each card between labels. Ask the user before you create them, because everyone in the group sees them. Create `loopworker::next`, `loopworker::working`, `loopworker::review` and `loopworker::stuck` once in the group that holds the projects, and `loopworker::ci` if a project's contract sets `[review] wait_for_ci`. On GitLab Premium these are scoped labels, so an issue carries one of them at a time. On GitLab Free, the user must remove the old label by hand when they add `loopworker::next` to a stuck card.

        Notion, for each project's database:

        1. The user connects the integration to the database: on the database's page, the ••• menu, then Connections, then the integration. You can't do this step. Until it is done, the API can't see the database.
        2. Add the state property: a select property named `LoopWorker` (or the configured `state_property`) with exactly the options `next`, `working`, `ci`, `review` and `stuck`. Only LoopWorker writes it; LoopWorker never reads or writes the team's own status property.
        3. Optionally, add a priority property (a number, or a select or multi-select whose earlier options rank higher) and a model property (a select or a text property that holds a claude model alias such as `opus`), and name them in `priority_property` and `model_property`.

        Make the changes in steps 2 and 3 with your Notion tools once the user agrees. If you have no Notion tools, give the user the clicks: open the database, add a property with the + at the end of the property header row, choose Select, name it `LoopWorker`, and add the five options.

        Patch: see the README (\#(docs)README.md) and the Patch backend's documentation.

        ## 7. Project contract

        Each project needs a project contract: a `.loopworker/` directory with `provision.sh` (brings a slot's stack up), `reset.sh` (cleans a hot slot between cards), `verify.sh` (the check that a worker must pass before it reports done), `teardown.sh`, an optional `manifest.toml` and an optional `BRIEF.md` with project instructions for workers. A slot whose provision or reset script is missing is marked broken. Check each project's repository for `.loopworker/`. If it is missing, explain this to the user and point them to the contract documentation (\#(docs)docs/project-contract.md) and the examples (\#(docs)examples/). Write a contract only when the user asks for it, in a new branch of their repository. When the contract shouldn't be committed, it can live on the host instead: set `contract = "~/.loopworker/contracts/<name>"` on the project.

        ## 8. Verify

        Run `loopworker doctor`. It prints `ok`, `warn` or `FAIL` for each check, with a remedy for each problem. Fix every FAIL that it names and run it again, until no FAIL is left. When a fix belongs to the user (a token value, a `sudo` command, connecting a Notion integration), tell the user exactly what doctor said. Explain each warning to the user, and let the user decide whether it matters.

        ## 9. Start

        Ask the user how to run the Manager:

        - In the foreground: `loopworker`. To keep it running after an SSH session ends: `tmux new-session -d -s loopworker loopworker run`.
        - As a launchd service that starts at login and restarts after a crash: `loopworker service install`. On a host where nobody logs in, `loopworker service install --daemon` writes a LaunchDaemon plist and prints the `sudo` commands that install it; the user runs those.

        Then tell the user how to vouch for a first card (step 3) and where to watch it: `loopworker status` shows the projects, slots and cards, and `$LOOPWORKER_HOME/state/manager.log` is the log. `loopworker pause` stops new claims, and the first Ctrl-C drains: running workers finish, then the Manager exits. The README (\#(docs)README.md) has the rest.

        """#
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
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                inFile = Self.secretNames(text)
                for n in Self.linesWithoutName(text) {
                    lines.append("  - line \(n) has no `NAME=`, so the Manager refuses to start; a value pasted without its name looks like this")
                }
            }
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
    /// The 1-based numbers of the lines in `secrets.env` text that `Secrets.load` rejects for
    /// lacking `=`. Never the content: such a line is often a bare token.
    static func linesWithoutName(_ text: String) -> [Int] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { n, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#") || line.contains("=") ? nil : n + 1
        }
    }

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
