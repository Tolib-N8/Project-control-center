import Foundation

/// Combined result of checks or workflow runs.
enum CheckState: String, Codable, Hashable {
    case success, failure, pending, none
}

struct PullRequest: Codable, Hashable, Identifiable {
    var number: Int
    var title: String
    var url: String
    var isDraft: Bool
    var author: String
    var branch: String
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED, or nil when the repo needs no review.
    var reviewDecision: String?
    var checks: CheckState
    /// MERGEABLE / CONFLICTING / UNKNOWN
    var mergeable: String?
    var updatedAt: Date

    var id: Int { number }
}

/// CI on the branch that is checked out locally: the latest run of each push/PR workflow.
struct CIStatus: Codable, Hashable {
    var state: CheckState
    var failed: Int
    var branch: String
    var url: String?
    var date: Date?
}

struct GitHubRepo: Codable, Hashable {
    var slug: String
    var pulls: [PullRequest]
    var ci: CIStatus?
    var fetchedAt: Date
}

enum GitHubAccess: Equatable {
    case unknown, notInstalled, signedOut
    case signedIn(String)

    var login: String? { if case .signedIn(let l) = self { l } else { nil } }
}

enum PRStatus {
    enum Tone { case ok, warn, bad, normal, muted }

    /// The one thing to know about a PR right now, as in the design: "Готов к merge", "Ждёт вашего ревью"…
    static func describe(_ pr: PullRequest, me: String?) -> (text: String, tone: Tone) {
        if pr.isDraft { return (tr("Черновик", "Draft"), .muted) }
        if pr.checks == .failure { return (tr("CI падает", "CI failing"), .bad) }
        if pr.mergeable == "CONFLICTING" { return (tr("Конфликт с base", "Conflicts with base"), .bad) }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return (tr("Просят правки", "Changes requested"), .warn) }
        if pr.checks == .pending { return (tr("Идут проверки", "Checks running"), .normal) }
        if pr.reviewDecision == "REVIEW_REQUIRED" {
            return pr.author == me ? (tr("Ждёт ревью", "Awaiting review"), .normal) : (tr("Ждёт вашего ревью", "Needs your review"), .normal)
        }
        if pr.mergeable == "MERGEABLE" { return (tr("Готов к merge", "Ready to merge"), .ok) }
        return (tr("Открыт", "Open"), .muted)
    }
}
