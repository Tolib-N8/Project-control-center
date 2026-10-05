import Foundation

/// Pull requests and CI through the GitHub CLI (`gh`), using the account the user is signed in with.
enum GitHubService {
    /// "owner/repo" from an origin URL on github.com (https, ssh or scp-style).
    static func slug(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "ssh://", "git://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let at = s.firstIndex(of: "@"), s[..<at].allSatisfy({ $0 != "/" }) { s = String(s[s.index(after: at)...]) }
        guard s.lowercased().hasPrefix("github.com") else { return nil }
        s = String(s.dropFirst("github.com".count))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    static func slug(forRepo path: String) -> String? {
        let r = Shell.git(path, ["remote", "get-url", "origin"], timeout: 5)
        return r.ok ? slug(fromRemote: r.stdout) : nil
    }

    static func access() -> GitHubAccess {
        guard CLILocator.path(for: "gh") != nil else { return .notInstalled }
        guard let r = CLILocator.run("gh", ["api", "user", "--jq", ".login"], timeout: 20), r.ok else { return .signedOut }
        let login = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? .signedOut : .signedIn(login)
    }

    static func fetch(slug: String, branch: String) -> GitHubRepo? {
        let prFields = "number,title,url,isDraft,author,headRefName,reviewDecision,statusCheckRollup,mergeable,updatedAt"
        guard let prs = CLILocator.run("gh", ["pr", "list", "-R", slug, "--state", "open", "--limit", "30", "--json", prFields], timeout: 30),
              prs.ok else { return nil }
        let runFields = "status,conclusion,workflowName,url,headBranch,createdAt,event"
        let runs = CLILocator.run("gh", ["run", "list", "-R", slug, "-b", branch, "-L", "20", "--json", runFields], timeout: 30)
        return GitHubRepo(slug: slug,
                          pulls: parsePulls(Data(prs.stdout.utf8)),
                          ci: runs?.ok == true ? parseCI(Data(runs!.stdout.utf8), branch: branch) : nil,
                          fetchedAt: Date())
    }

    // MARK: - Parsing

    static func parsePulls(_ data: Data) -> [PullRequest] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { p in
            guard let number = p["number"] as? Int, let title = p["title"] as? String else { return nil }
            let review = p["reviewDecision"] as? String
            return PullRequest(number: number, title: title, url: p["url"] as? String ?? "",
                               isDraft: p["isDraft"] as? Bool ?? false,
                               author: (p["author"] as? [String: Any])?["login"] as? String ?? "",
                               branch: p["headRefName"] as? String ?? "",
                               reviewDecision: review?.isEmpty == false ? review : nil,
                               checks: checkState(p["statusCheckRollup"] as? [[String: Any]] ?? []),
                               mergeable: p["mergeable"] as? String,
                               updatedAt: (p["updatedAt"] as? String).flatMap(DateFormat.parseISO) ?? .distantPast)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static let failing: Set<String> = ["FAILURE", "TIMED_OUT", "ERROR", "ACTION_REQUIRED", "STARTUP_FAILURE"]

    /// A check run has status + conclusion, a commit status has state.
    static func checkState(_ rollup: [[String: Any]]) -> CheckState {
        var pending = false, any = false
        for c in rollup {
            let state = ((c["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c["state"] as? String ?? "").uppercased()
            let status = (c["status"] as? String ?? "").uppercased()
            if failing.contains(state) { return .failure }
            if state == "PENDING" || state == "EXPECTED" || (!status.isEmpty && status != "COMPLETED") { pending = true }
            any = true
        }
        return pending ? .pending : any ? .success : .none
    }

    /// Latest run of each push / pull_request workflow on the branch; triage and other bots are ignored.
    static func parseCI(_ data: Data, branch: String) -> CIStatus? {
        guard let runs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var latest: [String: [String: Any]] = [:]
        for r in runs {
            guard ["push", "pull_request"].contains(r["event"] as? String ?? ""),
                  (r["headBranch"] as? String ?? branch) == branch else { continue }
            let name = r["workflowName"] as? String ?? ""
            let date = (r["createdAt"] as? String).flatMap(DateFormat.parseISO) ?? .distantPast
            let known = (latest[name]?["createdAt"] as? String).flatMap(DateFormat.parseISO) ?? .distantPast
            if latest[name] == nil || date > known { latest[name] = r }
        }
        guard !latest.isEmpty else { return nil }
        let considered = latest.values.filter { !["cancelled", "skipped", "neutral"].contains($0["conclusion"] as? String ?? "") }
        let failed = considered.filter { ["failure", "timed_out", "startup_failure", "action_required"].contains($0["conclusion"] as? String ?? "") }
        let running = considered.contains { ($0["status"] as? String ?? "completed") != "completed" }
        let newest = latest.values.max { ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "") }
        let state: CheckState = !failed.isEmpty ? .failure : running ? .pending : considered.isEmpty ? .none : .success
        let link = (failed.first ?? newest)?["url"] as? String
        return CIStatus(state: state, failed: failed.count, branch: branch, url: link,
                        date: (newest?["createdAt"] as? String).flatMap(DateFormat.parseISO))
    }
}
