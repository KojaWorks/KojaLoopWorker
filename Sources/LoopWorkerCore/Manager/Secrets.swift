import Foundation

/// `$LOOPWORKER_HOME/secrets.env`: backend tokens for a Manager that has no shell environment
/// (launchd). See DESIGN.md "Host config".
public enum Secrets {
    /// Reads `NAME=value` lines. Blank lines and lines starting with `#` are skipped; the value
    /// is taken literally (no shell expansion) after trimming blanks and one pair of matching
    /// surrounding quotes. A missing file is an empty dictionary.
    ///
    /// The caller overlays the result on the process environment and hands it only to the
    /// backend factories and the worker environment lookups; it never goes through `setenv`, so
    /// lifecycle scripts, git hooks and the notify command don't inherit it.
    ///
    /// - Throws: `ConfigError` naming the file and its mode when group or others can read it,
    ///   and naming the file and line number (never the content) for a malformed line.
    public static func load(_ file: URL) throws -> [String: String] {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { return [:] }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o044 != 0 {
            throw ConfigError("\(file.path) has mode \(String(mode, radix: 8)); group or others can read it. Run: chmod 600 \(file.path)")
        }
        let text: String
        do { text = try String(contentsOf: file, encoding: .utf8) }
        catch { throw ConfigError("can't read \(file.path): \(error.localizedDescription)") }

        if let bad = rejectedLines(text).first {
            throw ConfigError("\(file.path) line \(bad.number): \(bad.reason.rawValue); expected NAME=value")
        }
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = Substring(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = value.dropFirst().dropLast()
            }
            values[name] = String(value)
        }
        return values
    }

    /// `base` (the process environment) with `file`'s values overlaid: what the backend
    /// factories and the worker and preflight token lookups see.
    /// - Throws: whatever `load` throws.
    public static func overlay(_ base: [String: String], with file: URL) throws -> [String: String] {
        base.merging(try load(file)) { _, secret in secret }
    }

    /// A line of `secrets.env` that `load` refuses, by its 1-based number.
    public struct RejectedLine: Sendable, Equatable {
        public enum Reason: String, Sendable {
            case noName = "no NAME="
            case notAName = "not a variable name"
        }
        public var number: Int
        public var reason: Reason
    }

    /// Every line of `secrets.env` text that `load` refuses: one without `=`, or one whose
    /// part before `=` isn't a variable name (`export NAME=value`). Holds no content, because
    /// a rejected line is often a bare token.
    public static func rejectedLines(_ text: String) -> [RejectedLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { n, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            guard let eq = line.firstIndex(of: "=") else { return RejectedLine(number: n + 1, reason: .noName) }
            return isName(line[..<eq].trimmingCharacters(in: .whitespaces)) ? nil : RejectedLine(number: n + 1, reason: .notAName)
        }
    }

    private static func isName(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }
}
