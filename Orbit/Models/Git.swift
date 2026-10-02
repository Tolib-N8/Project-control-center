import Foundation

struct FileChange: Codable, Hashable, Identifiable {
    var id: String { path }
    var path: String
    /// One of M, A, D, R, ?
    var status: String
    var added: Int
    var removed: Int
}

struct Commit: Codable, Hashable, Identifiable {
    var id: String { hash }
    var hash: String
    var subject: String
    var author: String
    var date: Date
    var body: String
    var added: Int
    var removed: Int
    /// Agent that produced the commit, nil means the user did it by hand.
    var agent: AgentKind?

    var shortHash: String { String(hash.prefix(7)) }
}

struct BranchInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var lastCommit: Date
    var behindMain: Int
    var aheadMain: Int
    var merged: Bool
}

struct RepoStatus: Codable, Hashable {
    var branch = "—"
    var upstream: String?
    var ahead = 0
    var behind = 0
    var mainBranch: String?
    var behindMain = 0
    var aheadMain = 0
    var conflictFiles = 0
    var changes: [FileChange] = []
    /// Modification time of the oldest uncommitted change.
    var changesSince: Date?
    var commits: [Commit] = []
    var branches: [BranchInfo] = []
    var lastCommit: Commit?
    var stack: [String] = []
    var error: String?

    var linesAdded: Int { changes.reduce(0) { $0 + $1.added } }
    var linesRemoved: Int { changes.reduce(0) { $0 + $1.removed } }
    var isClean: Bool { changes.isEmpty }

    var changesAgeHours: Double? {
        changesSince.map { Date().timeIntervalSince($0) / 3600 }
    }
}
