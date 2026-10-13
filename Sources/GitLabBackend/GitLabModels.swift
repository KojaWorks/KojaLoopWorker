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
    var lastEditedAt: Date?
    var lastEditedBy: GQLUser?
    /// Null for a deleted user.
    var author: GQLUser?

    var numericID: String { String(id.split(separator: "/").last ?? Substring(id)) }
}

struct GQLPageInfo: Decodable, Sendable {
    var hasNextPage: Bool
    var endCursor: String?
}

struct GQLIssueContent: Decodable, Sendable {
    struct Notes: Decodable, Sendable {
        var pageInfo: GQLPageInfo
        var nodes: [GQLNote]
    }
    var title: String
    var description: String?
    var createdAt: Date
    var lastEditedAt: Date?
    var lastEditedBy: GQLUser?
    var author: GQLUser?
    var notes: Notes
}
