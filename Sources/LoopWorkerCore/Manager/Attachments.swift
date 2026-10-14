import Foundation

/// Files that a worker wrote into its slot state directory and named in its outcome: the
/// `guide`, and `attachment:<path>` references inside markdown links or images in the body,
/// such as `![after](attachment:after.png)`. The Manager uploads each through the forge and
/// swaps in the returned URL, so the worker lays out a rich body without forge credentials.
enum Attachments {
    static let maxBytes = 20 * 1024 * 1024
    /// Bytes scanned for secrets in a file that isn't UTF-8 text; text is scanned in full.
    static let scanBytes = 1024 * 1024

    /// A file that wasn't attached; its reference stays in the body as written.
    struct Refusal: Error, Equatable {
        /// The path as the worker wrote it.
        var path: String
        var reason: String
    }

    /// Files that the Manager writes at the top of a slot state directory; `worker.env` holds
    /// the worker's secrets.
    static let slotFiles: Set<String> = [
        "outcome.json", "card.json", "card.md", "brief.md", "ci.md", "launch.sh", "mcp.json", "worker.env", LastOutcome.fileName,
    ]

    nonisolated(unsafe) private static let reference = #/\]\(attachment:([^)\s]+)/#
    nonisolated(unsafe) private static let pemPrivateKey = #/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/#

    /// Uploads each file that `body` references once and replaces its `attachment:<path>` with
    /// the URL; a refused reference stays as it is.
    /// - Throws: what `attach` throws other than a `BackendRejection`, which is a refusal.
    static func resolve(_ body: String, in root: URL, attach: (URL) async throws -> URL?) async throws -> (body: String, refused: [Refusal]) {
        var urls: [String: URL] = [:]
        var refused: [Refusal] = []
        for path in body.matches(of: reference).map({ String($0.1) }) where urls[path] == nil && !refused.contains(where: { $0.path == path }) {
            switch try await upload(path, in: root, attach: attach) {
            case .success(let url): urls[path] = url
            case .failure(let refusal): refused.append(refusal)
            }
        }
        let out = body.replacing(reference) { m in
            urls[String(m.1)].map { "](\($0.absoluteString)" } ?? String(m.0)
        }
        return (out, refused)
    }

    /// Checks the file `path` names and uploads it.
    /// - Throws: what `attach` throws other than a `BackendRejection`, which is a refusal.
    static func upload(_ path: String, in root: URL, attach: (URL) async throws -> URL?) async throws -> Result<URL, Refusal> {
        let file: URL
        switch check(path, in: root) {
        case .success(let f): file = f
        case .failure(let r): return .failure(r)
        }
        do {
            guard let url = try await attach(file) else { return .failure(Refusal(path: path, reason: "this forge has no attachments")) }
            return .success(url)
        } catch let rejection as BackendRejection {
            return .failure(Refusal(path: path, reason: "the forge refused it: \(rejection)"))
        }
    }

    /// The file `path` names when it is safe to publish: inside `root` after resolving
    /// symlinks, not one of the Manager's `slotFiles`, a regular non-empty file under
    /// `maxBytes`, not named like a credential, and
    /// without a credential shape or a PEM private key in its content. Takes about a second
    /// per MB scanned, so callers stay off the Manager actor, as the async functions here do.
    static func check(_ path: String, in root: URL) -> Result<URL, Refusal> {
        func refuse(_ reason: String) -> Result<URL, Refusal> { .failure(Refusal(path: path, reason: reason)) }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let raw = path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
        let file = raw.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return refuse("it resolves to \(file.path), outside \(base.path)") }
        let components = file.path.dropFirst(base.path.count + 1).split(separator: "/").map(String.init)
        if components.count == 1, slotFiles.contains(components[0]) {
            return refuse("it resolves to \(file.path), LoopWorker's own slot file")
        }
        if credentialShaped(path.split(separator: "/").map(String.init)) { return refuse("its name looks like a credential file") }
        if credentialShaped(components) {
            return refuse("it resolves to \(file.path), whose name looks like a credential file")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return refuse("\(file.path) doesn't exist") }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return refuse("\(file.path) isn't a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return refuse("\(file.path) is empty") }
        guard size < maxBytes else { return refuse("\(file.path) is \(size) bytes; the limit is \(maxBytes)") }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { return refuse("can't read \(file.path): \(error)") }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data.prefix(scanBytes), as: UTF8.self)
        if text.contains(pemPrivateKey) { return refuse("it contains a PEM private key") }
        if Redactor.containsCredential(text) { return refuse("its content looks like it holds a token or password") }
        return .success(file)
    }

    /// `.env*`, `*.env`, `*.pem`, `*.key`, `*.p12`, `id_rsa*` and `id_ed25519*`, or anything under a
    /// `.git`, `.ssh` or `.claude` directory.
    static func credentialShaped(_ components: [String]) -> Bool {
        if components.contains(where: { [".git", ".ssh", ".claude"].contains($0.lowercased()) }) { return true }
        guard let name = components.last?.lowercased() else { return false }
        return name.hasPrefix(".env") || name.hasSuffix(".env") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519")
            || [".pem", ".key", ".p12"].contains { name.hasSuffix($0) }
    }
}
