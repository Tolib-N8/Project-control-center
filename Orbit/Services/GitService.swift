import Foundation

/// Reads repository state with /usr/bin/git. All methods are synchronous; call off the main thread.
enum GitService {
    static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    static func status(_ repo: String, historyDays: Int = 45) -> RepoStatus {
        var s = RepoStatus()
        guard isRepo(repo) else {
            s.error = "Не git-репозиторий"
            return s
        }
        readBranchAndChanges(repo, into: &s)
        s.mainBranch = mainBranch(repo)
        if let main = s.mainBranch {
            if s.branch != main {
                (s.aheadMain, s.behindMain) = aheadBehind(repo, "HEAD", main)
                if s.behindMain > 0 { s.conflictFiles = conflictCount(repo, main) }
            } else {
                s.behindMain = s.behind
            }
        }
        s.commits = commits(repo, sinceDays: historyDays)
        s.lastCommit = s.commits.first ?? commits(repo, limit: 1).first
        s.branches = branches(repo, current: s.branch, main: s.mainBranch)
        s.stack = StackDetector.detect(repo)
        return s
    }

    // MARK: - Working tree

    static func readBranchAndChanges(_ repo: String, into s: inout RepoStatus) {
        let r = Shell.git(repo, ["-c", "core.quotePath=false", "status", "--porcelain=v2", "--branch", "--untracked-files=normal"])
        guard r.ok else {
            s.error = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        var changes: [String: FileChange] = [:]
        var order: [String] = []
        for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                s.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                s.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    s.ahead = Int(parts[2].dropFirst()) ?? 0
                    s.behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                let isRename = line.hasPrefix("2 ")
                let fieldCount = line.hasPrefix("u ") ? 10 : (isRename ? 9 : 8)
                let fields = line.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard fields.count > fieldCount else { continue }
                let xy = fields[1]
                var path = String(fields[fieldCount])
                if isRename, let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
                let status: String
                if line.hasPrefix("u ") { status = "U" }
                else if isRename { status = "R" }
                else if xy.contains("A") { status = "A" }
                else if xy.contains("D") { status = "D" }
                else { status = "M" }
                if changes[path] == nil { order.append(path) }
                changes[path] = FileChange(path: path, status: status, added: 0, removed: 0)
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                if changes[path] == nil { order.append(path) }
                let isDir = path.hasSuffix("/")
                changes[path] = FileChange(path: path, status: "?", added: isDir || changes.count > 300 ? 0 : lineCount(repo, path), removed: 0)
            } else if s.branch == "(detached)" || line.hasPrefix("# branch.oid") {
                continue
            }
        }

        // Line counts for tracked changes (staged + unstaged against HEAD).
        let diff = Shell.git(repo, ["-c", "core.quotePath=false", "diff", "HEAD", "--numstat", "-M"])
        if diff.ok {
            for line in diff.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                var path = String(parts[2])
                if path.contains(" => ") { path = renameTarget(path) }
                guard var c = changes[path] else { continue }
                c.added = Int(parts[0]) ?? 0
                c.removed = Int(parts[1]) ?? 0
                changes[path] = c
            }
        }
        s.changes = order.compactMap { changes[$0] }

        let fm = FileManager.default
        let dates = s.changes.compactMap { change -> Date? in
            let full = (repo as NSString).appendingPathComponent(change.path)
            return (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
        }
        s.changesSince = dates.min()
    }

    private static func renameTarget(_ path: String) -> String {
        // "src/{old => new}/file" or "old => new"
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}") {
            let inner = path[path.index(after: open)..<close]
            let target = inner.components(separatedBy: " => ").last ?? ""
            return (String(path[..<open]) + target + String(path[path.index(after: close)...]))
                .replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }

    private static func lineCount(_ repo: String, _ path: String) -> Int {
        let full = (repo as NSString).appendingPathComponent(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
              let size = attrs[.size] as? Int, size < 1_000_000,
              let data = FileManager.default.contents(atPath: full),
              !data.contains(0) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    // MARK: - Branches

    static func mainBranch(_ repo: String) -> String? {
        for candidate in ["main", "master", "trunk", "develop"] {
            if Shell.git(repo, ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"]).ok { return candidate }
        }
        for candidate in ["origin/main", "origin/master"] {
            if Shell.git(repo, ["show-ref", "--verify", "--quiet", "refs/remotes/\(candidate)"]).ok { return candidate }
        }
        return nil
    }

    /// (ahead, behind) of `a` relative to `b`.
    static func aheadBehind(_ repo: String, _ a: String, _ b: String) -> (Int, Int) {
        let r = Shell.git(repo, ["rev-list", "--left-right", "--count", "\(a)...\(b)"])
        let parts = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard r.ok, parts.count >= 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    static func conflictCount(_ repo: String, _ main: String) -> Int {
        let r = Shell.git(repo, ["merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", main])
        guard r.status == 1 else { return 0 }
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return lines.prefix { !$0.isEmpty }.count
    }

    static func branches(_ repo: String, current: String, main: String?) -> [BranchInfo] {
        let r = Shell.git(repo, ["for-each-ref", "refs/heads", "--sort=-committerdate",
                                 "--format=%(refname:short)%1f%(committerdate:iso-strict)"])
        guard r.ok else { return [] }
        var merged = Set<String>()
        if let main {
            let m = Shell.git(repo, ["branch", "--merged", main, "--format=%(refname:short)"])
            merged = Set(m.stdout.split(separator: "\n").map(String.init))
        }
        var result: [BranchInfo] = []
        for line in r.stdout.split(separator: "\n").prefix(40) {
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let date = DateFormat.iso8601NoFraction.date(from: String(parts[1])) ?? .distantPast
            var info = BranchInfo(name: name, lastCommit: date, behindMain: 0, aheadMain: 0, merged: merged.contains(name))
            if let main, name != main {
                (info.aheadMain, info.behindMain) = aheadBehind(repo, name, main)
            }
            result.append(info)
        }
        return result
    }

    // MARK: - History

    static func commits(_ repo: String, sinceDays: Int? = nil, limit: Int? = nil) -> [Commit] {
        var args = ["-c", "core.quotePath=false", "log", "--no-merges", "--numstat",
                    "--format=%x1e%H%x1f%s%x1f%an%x1f%aI%x1f%b%x1f"]
        if let sinceDays { args.append("--since=\(sinceDays).days") }
        if let limit { args.append("-n\(limit)") }
        let r = Shell.git(repo, args)
        guard r.ok else { return [] }
        var result: [Commit] = []
        for record in r.stdout.split(separator: "\u{1e}") {
            let parts = record.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { continue }
            var added = 0, removed = 0
            if parts.count == 6 {
                for line in parts[5].split(separator: "\n") {
                    let cols = line.split(separator: "\t")
                    if cols.count >= 2 {
                        added += Int(cols[0]) ?? 0
                        removed += Int(cols[1]) ?? 0
                    }
                }
            }
            let body = String(parts[4])
            let author = String(parts[2])
            result.append(Commit(
                hash: String(parts[0]),
                subject: String(parts[1]),
                author: author,
                date: DateFormat.iso8601NoFraction.date(from: String(parts[3])) ?? Date(),
                body: body,
                added: added,
                removed: removed,
                agent: agentFromTrailers(author: author, body: body)
            ))
        }
        return result
    }

    static func agentFromTrailers(author: String, body: String) -> AgentKind? {
        let b = body.lowercased()
        if b.contains("co-authored-by: claude") || b.contains("generated with [claude code]") || b.contains("noreply@anthropic.com") { return .claude }
        if b.contains("co-authored-by: codex") || b.contains("codex@openai") || b.contains("chatgpt-codex") { return .codex }
        if b.contains("co-authored-by: cursor") || b.contains("cursoragent") { return .cursor }
        if author.lowercased().contains("(aider)") || b.contains("aider: ") { return .aider }
        return nil
    }

    // MARK: - Actions

    static func fetch(_ repo: String) -> ShellResult {
        Shell.git(repo, ["fetch", "--all", "--prune", "--quiet"], timeout: 90)
    }

    static func diff(_ repo: String, files: [String] = []) -> String {
        var args = ["-c", "core.quotePath=false", "diff", "HEAD", "--stat", "--patch", "--no-color"]
        if !files.isEmpty { args += ["--"] + files }
        var out = Shell.git(repo, args).stdout
        let untracked = Shell.git(repo, ["ls-files", "--others", "--exclude-standard"]).stdout
        if !untracked.isEmpty { out += "\n# Новые файлы (не отслеживаются):\n" + untracked }
        return out
    }

    static func commit(_ repo: String, files: [String], message: String, push: Bool) -> ShellResult {
        let add = Shell.git(repo, ["add", "-A", "--"] + files)
        guard add.ok else { return add }
        let commit = Shell.git(repo, ["commit", "-m", message, "--"] + files)
        guard commit.ok, push else { return commit }
        return Shell.git(repo, ["push"], timeout: 90)
    }

    static func deleteBranch(_ repo: String, _ name: String) -> ShellResult {
        Shell.git(repo, ["branch", "-d", name])
    }

    /// Rebases `branch` onto `main`, aborting on conflicts and returning to the original branch.
    static func rebase(_ repo: String, branch: String, onto main: String) -> ShellResult {
        var s = RepoStatus()
        readBranchAndChanges(repo, into: &s)
        guard s.isClean else {
            return ShellResult(status: 1, stdout: "", stderr: "Есть незакоммиченные изменения — сначала закоммитьте их.")
        }
        let original = s.branch
        let r = Shell.git(repo, ["rebase", main, branch], timeout: 120)
        if !r.ok { Shell.git(repo, ["rebase", "--abort"]) }
        if original != branch { Shell.git(repo, ["switch", original]) }
        return r
    }
}

enum StackDetector {
    static func detect(_ repo: String) -> [String] {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (repo as NSString).appendingPathComponent(name)) }
        var stack: [String] = []

        if has("package.json"), let data = fm.contents(atPath: (repo as NSString).appendingPathComponent("package.json")),
           let text = String(data: data, encoding: .utf8) {
            if text.contains("\"react-native\"") { stack.append("React Native") }
            else if text.contains("\"next\"") { stack.append("Next.js") }
            else if text.contains("\"electron\"") { stack.append("Electron") }
            else if text.contains("\"vue\"") { stack.append("Vue") }
            else if text.contains("\"svelte\"") || text.contains("\"@sveltejs/kit\"") { stack.append("Svelte") }
            else if text.contains("\"react\"") { stack.append("React") }
            else { stack.append(has("tsconfig.json") ? "TypeScript" : "Node.js") }
        }
        if has("go.mod") { stack.append("Go") }
        if has("Cargo.toml") { stack.append("Rust") }
        if has("Package.swift") || (try? fm.contentsOfDirectory(atPath: repo))?.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "project.yml" }) == true {
            stack.append("Swift")
        }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
            stack.append("Python")
            let req = ["requirements.txt", "pyproject.toml"].compactMap { fm.contents(atPath: (repo as NSString).appendingPathComponent($0)) }
                .compactMap { String(data: $0, encoding: .utf8) }.joined()
            if req.contains("torch") { stack.append("PyTorch") }
            else if req.contains("django") { stack.append("Django") }
            else if req.contains("fastapi") { stack.append("FastAPI") }
        }
        if has("Gemfile") { stack.append("Ruby") }
        if has("pubspec.yaml") { stack.append("Flutter") }
        if has("docker-compose.yml") || has("compose.yaml") {
            let text = ["docker-compose.yml", "compose.yaml"].compactMap { fm.contents(atPath: (repo as NSString).appendingPathComponent($0)) }
                .compactMap { String(data: $0, encoding: .utf8) }.joined()
            if text.contains("postgres") { stack.append("Postgres") }
        }
        if stack.isEmpty {
            let files = (try? fm.contentsOfDirectory(atPath: repo)) ?? []
            if files.contains(where: { $0.hasSuffix(".sh") || $0 == ".zshrc" }) { stack.append("Shell") }
            if files.contains(where: { $0.hasSuffix(".lua") }) || has("nvim") { stack.append("Lua") }
            if files.contains(where: { $0.hasSuffix(".html") }) { stack.append("HTML") }
        }
        return Array(stack.prefix(2))
    }
}
