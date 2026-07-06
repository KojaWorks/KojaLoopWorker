import Foundation

// Decoded from `loopworker`'s status contract (see docs/distribution.md, dashboard.py).
// contract_version lets the app refuse a Manager it can't parse rather than misrender it.
let supportedContractVersion = 1

/// GET /health — compact, cheap-to-poll state summary.
struct Health: Codable {
    let contractVersion: Int
    let loopworkerVersion: String
    let mode: String                 // "host" | "single"
    let workerManager: String?
    let paused: Bool
    let slots: Int
    let busy: Int

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case loopworkerVersion = "loopworker_version"
        case workerManager = "worker_manager"
        case mode, paused, slots, busy
    }
}

/// GET /json — the full snapshot. Decoded leniently: host mode carries `projects[]`,
/// single-project mode carries top-level `slots[]`.
struct Snapshot: Codable {
    let workerManager: String?
    let project: String?
    let paused: Bool?
    let startedAt: String?
    let projects: [ProjectSnapshot]?
    let slots: [SlotSnapshot]?

    enum CodingKeys: String, CodingKey {
        case workerManager = "worker_manager"
        case project, paused, projects, slots
        case startedAt = "started_at"
    }

    /// Normalize both shapes into a flat list of (project, slots) sections for the UI.
    var sections: [(project: String, slots: [SlotSnapshot])] {
        if let projects { return projects.map { ($0.project, $0.slots) } }
        return [(project ?? "project", slots ?? [])]
    }
}

struct ProjectSnapshot: Codable {
    let project: String
    let hot: Bool?
    let slots: [SlotSnapshot]
}

struct SlotSnapshot: Codable, Identifiable {
    let index: Int
    let state: String                // cold | idle | busy | broken
    let activity: String?
    let card: Int?
    let model: String?
    let port: Int?

    var id: Int { index }            // unique within a project section, which is all the UI needs
}

/// `loopworker doctor --json` — host-prerequisite sweep.
struct DoctorReport: Codable {
    let ok: Bool
    let checks: [ReadinessCheck]
}

struct ReadinessCheck: Codable, Identifiable {
    let name: String
    let ok: Bool
    let detail: String
    let remedy: String

    var id: String { name }
}
