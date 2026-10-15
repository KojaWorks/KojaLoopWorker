import Foundation

// REST v4 shapes, decoded with snake_case conversion. Only the fields LoopWorker reads.

struct GLUser: Decodable, Sendable, Equatable {
    var id: Int
    var username: String
}

struct GLProject: Decodable, Sendable {
    var id: Int
    var pathWithNamespace: String
    var defaultBranch: String?
}

struct GLIssue: Decodable, Sendable {
    /// Global id; also the work item's id.
    var id: Int
    var iid: Int
    var projectId: Int
    var title: String
    var description: String?
    /// `opened` or `closed`.
    var state: String
    var labels: [String]
    var assignees: [GLUser]?
    var author: GLUser
    var createdAt: Date
    var webUrl: String
    var movedToId: Int?
}

struct GLNote: Decodable, Sendable {
    var id: Int
    var body: String
    var author: GLUser
    var createdAt: Date
    var system: Bool
}

struct GLLabelEvent: Decodable, Sendable {
    struct Label: Decodable, Sendable { var name: String }
    var id: Int
    var user: GLUser?
    var createdAt: Date
    /// Null when the label was deleted since.
    var label: Label?
    /// `add` or `remove`.
    var action: String
}

struct GLMergeRequest: Decodable, Sendable {
    var iid: Int
    var webUrl: String
    var assignees: [GLUser]?
    /// `opened`, `closed`, `locked` (a merge in progress) or `merged`.
    var state: String?
    var mergeCommitSha: String?
    /// Why it can or can't merge now: `mergeable`, `not_approved`, `need_rebase`, ...
    var detailedMergeStatus: String?
    var createdAt: Date?
    var description: String?
}

/// A merge request discussion: a thread, or a single note (`individualNote`).
struct GLDiscussion: Decodable, Sendable {
    struct Note: Decodable, Sendable {
        var id: Int
        var body: String
        var author: GLUser
        var createdAt: Date
        var system: Bool
        var resolvable: Bool?
        var resolved: Bool?
        var position: Position?
    }
    struct Position: Decodable, Sendable {
        var headSha: String?
        var oldPath: String?
        var newPath: String?
        var oldLine: Int?
        var newLine: Int?
    }
    var id: String
    var individualNote: Bool
    var notes: [Note]
}

struct GLPipeline: Decodable, Sendable {
    var id: Int
    /// `created`, `pending`, `running`, `success`, `failed`, `canceled`, `skipped`, `manual`, ...
    var status: String
    var webUrl: String
    var ref: String?
    /// What triggered it: `push`, `merge_request_event`, `parent_pipeline` (a child), ...
    var source: String?
}

struct GLJob: Decodable, Sendable {
    var id: Int
    var name: String
    var stage: String
    var webUrl: String
    var allowFailure: Bool
    /// `success`, `failed`, `canceled`, `skipped`, `manual`, ...
    var status: String?
}

struct GLUpload: Decodable, Sendable {
    /// Relative to the project, e.g. `/uploads/<secret>/shot.png`.
    var url: String
    /// Relative to the instance, e.g. `/-/project/12/uploads/<secret>/shot.png`.
    var fullPath: String?
}

// GraphQL shapes. Snake-case conversion leaves camelCase keys untouched.

struct GQLUser: Decodable, Sendable {
    /// `gid://gitlab/User/<id>`.
    var id: String
    var username: String

    var numericID: Int? { Int(id.split(separator: "/").last ?? "") }
}

struct GQLNote: Decodable, Sendable {
    /// `gid://gitlab/Note/<id>`.
    var id: String
    var body: String
    var system: Bool
    var createdAt: Date
    /// Also set, to `updatedAt`, on a note nobody edited, and bumped when its thread is
    /// (un)resolved; only `lastEditedBy` marks a content edit.
    var lastEditedAt: Date?
    var lastEditedBy: GQLUser?
    /// Null for a deleted user.
    var author: GQLUser?

    var numericID: String { String(id.split(separator: "/").last ?? Substring(id)) }
    /// When someone last edited the body; nil when nobody did.
    var contentEditedAt: Date? { lastEditedBy == nil ? nil : lastEditedAt }
}

struct GQLPageInfo: Decodable, Sendable {
    var hasNextPage: Bool
    var endCursor: String?
}

/// One page of the snapshot query: the work item's title and description widget, and a page
/// of the issue's notes. `Issue` has no edit metadata; the description widget does, and GitLab
/// updates it when either the title or the description changes.
struct GQLSnapshotPage: Decodable, Sendable {
    struct Namespace: Decodable, Sendable { var workItem: WorkItem? }
    struct WorkItem: Decodable, Sendable {
        var title: String
        var widgets: [Widget]
    }
    /// Only the description widget's fragment fills the optional fields.
    struct Widget: Decodable, Sendable {
        var typename: String
        var description: String?
        var lastEditedAt: Date?
        var lastEditedBy: GQLUser?
        enum CodingKeys: String, CodingKey {
            case typename = "__typename", description, lastEditedAt, lastEditedBy
        }
    }
    struct Project: Decodable, Sendable { var issue: Issue? }
    struct Issue: Decodable, Sendable { var notes: Notes }
    struct Notes: Decodable, Sendable {
        var pageInfo: GQLPageInfo
        var nodes: [GQLNote]
    }
    var namespace: Namespace?
    var project: Project?
}

/// One page of a merge request's notes with their edit metadata, which REST doesn't have.
struct GQLMergeRequestNotesPage: Decodable, Sendable {
    struct Project: Decodable, Sendable { var mergeRequest: MergeRequest? }
    struct MergeRequest: Decodable, Sendable { var notes: Notes }
    struct Notes: Decodable, Sendable {
        var pageInfo: GQLPageInfo
        var nodes: [Edit]
    }
    struct Edit: Decodable, Sendable {
        /// `gid://gitlab/Note/<id>` or `gid://gitlab/DiffNote/<id>`.
        var id: String
        /// Like `GQLNote.lastEditedAt`: only a non-nil `lastEditedBy` marks a content edit.
        var lastEditedAt: Date?
        var lastEditedBy: GQLUser?

        var numericID: Int? { Int(id.split(separator: "/").last ?? "") }
    }
    var project: Project?
}

/// An issue's title and description with the metadata the trust check needs.
struct IssueText: Sendable {
    var title: String
    var description: String?
    var createdAt: Date
    var author: GQLUser?
    /// Covers title and description edits; nil when neither was ever edited.
    var lastEditedAt: Date?
    var lastEditedBy: GQLUser?
}
