import Foundation

/// Scrubs secret-shaped substrings from text before it reaches any output. Lifecycle scripts
/// print stack secrets (JWTs, S3 keys, database URLs), and that output is streamed to the log
/// and the status file. Over-redaction (a 40-character git SHA, for example) is accepted.
public enum Redactor {
    public static let placeholder = "[REDACTED]"

    /// Returns `line` with every secret-shaped substring replaced by `[REDACTED]`.
    ///
    /// Covered: JWTs, Supabase `sb_secret_`/`sb_publishable_` keys, hex strings of 32 or more
    /// characters, passwords in `scheme://user:password@host` URLs, GitLab (`glpat-`, `gloas-`,
    /// `glrt-`, `gldt-`), GitHub (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_`, `github_pat_`) and
    /// Claude (`sk-ant-`) tokens, and the values of `Bearer` and `PRIVATE-TOKEN:` headers.
    /// - Parameters:
    ///   - line: Text to scrub. Multi-line text works, but patterns never span lines.
    ///   - literals: Exact secret values to scrub as well, such as the configured backlog and
    ///     forge tokens. Empty strings are ignored.
    public static func redact(_ line: String, literals: [String] = []) -> String {
        var line = line
        for literal in literals where !literal.isEmpty {
            line = line.replacingOccurrences(of: literal, with: placeholder)
        }
        line = line.replacing(urlPassword) { "\($0.1)\(placeholder)@" }
        line = line.replacing(bearer) { "\($0.1)\(placeholder)" }
        line = line.replacing(privateToken) { "\($0.1)\(placeholder)" }
        for pattern in tokens {
            line = line.replacing(pattern, with: placeholder)
        }
        return line
    }

    /// True when `text` holds a credential shape that `redact` scrubs, leaving out the bare
    /// hex rule, which commit SHAs and digests match too.
    public static func containsCredential(_ text: String) -> Bool {
        text.contains(urlPassword) || text.contains(bearer) || text.contains(privateToken)
            || credentialTokens.contains { text.contains($0) }
    }

    // Regex isn't Sendable, but matching never mutates it (its compiled program is initialized atomically).
    nonisolated(unsafe) private static let urlPassword = #/([A-Za-z][A-Za-z0-9+.\-]*://[^:@/\s]+:)[^@/\s]+@/#
    nonisolated(unsafe) private static let bearer = #/(Bearer\s+)[^\s"']+/#.ignoresCase()
    nonisolated(unsafe) private static let privateToken = #/(PRIVATE-TOKEN:\s*)[^\s"']+/#.ignoresCase()
    nonisolated(unsafe) private static let tokens = credentialTokens + [#/\b[0-9a-fA-F]{32,}\b/#]
    nonisolated(unsafe) private static let credentialTokens: [Regex<Substring>] = [
        #/eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}/#,
        #/sb_(?:secret|publishable)_[A-Za-z0-9_\-]+/#,
        #/\b(?:glpat|gloas|glrt|gldt)-[A-Za-z0-9_.\-]+/#,
        #/\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]+/#,
        #/\bgithub_pat_[A-Za-z0-9_]+/#,
        #/\bsk-ant-[A-Za-z0-9_\-]+/#,
    ]
}
