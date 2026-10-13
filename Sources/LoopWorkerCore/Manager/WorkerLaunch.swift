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
            exec claude --permission-mode auto --strict-mcp-config --mcp-config \(q(state + "/mcp.json"))\(modelFlag) "$(cat \(q(state + "/brief.md")))"

            """
    }

    /// `worker.env`: one `NAME='value'` line per variable, for `set -a; . worker.env`.
    public static func environmentFile(_ values: [(name: String, value: String)]) -> String {
        values.map { "\($0.name)=\(shellQuote($0.value))\n" }.joined()
    }

    /// The MCP config for workers whose contract declares none.
    public static let emptyMCPConfig = #"{"mcpServers":{}}"#
}
