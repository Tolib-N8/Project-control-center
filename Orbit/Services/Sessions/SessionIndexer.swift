import Foundation

/// Finds agent logs for the tracked projects, parses them (with an mtime cache) and maps sessions to projects.
enum SessionIndexer {
    private struct CacheEntry: Codable {
        var size: Int
        var mtime: Double
        var sessions: [AgentSession]
    }

    private static let cacheName = "cache/sessions-v2.json"
    /// Logs not touched for this long are ignored.
    static let maxAgeDays: Double = 120

    struct Source {
        var url: URL
        var agent: AgentKind
        var repo: String
    }

    static func sources(projects: [ProjectConfig], config: OrbitConfig) -> [Source] {
        let paths = projects.map(\.path)
        var result: [Source] = []

        let claude = config.source(.claude)
        if claude.enabled {
            let root = (claude.customPath ?? ClaudeCodeParser.defaultRoot()).expandingTilde
            result += ClaudeCodeParser.discover(root: root, projectPaths: paths).map { Source(url: $0, agent: .claude, repo: "") }
        }
        let codex = config.source(.codex)
        if codex.enabled {
            let root = (codex.customPath ?? CodexParser.defaultRoot()).expandingTilde
            for (url, cwd) in CodexParser.discover(root: root) where project(for: cwd, in: paths) != nil {
                result.append(Source(url: url, agent: .codex, repo: ""))
            }
        }
        if config.source(.aider).enabled {
            for p in paths {
                if let url = AiderParser.historyFile(in: p) { result.append(Source(url: url, agent: .aider, repo: p)) }
            }
        }
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        return result.filter { modificationDate($0.url) ?? .distantPast > cutoff }
    }

    /// Parses all sources, reusing cached results for unchanged files.
    static func index(projects: [ProjectConfig], config: OrbitConfig, progress: ((Int, Int) -> Void)? = nil) -> [AgentSession] {
        let srcs = sources(projects: projects, config: config)
        var cache = Store.load([String: CacheEntry].self, from: cacheName) ?? [:]
        var fresh: [String: CacheEntry] = [:]
        let names = srcs.contains { $0.agent == .codex } ? CodexParser.threadNames() : [:]
        var all: [AgentSession] = []

        for (i, src) in srcs.enumerated() {
            progress?(i, srcs.count)
            let key = src.url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: key)
            let size = attrs?[.size] as? Int ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let sessions: [AgentSession]
            if let hit = cache[key], hit.size == size, hit.mtime == mtime {
                sessions = hit.sessions
            } else {
                switch src.agent {
                case .claude: sessions = ClaudeCodeParser.parse(src.url)
                case .codex: sessions = CodexParser.parse(src.url, names: names)
                case .aider: sessions = AiderParser.parse(src.url, repo: src.repo)
                case .cursor: sessions = []
                }
            }
            fresh[key] = CacheEntry(size: size, mtime: mtime, sessions: sessions)
            all += sessions
            cache[key] = nil
        }
        progress?(srcs.count, srcs.count)
        Store.save(fresh, to: cacheName, pretty: false)

        let paths = projects.map(\.path)
        return all.compactMap { s in
            var s = s
            guard let p = project(for: s.cwd, in: paths) else { return nil }
            s.projectId = p
            return s
        }
        .sorted { $0.start > $1.start }
    }

    /// The project whose path is the longest prefix of `cwd`.
    static func project(for cwd: String, in paths: [String]) -> String? {
        paths.filter { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Derives session status and links sessions to commits.
enum SessionAnalyzer {
    static func analyze(_ sessions: [AgentSession], repos: [String: RepoStatus], now: Date = Date()) -> (sessions: [AgentSession], repos: [String: RepoStatus]) {
        var repos = repos
        var result = sessions

        // Attribute commits without trailers to an agent whose session window contains them.
        for (pid, var status) in repos {
            let projectSessions = sessions.filter { $0.projectId == pid }
            for i in status.commits.indices where status.commits[i].agent == nil {
                let date = status.commits[i].date
                if let s = projectSessions.first(where: { date >= $0.start.addingTimeInterval(-60) && date <= $0.end.addingTimeInterval(15 * 60) }) {
                    status.commits[i].agent = s.agent
                }
            }
            if let last = status.lastCommit, let match = status.commits.first(where: { $0.hash == last.hash }) {
                status.lastCommit = match
            }
            repos[pid] = status
        }

        // Latest session per file decides who "owns" the uncommitted change.
        var latestToucher: [String: String] = [:]
        for s in result.sorted(by: { $0.start < $1.start }) {
            for f in s.filesTouched { latestToucher[relative(f, session: s)] = s.id }
        }

        for i in result.indices {
            let s = result[i]
            let status = repos[s.projectId]
            let window = (status?.commits ?? []).filter {
                $0.date >= s.start.addingTimeInterval(-60) && $0.date <= s.end.addingTimeInterval(30 * 60)
            }
            result[i].commitsInWindow = window.map(\.hash)
            let committedInSession = !window.isEmpty || s.events.contains { $0.kind == .commit }

            let changed = Set(status?.changes.map(\.path) ?? [])
            let touched = s.filesTouched.map { relative($0, session: s) }
            let leftUncommitted = touched.contains { changed.contains($0) && latestToucher[$0] == s.id }

            if now.timeIntervalSince(s.end) < 10 * 60 {
                result[i].status = .active
            } else if s.reverts >= 2 && !committedInSession {
                result[i].status = .rolledBack
            } else if s.reverts >= 1 && !committedInSession && !touched.isEmpty && !touched.contains(where: { changed.contains($0) }) && s.linesAdded < 80 {
                result[i].status = .rolledBack
            } else if (s.testsFailed ?? 0) > 0 || (leftUncommitted && !committedInSession) {
                result[i].status = .unfinished
            } else {
                result[i].status = .done
            }
        }
        return (result, repos)
    }

    /// Path relative to the project root.
    static func relative(_ file: String, session: AgentSession) -> String {
        let root = session.projectId
        let absolute = file.hasPrefix("/") ? file : (session.cwd as NSString).appendingPathComponent(file)
        let standardized = (absolute as NSString).standardizingPath
        if standardized.hasPrefix(root + "/") { return String(standardized.dropFirst(root.count + 1)) }
        return file
    }
}
