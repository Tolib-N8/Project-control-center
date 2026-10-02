import Foundation

struct FoundRepo: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var branch: String = "—"
    var lastActivity: Date?
    var agents: [AgentKind: Int] = [:]
}

/// Finds git repositories under the chosen folders.
enum RepoScanner {
    static let skipped: Set<String> = ["node_modules", ".build", "build", "Pods", "vendor", "DerivedData", "dist", ".venv", "venv", "target", "Library"]

    static func scan(roots: [String], maxDepth: Int = 3) -> [FoundRepo] {
        var found: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String, depth: Int) {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                found.append(dir)
                return
            }
            guard depth < maxDepth, let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for item in items where !item.hasPrefix(".") && !skipped.contains(item) {
                let child = (dir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    walk(child, depth: depth + 1)
                }
            }
        }
        for root in roots { walk(root.expandingTilde, depth: 0) }
        return Array(Set(found)).sorted().map { path in
            FoundRepo(path: path, name: (path as NSString).lastPathComponent)
        }
    }

    /// Adds branch, last commit date and agent session counts.
    static func enrich(_ repos: [FoundRepo]) -> [FoundRepo] {
        let claudeRoot = ClaudeCodeParser.defaultRoot()
        let codex = CodexParser.discover(root: CodexParser.defaultRoot())
        let paths = repos.map(\.path)
        var codexCounts: [String: Int] = [:]
        for (_, cwd) in codex {
            if let p = SessionIndexer.project(for: cwd, in: paths) { codexCounts[p, default: 0] += 1 }
        }
        return repos.map { r in
            var r = r
            let head = Shell.git(r.path, ["rev-parse", "--abbrev-ref", "HEAD"])
            if head.ok { r.branch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            let last = Shell.git(r.path, ["log", "-1", "--format=%aI"])
            r.lastActivity = DateFormat.iso8601NoFraction.date(from: last.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let claude = ClaudeCodeParser.countSessions(root: claudeRoot, projectPath: r.path)
            if claude > 0 { r.agents[.claude] = claude }
            if let c = codexCounts[r.path] { r.agents[.codex] = c }
            if AiderParser.historyFile(in: r.path) != nil { r.agents[.aider] = 1 }
            return r
        }
    }
}
