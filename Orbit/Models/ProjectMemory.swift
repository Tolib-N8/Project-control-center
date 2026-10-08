import Foundation

/// What a fresh Claude Code or Codex session should know about a project, kept by Orbit in .orbit/memory.md.
struct ProjectMemory: Codable, Hashable {
    struct Done: Codable, Hashable {
        var date: String
        var text: String
    }

    struct Check: Codable, Hashable {
        var command: String
        var note: String
    }

    var summary: String
    var state: [String]
    var done: [Done]
    var verify: [Check]
    var decisions: [String]
    var pitfalls: [String]
    var next: [String]

    /// The same memory with secrets and home paths taken out of every field — what Orbit stores, shows and sends back.
    func redacted() -> ProjectMemory {
        let r = Redact.text
        return ProjectMemory(summary: r(summary), state: state.map(r),
                             done: done.map { Done(date: $0.date, text: r($0.text)) },
                             verify: verify.map { Check(command: r($0.command), note: r($0.note)) },
                             decisions: decisions.map(r), pitfalls: pitfalls.map(r), next: next.map(r))
    }
}

/// Bookkeeping per project in ~/.orbit/memory-state.json.
struct MemoryRecord: Codable, Hashable {
    var memory: ProjectMemory
    var updatedAt: Date
    /// "Claude", "Codex"… or "эвристики".
    var source: String
    var sessions: Int
    /// Hash of the inputs; an unchanged project is not analysed again.
    var inputHash: String
    var lang: String?
}

// MARK: - Commands that build and test the project

struct ObservedCommand: Hashable {
    var command: String
    var runs: Int
    var passed: Int
    var failed: Int
    var isTest: Bool
}

enum CommandHistory {
    /// Build, lint and run commands worth remembering (tests are recognised by the session parser already).
    private static let useful = try! NSRegularExpression(pattern:
        #"^(xcodebuild|swift (build|test|run)|npm (run |test|start|ci)|pnpm |yarn |bun (run|test)|npx (tsc|eslint|vitest|jest|playwright|prisma)|cargo (build|test|run|clippy)|go (build|test|run|vet)|make|docker compose|python3? -m (pytest|unittest)|pytest|uv run|poetry run|gradle|\./gradlew|mvn|flutter (build|test|run)|tsc|eslint|ruff|mypy|alembic|rails |bundle exec)"#)

    /// The commands agents ran to build and verify the project, tests first, most used first.
    static func observed(_ sessions: [AgentSession], limit: Int = 8) -> [ObservedCommand] {
        var byCommand: [String: ObservedCommand] = [:]
        for s in sessions {
            for e in s.events where e.kind == .test || e.kind == .bash {
                let command = normalize(e.text)
                guard !command.isEmpty, Redact.isClean(command) else { continue }
                if e.kind == .bash, useful.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) == nil { continue }
                var o = byCommand[command] ?? ObservedCommand(command: command, runs: 0, passed: 0, failed: 0, isTest: e.kind == .test)
                o.runs += max(1, e.count)
                if e.kind == .test {
                    if (e.failed ?? 0) > 0 { o.failed += 1 } else { o.passed += 1 }
                }
                byCommand[command] = o
            }
        }
        return byCommand.values
            .sorted { ($0.isTest ? 1 : 0, $0.runs) > ($1.isTest ? 1 : 0, $1.runs) }
            .prefix(limit).map { $0 }
    }

    /// One line, no `cd /abs/path &&` prefix, no trailing output plumbing.
    static func normalize(_ command: String) -> String {
        var c = command.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let range = c.range(of: #"^cd \S+ *(&&|;) *"#, options: .regularExpression) { c.removeSubrange(range) }
        for tail in [" 2>&1", " | tail", " | head", " | grep", " | xcpretty"] {
            if let r = c.range(of: tail) { c = String(c[..<r.lowerBound]) }
        }
        return c.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Secrets never reach the memory files

enum Redact {
    private static let patterns: [NSRegularExpression] = [
        #"\b(sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"#,
        #"(?i)\b(token|secret|password|passwd|api[_-]?key|access[_-]?key)\b\s*[=:]\s*(?:"[^"]{6,}"|'[^']{6,}'|[^\s"']{6,})"#,
        // Environment variables like SECRET_KEY=…, SUPABASE_KEY=…, DB_PASSWORD=…, GITHUB_TOKEN=…
        #"(?i)\b[A-Z0-9_]*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|PWD|CREDENTIALS?|AUTH|DSN|PRIVATE)[A-Z0-9_]*\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"']+)"#,
        #"(?i)://[^/\s:@]+:[^/\s@]+@"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func text(_ s: String) -> String {
        // Home folders are personal: /Users/name/… becomes ~/…
        var out = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for p in patterns {
            out = p.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tr("[скрыто]", "[redacted]"))
        }
        return out
    }

    static func isClean(_ s: String) -> Bool { text(s) == s }
}

// MARK: - Without a model

enum MemoryHeuristics {
    static func build(_ p: ProjectSnapshot, openTasks: [ProjectTask], health: Int) -> ProjectMemory {
        let r = p.repo
        let sessions = Array(p.sessions.prefix(12))
        var summary = p.config.name
        if !r.stack.isEmpty { summary += " — " + r.stack.joined(separator: ", ") }
        let dirs = InsightEngine.topDirectories(sessions)
        if !dirs.isEmpty { summary += tr(". Чаще всего работа идёт в \(dirs.prefix(3).joined(separator: ", ")).", ". Most work happens in \(dirs.prefix(3).joined(separator: ", ")).") }

        var state = [tr("Ветка \(r.branch)", "Branch \(r.branch)") + (r.mainBranch != nil && r.branch != r.mainBranch ? tr(", отстаёт от main на \(r.behindMain)", ", \(r.behindMain) behind main") : "")]
        state.append(r.changes.isEmpty ? tr("Всё закоммичено", "Everything is committed") : tr("Не закоммичено: \(Plural.files(r.changes.count))", "Uncommitted: \(Plural.files(r.changes.count))"))
        if let last = sessions.first(where: { $0.testsPassed != nil || $0.testsFailed != nil }) {
            let failed = last.testsFailed ?? 0
            state.append(failed > 0 ? tr("Последний прогон тестов: \(failed) падают", "Last test run: \(failed) failing")
                                    : tr("Последний прогон тестов зелёный (\(last.testsPassed ?? 0))", "Last test run is green (\(last.testsPassed ?? 0))"))
        }
        state.append(tr("Здоровье \(health)/100", "Health \(health)/100"))

        let done = sessions.filter { $0.status == .done || !$0.commitsInWindow.isEmpty }.prefix(8).map {
            ProjectMemory.Done(date: AnalysisService.day($0.start), text: "\($0.agent.title): \(InsightEngine.sessionSummary($0, limit: 180))")
        }

        let verify = CommandHistory.observed(sessions).map { c -> ProjectMemory.Check in
            let note: String
            if c.isTest {
                note = c.failed == 0 ? tr("тесты, проходили \(Plural.times(c.passed))", "tests, passed \(c.passed)×")
                                     : tr("тесты, падали \(Plural.times(c.failed)) из \(c.runs)", "tests, failed \(c.failed) of \(c.runs)")
            } else {
                note = tr("запускалась \(Plural.times(c.runs))", "ran \(c.runs)×")
            }
            return ProjectMemory.Check(command: c.command, note: note)
        }

        var pitfalls: [String] = []
        for s in sessions {
            if s.status == .rolledBack { pitfalls.append(tr("«\(s.title)»: правки откатывались — задача, видимо, сформулирована неясно", "“\(s.title)”: edits were rolled back — the task was probably unclear")) }
            if let stuck = InsightEngine.stuck(s) { pitfalls.append(stuck) }
            if let failing = s.lastFailingTest { pitfalls.append(tr("Падал тест \(failing)", "Test \(failing) was failing")) }
        }

        var next = openTasks.prefix(6).map(\.title)
        for step in InsightEngine.nextSteps(p) where !next.contains(step) { next.append(step) }

        return ProjectMemory(summary: summary, state: state, done: Array(done), verify: verify,
                             decisions: [], pitfalls: Array(NSOrderedSet(array: pitfalls).array as! [String]).prefix(6).map { $0 },
                             next: Array(next.prefix(8)))
    }
}

// MARK: - Markdown

enum MemoryMarkdown {
    static let limit = 8000

    /// The memory as agents read it, cut to `limit` characters by dropping the oldest and least important items.
    static func render(_ m: ProjectMemory, project: String, updated: Date, source: String, sessions: Int) -> String {
        var caps = (done: 10, verify: 8, decisions: 8, pitfalls: 8, next: 10, state: 8)
        while true {
            let text = Redact.text(compose(m, caps: caps, project: project, updated: updated, source: source, sessions: sessions))
            if text.count <= limit || (caps.done + caps.pitfalls + caps.decisions + caps.next) <= 4 { return text }
            if caps.done > 3 { caps.done -= 1 } else if caps.pitfalls > 2 { caps.pitfalls -= 1 }
            else if caps.decisions > 2 { caps.decisions -= 1 } else if caps.next > 3 { caps.next -= 1 } else { caps.verify = max(2, caps.verify - 1); caps.state = 4 }
        }
    }

    private static func compose(_ m: ProjectMemory, caps: (done: Int, verify: Int, decisions: Int, pitfalls: Int, next: Int, state: Int),
                                project: String, updated: Date, source: String, sessions: Int) -> String {
        var out = [
            tr("# Память проекта \(project)", "# Project memory: \(project)"),
            "",
            tr("> Ведёт Orbit · обновлено \(DateFormat.short(updated)) \(DateFormat.time.string(from: updated)) по \(plural(sessions, ru: ("сессии", "сессиям", "сессиям"), en: ("session", "sessions"))) · \(source).",
               "> Kept by Orbit · updated \(DateFormat.short(updated)) \(DateFormat.time.string(from: updated)) from \(Plural.sessions(sessions)) · \(source)."),
            tr("> Не редактируйте этот блок — он перезаписывается. Свои заметки пишите в CLAUDE.md или AGENTS.md вне блока Orbit.",
               "> Don't edit this block — it is rewritten. Keep your own notes in CLAUDE.md or AGENTS.md outside the Orbit block."),
            "",
            m.summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        func section(_ title: String, _ lines: [String]) {
            let items = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return }
            out += ["", "## \(title)", ""] + items.map { "- \($0)" }
        }
        section(tr("Текущее состояние", "Current state"), Array(m.state.prefix(caps.state)))
        section(tr("Что сделано", "What's done"), m.done.prefix(caps.done).map { "\($0.date): \($0.text)" })
        section(tr("Как проверять", "How to verify"), m.verify.prefix(caps.verify).map { "`\($0.command)` — \($0.note)" })
        section(tr("Решения и договорённости", "Decisions"), Array(m.decisions.prefix(caps.decisions)))
        section(tr("Подводные камни", "Pitfalls"), Array(m.pitfalls.prefix(caps.pitfalls)))
        section(tr("Что дальше", "What's next"), Array(m.next.prefix(caps.next)))
        return out.joined(separator: "\n") + "\n"
    }
}
