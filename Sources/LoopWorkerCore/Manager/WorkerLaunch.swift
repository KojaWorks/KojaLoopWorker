import Foundation

/// The files in a slot's state directory that start a worker.
public enum WorkerLaunch {
    /// Quotes `s` as one word for bash, whatever it contains.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `launch.sh`: re-execs itself under `env -i` so that no Manager or tmux-server variable
    /// reaches the worker, sources `worker.env`, and execs `claude` with the brief read from
    /// `brief.md`. `model` nil omits `--model`.
    public static func script(worktree: URL, stateDir: URL, port: Int, model: String?) -> String {
        let q = { shellQuote($0) }
        let state = stateDir.path
        let modelFlag = model.map { " --model \(q($0))" } ?? ""
        return """
            #!/usr/bin/env bash
            # Start from an empty environment so no Manager or tmux-server secret reaches the worker.
            [ -n "${LOOPWORKER_CLEAN_ENV:-}" ] || exec env -i LOOPWORKER_CLEAN_ENV=1 HOME="$HOME" PATH="$PATH" TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$0"
            set -euo pipefail
            cd \(q(worktree.path))
            set -a; . \(q(state + "/worker.env")); set +a
            export LOOPWORKER=1 LOOPWORKER_OUTCOME=\(q(state + "/outcome.json")) LOOPWORKER_SLOT_DIR=\(q(worktree.path)) LOOPWORKER_PORT=\(port)
            unset USER   # claude-code 2.1.201: USER plus MCP ToolSearch gives a 401
            exec claude --permission-mode auto --add-dir \(q(state)) --strict-mcp-config --mcp-config \(q(state + "/mcp.json")) --settings \(q(state + "/settings.json"))\(modelFlag) "$(cat \(q(state + "/brief.md")))"

            """
    }

    /// `worker.env`: one `NAME='value'` line per variable, for `set -a; . worker.env`.
    public static func environmentFile(_ values: [(name: String, value: String)]) -> String {
        values.map { "\($0.name)=\(shellQuote($0.value))\n" }.joined()
    }

    /// `settings.json`, added on top of the host user's Claude Code settings: it denies file
    /// writes under `~/.claude` (memories, settings, hooks) and in the user's `autoMemoryDirectory`,
    /// by its configured and its symlink-resolved path, so an unattended worker can't change what
    /// every later session loads.
    /// - Parameters:
    ///   - home: The worker's `HOME`; nil leaves only the `~/.claude` rules.
    ///   - userSettings: The contents of `~/.claude/settings.json`, if any.
    public static func settings(home: URL?, userSettings: Data?) -> String {
        var dirs = ["~/.claude"]
        if let home {
            let memory = userSettings
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["autoMemoryDirectory"] as? String }
            for configured in [home.appending(path: ".claude").path] + (memory.map { [$0] } ?? []) {
                let url = configured.hasPrefix("~/") ? home.appending(path: String(configured.dropFirst(2))) : URL(filePath: configured)
                for path in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path] where !dirs.contains("/" + path) {
                    dirs.append("/" + path)  // `//abs` is an absolute path in a permission rule
                }
            }
        }
        let deny = dirs.flatMap { ["Edit(\($0)/**)", "Write(\($0)/**)"] }
        let data = try! JSONSerialization.data(withJSONObject: ["permissions": ["deny": deny]], options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The MCP config for workers whose contract declares none.
    public static let emptyMCPConfig = #"{"mcpServers":{}}"#
}
