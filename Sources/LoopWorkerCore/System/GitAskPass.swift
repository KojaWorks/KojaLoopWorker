import Foundation

/// Gives git HTTPS credentials without putting them in argv, remote URLs or git config: git
/// runs `GIT_ASKPASS`, which answers its prompts from two environment variables.
public enum GitAskPass {
    public static let usernameVariable = "LOOPWORKER_GIT_USERNAME"
    public static let passwordVariable = "LOOPWORKER_GIT_PASSWORD"

    /// Writes the helper script into `directory` (once; it holds no secret) and returns the
    /// environment that makes git use it with `username` and `password`.
    public static func environment(scriptDirectory directory: URL, username: String, password: String) throws -> [String: String] {
        let script = directory.appending(path: "git-askpass.sh")
        let body = """
            #!/bin/sh
            case "$1" in
              Username*) printf '%s\\n' "$\(usernameVariable)" ;;
              *) printf '%s\\n' "$\(passwordVariable)" ;;
            esac

            """
        if (try? String(contentsOf: script, encoding: .utf8)) != body {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        return [
            "GIT_ASKPASS": script.path,
            "GIT_TERMINAL_PROMPT": "0",
            usernameVariable: username,
            passwordVariable: password,
        ]
    }
}
