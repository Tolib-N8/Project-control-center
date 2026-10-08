import Foundation

/// Puts the project memory where agents look at startup, without touching anything else in the repository:
/// .orbit/memory.md, an import line in CLAUDE.local.md (Claude Code) and the text itself in AGENTS.md (Codex,
/// which has no imports). Orbit's parts sit between markers; files Orbit adds are hidden from git via .git/info/exclude.
enum MemoryWriter {
    static let begin = "<!-- orbit:memory -->"
    static let end = "<!-- /orbit:memory -->"
    static let memoryPath = ".orbit/memory.md"

    struct Result {
        var memoryFile: String
        var claudeFile: String
        var agentsFile: String
    }

    /// Writes into `root` (the repository, or a scratch folder for `--memory-out`).
    @discardableResult
    static func write(_ markdown: String, to root: String, gitRepo: String? = nil) throws -> Result {
        let fm = FileManager.default
        let dir = (root as NSString).appendingPathComponent(".orbit")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let memory = (root as NSString).appendingPathComponent(memoryPath)
        try markdown.write(toFile: memory, atomically: true, encoding: .utf8)

        let claude = (root as NSString).appendingPathComponent("CLAUDE.local.md")
        let claudeBlock = tr("Память проекта от Orbit — прочитай перед работой:", "Project memory from Orbit — read it before you start:") + "\n@\(memoryPath)"
        try upsertBlock(claudeBlock, in: claude)

        let agents = (root as NSString).appendingPathComponent("AGENTS.md")
        let agentsExisted = fm.fileExists(atPath: agents)
        try upsertBlock(markdown.trimmingCharacters(in: .whitespacesAndNewlines), in: agents)

        if let repo = gitRepo {
            var hide = [".orbit/", "CLAUDE.local.md"]
            if !agentsExisted || !isTracked("AGENTS.md", in: repo) { hide.append("AGENTS.md") }
            try exclude(hide, in: repo)
        }
        return Result(memoryFile: memory, claudeFile: claude, agentsFile: agents)
    }

    /// Takes Orbit's blocks and files out again (memory turned off for the project).
    static func remove(from root: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: (root as NSString).appendingPathComponent(".orbit"))
        for name in ["CLAUDE.local.md", "AGENTS.md"] {
            let path = (root as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let rest = stripBlock(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { try fm.removeItem(atPath: path) } else { try (rest + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: - Blocks

    /// Replaces Orbit's block, or appends one after the file's own text (creating the file if needed).
    static func upsertBlock(_ content: String, in path: String) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try withBlock(content, in: existing).write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func withBlock(_ content: String, in text: String) -> String {
        let block = "\(begin)\n\(content)\n\(end)"
        if let range = blockRange(in: text) {
            return text.replacingCharacters(in: range, with: block)
        }
        let own = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? block + "\n" : own + "\n\n" + block + "\n"
    }

    static func stripBlock(_ text: String) -> String {
        guard let range = blockRange(in: text) else { return text }
        var out = text
        out.removeSubrange(range)
        return out
    }

    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        return start.lowerBound..<stop.upperBound
    }

    /// True when a tracked file differs from HEAD only by Orbit's block — not a change worth flagging.
    static func onlyOrbitChanged(_ file: String, in repo: String) -> Bool {
        let path = (repo as NSString).appendingPathComponent(file)
        guard let current = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let head = Shell.git(repo, ["show", "HEAD:\(file)"], timeout: 5)
        guard head.ok else { return false }
        func norm(_ s: String) -> String { stripBlock(s).trimmingCharacters(in: .whitespacesAndNewlines) }
        return norm(current) == norm(head.stdout)
    }

    /// Orbit's own files never count as uncommitted work: .orbit/ and CLAUDE.local.md are excluded from git anyway,
    /// and a tracked AGENTS.md that differs only by Orbit's block is dropped from the list.
    static func hidingOwnChanges(_ status: RepoStatus, repo: String) -> RepoStatus {
        guard status.changes.contains(where: isOrbitPath) else { return status }
        var s = status
        s.changes.removeAll { change in
            guard isOrbitPath(change) else { return false }
            return change.path != "AGENTS.md" || change.status == "?" || onlyOrbitChanged("AGENTS.md", in: repo)
        }
        return s
    }

    private static func isOrbitPath(_ c: FileChange) -> Bool {
        c.path.hasPrefix(".orbit/") || c.path == ".orbit" || c.path == "CLAUDE.local.md" || c.path == "AGENTS.md"
    }

    // MARK: - git

    static func isTracked(_ file: String, in repo: String) -> Bool {
        Shell.git(repo, ["ls-files", "--error-unmatch", file], timeout: 5).ok
    }

    /// Adds lines to .git/info/exclude once.
    static func exclude(_ entries: [String], in repo: String) throws {
        let gitDir = Shell.git(repo, ["rev-parse", "--git-dir"], timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDir.isEmpty else { return }
        let base = gitDir.hasPrefix("/") ? gitDir : (repo as NSString).appendingPathComponent(gitDir)
        let info = (base as NSString).appendingPathComponent("info")
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let file = (info as NSString).appendingPathComponent("exclude")
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let missing = excludeAdditions(entries, existing: text)
        guard !missing.isEmpty else { return }
        let header = text.contains("# Orbit") ? "" : "\n# Orbit: project memory for agents\n"
        let updated = (text.hasSuffix("\n") || text.isEmpty ? text : text + "\n") + header + missing.joined(separator: "\n") + "\n"
        try updated.write(toFile: file, atomically: true, encoding: .utf8)
    }

    static func excludeAdditions(_ entries: [String], existing: String) -> [String] {
        let lines = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return entries.filter { !lines.contains($0) && !lines.contains("/" + $0) }
    }
}
