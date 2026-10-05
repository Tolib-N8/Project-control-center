import Foundation

/// Everything known about one project at a point in time.
struct ProjectSnapshot {
    var config: ProjectConfig
    var repo: RepoStatus
    /// Newest first.
    var sessions: [AgentSession]

    var lastActivity: Date? {
        [repo.lastCommit?.date, sessions.first?.end].compactMap { $0 }.max()
    }

    func idleDays(at now: Date = Date()) -> Int {
        guard let last = lastActivity(before: now) else { return 999 }
        return max(0, Int(now.timeIntervalSince(last) / 86400))
    }

    func lastActivity(before date: Date) -> Date? {
        let commit = repo.commits.first { $0.date <= date }?.date ?? repo.lastCommit.flatMap { $0.date <= date ? $0.date : nil }
        let session = sessions.first { $0.end <= date }?.end
        return [commit, session].compactMap { $0 }.max()
    }

    func sessions(in days: Int, before date: Date = Date()) -> [AgentSession] {
        let from = date.addingTimeInterval(-Double(days) * 86400)
        return sessions.filter { $0.start >= from && $0.start <= date }
    }

    func commits(in days: Int, before date: Date = Date()) -> [Commit] {
        let from = date.addingTimeInterval(-Double(days) * 86400)
        return repo.commits.filter { $0.date >= from && $0.date <= date }
    }

    /// Last session that ran tests.
    var lastTestedSession: AgentSession? { sessions.first { $0.testsFailed != nil || $0.testsPassed != nil } }

    var testsFailing: Int { lastTestedSession?.testsFailed ?? 0 }
    var testsTotal: Int? {
        guard let s = lastTestedSession else { return nil }
        return (s.testsPassed ?? 0) + (s.testsFailed ?? 0)
    }

    var abandonedBranches: [BranchInfo] {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return repo.branches.filter { $0.name != repo.branch && $0.name != repo.mainBranch && $0.lastCommit < cutoff }
    }
}

/// Heuristic project health, 0–100.
enum HealthEngine {
    struct Breakdown {
        var score: Int
        var reasons: [String]
    }

    static func score(_ p: ProjectSnapshot, at date: Date = Date()) -> Int {
        breakdown(p, at: date).score
    }

    static func breakdown(_ p: ProjectSnapshot, at date: Date = Date()) -> Breakdown {
        var score = 92.0
        var reasons: [String] = []

        // Working-tree penalties are only known for "now"; history reuses them as a constant offset.
        if !p.repo.changes.isEmpty, let age = p.repo.changesAgeHours {
            if age > 24 {
                let pen = min(20, 8 + age / 12)
                score -= pen
                reasons.append(tr("изменения не закоммичены дольше суток", "changes uncommitted for over a day"))
            } else {
                score -= 2
            }
        }
        if p.repo.behindMain >= 5 {
            score -= min(25, Double(p.repo.behindMain) * 0.5)
            reasons.append(tr("отстаёт от main на \(p.repo.behindMain)", "\(p.repo.behindMain) behind main"))
        }
        if p.repo.conflictFiles > 0 {
            score -= min(10, Double(p.repo.conflictFiles) * 3)
            reasons.append(tr("конфликты: \(p.repo.conflictFiles)", "conflicts: \(p.repo.conflictFiles)"))
        }

        let past = p.sessions.filter { $0.end <= date }
        if let tested = past.first(where: { $0.testsFailed != nil }), (tested.testsFailed ?? 0) > 0 {
            score -= 10
            reasons.append(tr("падают тесты", "tests failing"))
        }

        let idle = p.idleDays(at: date)
        if idle > 7 && idle < 999 {
            score -= min(25, 10 + Double(idle - 7) * 2)
            reasons.append(tr("\(idle) дн. без работы", "idle for \(idle) days"))
        } else if idle >= 999 {
            score -= 20
        } else if idle > 3 {
            score -= 3
        }

        let week = p.sessions(in: 7, before: date)
        if !week.isEmpty {
            let bad = week.filter { $0.status == .rolledBack || $0.status == .unfinished }.count
            let ratio = Double(bad) / Double(week.count)
            score -= (15 * ratio).rounded()
            if ratio >= 0.5 { reasons.append(tr("много незавершённых сессий", "many unfinished sessions")) }
            score += Double(min(5, week.filter { $0.status == .done }.count))
        }
        score += Double(min(3, p.commits(in: 7, before: date).count))

        return Breakdown(score: Int(max(0, min(100, score)).rounded()), reasons: reasons)
    }

    /// Scores for the last `days` days, oldest first.
    static func history(_ p: ProjectSnapshot, days: Int = 14) -> [Int] {
        let cal = Week.calendar
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset in
            if offset == 0 { return score(p) }
            let day = cal.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(86399)
            return score(p, at: day)
        }
    }

    static func trend(_ p: ProjectSnapshot) -> Int {
        let h = history(p, days: 8)
        return (h.last ?? 0) - (h.first ?? 0)
    }

    static func label(_ score: Int) -> String {
        if score >= 75 { return tr("В хорошей форме", "In good shape") }
        if score >= 50 { return tr("Требует внимания", "Needs attention") }
        return tr("Критично", "Critical")
    }
}
