import CryptoKit
import Foundation

struct ProjectAI: Codable, Hashable {
    var headline: String
    var summary: String
    var digest: String
    var nextSteps: [String]
    var goal: String
    var source: String
    var createdAt: Date
    var inputHash: String
}

struct SessionAI: Codable, Hashable {
    var done: [String]
    var stuck: String
    var recommendation: String
    var source: String
    var createdAt: Date
    var inputHash: String
}

struct AICache: Codable {
    var projects: [String: ProjectAI] = [:]
    var sessions: [String: SessionAI] = [:]
}

/// Builds prompts from Orbit's facts and turns model answers into typed results.
/// Only summaries leave the Mac: titles, file names, agent final messages, commit subjects — not code.
enum AnalysisService {
    /// Bump when prompts change so cached answers are regenerated.
    static let promptVersion = "1"

    static let system = """
    Ты — аналитик в приложении Orbit. Оно помогает разработчику вести несколько проектов, \
    в которых работают ИИ-агенты (Claude Code, Codex, Aider). Тебе дают факты о проекте: состояние git, \
    сессии агентов и их итоги. Пиши по-русски, коротко и конкретно, как опытный тимлид. \
    Опирайся только на переданные факты: не придумывай файлы, тесты и события, которых нет во входных данных. \
    Называй файлы, ветки и команды точно так же, как они даны. Без вступлений и общих слов.
    """

    // MARK: - Project

    static let projectSchema: [String: Any] = object([
        "headline": string,
        "summary": string,
        "digest": string,
        "next_steps": ["type": "array", "items": string],
        "goal": string,
    ])

    static func projectRequest(_ p: ProjectSnapshot, health: Int, signals: [Signal]) -> (AIRequest, String) {
        let facts = JSONText.encode(projectFacts(p, health: health, signals: signals))
        let prompt = """
        Сделай вывод о проекте по фактам ниже. Заполни поля:
        - headline: одна строка до 60 символов для таблицы — в каком состоянии проект прямо сейчас;
        - summary: 1–2 предложения для карточки проекта — где сейчас идёт работа и главный риск;
        - digest: 2–4 предложения о последних сессиях агентов — что продвинулось, где агенты буксовали \
        и что дать агенту в следующий раз, чтобы он не застрял;
        - next_steps: до трёх конкретных шагов на ближайшую рабочую сессию, каждый до 60 символов, в повелительном наклонении;
        - goal: цель на рабочий день одной фразой до 90 символов.

        Факты (JSON):
        \(facts)
        """
        return (AIRequest(system: system, prompt: prompt, schema: projectSchema, schemaName: "project_insight"), hash(facts))
    }

    static func parseProject(_ obj: [String: Any], source: String, hash: String) throws -> ProjectAI {
        guard let headline = obj["headline"] as? String, let summary = obj["summary"] as? String else {
            throw AIError.badResponse("нет полей headline/summary")
        }
        return ProjectAI(headline: headline.trimmed, summary: summary.trimmed,
                         digest: (obj["digest"] as? String ?? "").trimmed,
                         nextSteps: (obj["next_steps"] as? [String] ?? []).map(\.trimmed).filter { !$0.isEmpty }.prefix(3).map { $0 },
                         goal: (obj["goal"] as? String ?? "").trimmed,
                         source: source, createdAt: Date(), inputHash: hash)
    }

    /// Facts with coarse time values, so the hash only changes when something meaningful changed.
    static func projectFacts(_ p: ProjectSnapshot, health: Int, signals: [Signal]) -> [String: Any] {
        let r = p.repo
        var git: [String: Any] = [
            "branch": r.branch,
            "ahead_of_origin": r.ahead,
            "behind_origin": r.behind,
            // git status letters; "?" = untracked, never added to the index.
            "uncommitted_files": r.changes.prefix(20).map { "\($0.status == "?" ? "untracked" : $0.status) \($0.path)" },
            "uncommitted_count": r.changes.count,
            "recent_commits": r.commits.prefix(8).map { "\(day($0.date)) [\($0.agent?.title ?? "человек")] \($0.subject)" },
        ]
        if let main = r.mainBranch {
            git["main_branch"] = main
            git["behind_main"] = r.behindMain
            git["conflict_files_with_main"] = r.conflictFiles
        }
        if let age = r.changesAgeHours { git["uncommitted_age_days"] = Int(age / 24) }
        let stale = p.abandonedBranches.prefix(5).map { "\($0.name) (\($0.merged ? "смержена" : "не смержена"), с \(day($0.lastCommit)))" }
        if !stale.isEmpty { git["stale_branches"] = stale }

        return [
            "project": p.config.name,
            "stack": r.stack,
            "health_score": health,
            "health_reasons": HealthEngine.breakdown(p).reasons,
            "idle_days": min(p.idleDays(), 999),
            "today": day(Date()),
            "git": git,
            "recent_sessions": p.sessions.prefix(5).map(sessionFacts),
            "active_signals": signals.map(\.title),
        ]
    }

    // MARK: - Session

    static let sessionSchema: [String: Any] = object([
        "done": ["type": "array", "items": string],
        "stuck": string,
        "recommendation": string,
    ])

    static func sessionRequest(_ s: AgentSession) -> (AIRequest, String) {
        var facts = sessionFacts(s)
        facts["timeline"] = InsightEngine.timeline(s, limit: 20).map { "\(DateFormat.time.string(from: $0.time)) \($0.text)" }
        let json = JSONText.encode(facts)
        let prompt = """
        Разбери сессию ИИ-агента по фактам ниже. Заполни поля:
        - done: 2–4 пункта, что агент реально сделал (без маркеров списка в начале строки);
        - stuck: если сессия не завершена или с откатами — где и почему агент застрял, 1–3 предложения; иначе пустая строка;
        - recommendation: 1–2 предложения — с чего начать следующую сессию и что передать агенту.

        Факты (JSON):
        \(json)
        """
        return (AIRequest(system: system, prompt: prompt, schema: sessionSchema, schemaName: "session_insight"), hash(json))
    }

    static func parseSession(_ obj: [String: Any], source: String, hash: String) throws -> SessionAI {
        guard let done = obj["done"] as? [String] else { throw AIError.badResponse("нет поля done") }
        return SessionAI(done: done.map(\.trimmed).filter { !$0.isEmpty },
                         stuck: (obj["stuck"] as? String ?? "").trimmed,
                         recommendation: (obj["recommendation"] as? String ?? "").trimmed,
                         source: source, createdAt: Date(), inputHash: hash)
    }

    static func sessionFacts(_ s: AgentSession) -> [String: Any] {
        var f: [String: Any] = [
            "agent": s.agent.title,
            "title": s.title,
            "date": day(s.start),
            "duration_min": s.durationMinutes,
            "status": s.status.title,
            "task": String(s.firstPrompt.prefix(400)),
            // Files outside the repository (agent plans, memory) are noise for the analysis.
            "files_changed": s.filesTouched.map { SessionAnalyzer.relative($0, session: s) }.filter { !$0.hasPrefix("/") }.prefix(12).map { $0 },
            "lines": "+\(s.linesAdded) -\(s.linesRemoved)",
            "reverts": s.reverts,
            "commits_made": s.commitsInWindow.count,
        ]
        if let msg = s.finalMessage { f["agent_final_message"] = String(msg.prefix(700)) }
        if s.testsPassed != nil || s.testsFailed != nil {
            f["tests"] = ["passed": s.testsPassed ?? 0, "failed": s.testsFailed ?? 0, "failing": s.lastFailingTest ?? ""]
        }
        if let hot = s.hottestFile, hot.edits >= 3 { f["most_edited_file"] = "\(SessionAnalyzer.relative(hot.path, session: s)) ×\(hot.edits)" }
        if let e = s.lastError { f["last_error"] = String(e.prefix(240)) }
        return f
    }

    // MARK: - Commit message & brief

    static let messageSchema: [String: Any] = object(["message": string])
    static let briefSchema: [String: Any] = object(["brief": string])

    static func commitRequest(project: String, changes: [FileChange], diff: String?, sessions: [AgentSession]) -> AIRequest {
        var facts: [String: Any] = [
            "project": project,
            "files": changes.prefix(40).map { "\($0.status) \($0.path) (+\($0.added) -\($0.removed))" },
            "recent_agent_sessions": sessions.prefix(2).map { ["title": $0.title, "agent_final_message": String(($0.finalMessage ?? "").prefix(500))] },
        ]
        if let diff { facts["diff"] = String(diff.prefix(12_000)) }
        let prompt = """
        Напиши сообщение коммита в стиле Conventional Commits для этих изменений. \
        Первая строка до 72 символов: тип(область): что сделано. Затем пустая строка и 2–5 пунктов «- …» о сути изменений. \
        Язык — как в недавних коммитах проекта; если не ясно — по-русски. Верни поле message.

        Факты (JSON):
        \(JSONText.encode(facts))
        """
        return AIRequest(system: system, prompt: prompt, schema: messageSchema, schemaName: "commit_message")
    }

    static func briefRequest(signal: Signal, snapshot: ProjectSnapshot) -> AIRequest {
        let facts: [String: Any] = [
            "signal": ["title": signal.title, "detail": signal.detail],
            "project": projectFacts(snapshot, health: HealthEngine.score(snapshot), signals: [signal]),
        ]
        let prompt = """
        Агент несколько сессий подряд не может довести задачу до конца. Составь для него бриф в Markdown \
        с разделами «## Задача», «## Что уже пробовали», «## Файлы», «## Критерий готовности», «## Ограничения». \
        Критерий готовности — проверяемые пункты. Верни поле brief.

        Факты (JSON):
        \(JSONText.encode(facts))
        """
        return AIRequest(system: system, prompt: prompt, schema: briefSchema, schemaName: "agent_brief")
    }

    // MARK: - Helpers

    private static let string: [String: Any] = ["type": "string"]

    private static func object(_ props: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": props, "required": props.keys.sorted(), "additionalProperties": false]
    }

    static func day(_ d: Date) -> String { DateFormat.isoDay.string(from: d) }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data((promptVersion + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
