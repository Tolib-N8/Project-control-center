import Foundation

/// What the local repository knows about the production branch on origin.
enum DeployGit {
    /// Tip of `branch` on origin, asked over the network; the repository itself isn't changed.
    static func remoteTip(_ repo: String, branch: String) -> String? {
        let r = Shell.git(repo, ["ls-remote", "origin", "refs/heads/" + branch], timeout: 25)
        guard r.ok, let sha = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first, sha.count >= 40 else { return nil }
        return String(sha)
    }

    /// Brings origin's branch into the local repository (remote-tracking ref only) and returns its tip.
    static func fetch(_ repo: String, branch: String) -> (tip: String?, error: String?) {
        let r = Shell.git(repo, ["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], timeout: 90)
        let tip = Shell.git(repo, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)^{commit}"], timeout: 10)
        let sha = tip.ok ? tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let error = r.ok ? nil : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        return (sha.isEmpty ? nil : sha, error)
    }

    static func has(_ repo: String, commit: String) -> Bool {
        Shell.git(repo, ["cat-file", "-e", commit + "^{commit}"], timeout: 10).ok
    }

    /// Commits in `to` that `from` doesn't have; nil when either side is unknown locally.
    static func behind(_ repo: String, from: String, to: String) -> Int? {
        guard has(repo, commit: from), has(repo, commit: to) else { return nil }
        let r = Shell.git(repo, ["rev-list", "--count", "\(from)..\(to)"], timeout: 15)
        return r.ok ? Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    static func subject(_ repo: String, commit: String) -> String? {
        let r = Shell.git(repo, ["log", "-1", "--format=%s", commit], timeout: 10)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    struct Line: Hashable, Identifiable {
        var hash: String
        var subject: String
        var author: String
        var date: Date
        var id: String { hash }
        var shortHash: String { String(hash.prefix(7)) }
    }

    /// What a deploy would bring: commits in `to` that `from` doesn't have, newest first.
    static func commits(_ repo: String, from: String, to: String, limit: Int = 40) -> [Line]? {
        guard has(repo, commit: from), has(repo, commit: to) else { return nil }
        let r = Shell.git(repo, ["log", "--format=%H%x09%ct%x09%an%x09%s", "-n", "\(limit)", "\(from)..\(to)"], timeout: 20)
        guard r.ok else { return nil }
        return parseLines(r.stdout)
    }

    static func parseLines(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { row in
            let p = row.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard p.count == 4, let ts = Double(p[1]) else { return nil }
            return Line(hash: String(p[0]), subject: String(p[3]), author: String(p[2]), date: Date(timeIntervalSince1970: ts))
        }
    }
}

/// What "Выкатить" shows before anything runs.
struct DeployPreview: Hashable {
    /// The commit that would be deployed: the tip of the production branch on origin.
    var target: String?
    var subject: String?
    /// What the server runs now.
    var current: String?
    /// nil when the list can't be worked out (the server's commit isn't in the local repository).
    var commits: [DeployGit.Line]?
    /// Why the deploy can't start, if it can't.
    var problem: String?
    var warning: String?

    var upToDate: Bool { target != nil && target == current }
}
