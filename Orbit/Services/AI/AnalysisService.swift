import CryptoKit
import Foundation

struct ProjectAI: Codable, Hashable {
    /// Language the answer is written in; nil for answers cached before localization (Russian).
    var lang: String?
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
    var lang: String?
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

    /// Prompts are written in the interface language, so answers come back in it too.
    static var system: String {
        tr("""
        Ты — аналитик в приложении Orbit. Оно помогает разработчику вести несколько проектов, \
        в которых работают ИИ-агенты (Claude Code, Codex, Aider). Тебе дают факты о проекте: состояние git, \
        сессии агентов и их итоги. Пиши по-русски, коротко и конкретно, как опытный тимлид. \
        Опирайся только на переданные факты: не придумывай файлы, тесты и события, которых нет во входных данных. \
        Называй файлы, ветки и команды точно так же, как они даны. Без вступлений и общих слов.
        """, """
        You are the analyst inside Orbit, an app that helps a developer run several projects where AI agents \
        (Claude Code, Codex, Aider) do much of the work. You get facts about a project: git state, agent sessions \
        and their outcomes. Write in English, briefly and concretely, like an experienced tech lead. \
        Rely only on the facts given: never invent files, tests or events that are not in the input. \
        Name files, branches and commands exactly as given. No preambles, no filler.
        """)
    }

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
        let prompt = tr("""
        Сделай вывод о проекте по фактам ниже. Заполни поля:
        - headline: одна строка до 60 символов для таблицы — в каком состоянии проект прямо сейчас;
        - summary: 1–2 предложения для карточки проекта — где сейчас идёт работа и главный риск;
        - digest: 2–4 предложения о последних сессиях агентов — что продвинулось, где агенты буксовали \
        и что дать агенту в следующий раз, чтобы он не застрял;
        - next_steps: до трёх конкретных шагов на ближайшую рабочую сессию, каждый до 60 символов, в повелительном наклонении;
        - goal: цель на рабочий день одной фразой до 90 символов.

        Факты (JSON):
        \(facts)
        """, """
        Assess the project from the facts below. Fill in the fields:
        - headline: one line up to 60 characters for a table — the state of the project right now;
        - summary: 1–2 sentences for the project card — where the work is happening and the main risk;
        - digest: 2–4 sentences about the latest agent sessions — what moved forward, where the agents got stuck \
        and what to give the agent next time so it doesn't get stuck;
        - next_steps: up to three concrete steps for the next work session, each up to 60 characters, in the imperative;
        - goal: the goal for the work day in one phrase up to 90 characters.

        Facts (JSON):
        \(facts)
        """)
        return (AIRequest(system: system, prompt: prompt, schema: projectSchema, schemaName: "project_insight"), hash(facts + languageSalt))
    }

    static func parseProject(_ obj: [String: Any], source: String, hash: String) throws -> ProjectAI {
        guard let headline = obj["headline"] as? String, let summary = obj["summary"] as? String else {
            throw AIError.badResponse(tr("нет полей headline/summary", "missing headline/summary"))
        }
        return ProjectAI(lang: L10n.current.rawValue, headline: headline.trimmed, summary: summary.trimmed,
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
            "recent_commits": r.commits.prefix(8).map { "\(day($0.date)) [\($0.agent?.title ?? tr("человек", "human"))] \($0.subject)" },
        ]
        if let main = r.mainBranch {
            git["main_branch"] = main
            git["behind_main"] = r.behindMain
            git["conflict_files_with_main"] = r.conflictFiles
        }
        if let age = r.changesAgeHours { git["uncommitted_age_days"] = Int(age / 24) }
        let stale = p.abandonedBranches.prefix(5).map { "\($0.name) (\($0.merged ? tr("смержена", "merged") : tr("не смержена", "not merged")), \(tr("с", "since")) \(day($0.lastCommit)))" }
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
        let prompt = tr("""
        Разбери сессию ИИ-агента по фактам ниже. Заполни поля:
        - done: 2–4 пункта, что агент реально сделал (без маркеров списка в начале строки);
        - stuck: если сессия не завершена или с откатами — где и почему агент застрял, 1–3 предложения; иначе пустая строка;
        - recommendation: 1–2 предложения — с чего начать следующую сессию и что передать агенту.

        Факты (JSON):
        \(json)
        """, """
        Review the AI agent session from the facts below. Fill in the fields:
        - done: 2–4 points on what the agent actually did (no list markers at the start of a line);
        - stuck: if the session is unfinished or had rollbacks — where and why the agent got stuck, 1–3 sentences; otherwise an empty string;
        - recommendation: 1–2 sentences — where to start the next session and what to hand the agent.

        Facts (JSON):
        \(json)
        """)
        return (AIRequest(system: system, prompt: prompt, schema: sessionSchema, schemaName: "session_insight"), hash(json + languageSalt))
    }

    static func parseSession(_ obj: [String: Any], source: String, hash: String) throws -> SessionAI {
        guard let done = obj["done"] as? [String] else { throw AIError.badResponse(tr("нет поля done", "missing done")) }
        return SessionAI(lang: L10n.current.rawValue, done: done.map(\.trimmed).filter { !$0.isEmpty },
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
        let prompt = tr("""
        Напиши сообщение коммита в стиле Conventional Commits для этих изменений. \
        Первая строка до 72 символов: тип(область): что сделано. Затем пустая строка и 2–5 пунктов «- …» о сути изменений. \
        Язык — как в недавних коммитах проекта; если не ясно — по-русски. Верни поле message.

        Факты (JSON):
        \(JSONText.encode(facts))
        """, """
        Write a Conventional Commits message for these changes. \
        First line up to 72 characters: type(scope): what was done. Then a blank line and 2–5 "- …" points on the substance. \
        Use the language of the project's recent commits; if unclear, English. Return the message field.

        Facts (JSON):
        \(JSONText.encode(facts))
        """)
        return AIRequest(system: system, prompt: prompt, schema: messageSchema, schemaName: "commit_message")
    }

    static func briefRequest(signal: Signal, snapshot: ProjectSnapshot) -> AIRequest {
        let facts: [String: Any] = [
            "signal": ["title": signal.title, "detail": signal.detail],
            "project": projectFacts(snapshot, health: HealthEngine.score(snapshot), signals: [signal]),
        ]
        let prompt = tr("""
        Агент несколько сессий подряд не может довести задачу до конца. Составь для него бриф в Markdown \
        с разделами «## Задача», «## Что уже пробовали», «## Файлы», «## Критерий готовности», «## Ограничения». \
        Критерий готовности — проверяемые пункты. Верни поле brief.

        Факты (JSON):
        \(JSONText.encode(facts))
        """, """
        For several sessions in a row the agent hasn't managed to finish the task. Write it a brief in Markdown \
        with the sections "## Task", "## What was tried", "## Files", "## Definition of done", "## Constraints". \
        The definition of done must be checkable points. Return the brief field.

        Facts (JSON):
        \(JSONText.encode(facts))
        """)
        return AIRequest(system: system, prompt: prompt, schema: briefSchema, schemaName: "agent_brief")
    }

    // MARK: - Helpers

    private static let string: [String: Any] = ["type": "string"]

    private static func object(_ props: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": props, "required": props.keys.sorted(), "additionalProperties": false]
    }

    static func day(_ d: Date) -> String { DateFormat.isoDay.string(from: d) }

    /// Russian keeps the hashes it had before localization, so existing answers stay cached.
    static var languageSalt: String { L10n.current == .ru ? "" : "|lang:\(L10n.current.rawValue)" }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data((promptVersion + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
