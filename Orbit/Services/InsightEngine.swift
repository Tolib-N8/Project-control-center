import Foundation

/// Rule-based text conclusions about projects and sessions (stands in for an LLM in v1).
enum InsightEngine {
    // MARK: - Projects

    /// One line for tables ("Стабильный прогресс, тесты растут").
    static func headline(_ p: ProjectSnapshot) -> String {
        let idle = p.idleDays()
        if idle >= 999 { return tr("Нет данных об активности", "No activity data") }
        if idle >= 7 { return tr("Нет активности \(Plural.days(idle))", "No activity for \(Plural.days(idle))") }
        if let loop = loopingFile(p) { return tr("Агент зацикливается на \(loop.name)", "Agent is looping on \(loop.name)") }
        if let last = p.sessions.first, last.status == .unfinished, (last.testsFailed ?? 0) > 0 {
            return tr("Остановились на падающих тестах: \(last.testsFailed!)", "Stopped on failing tests: \(last.testsFailed!)")
        }
        if let age = p.repo.changesAgeHours, age > 24 {
            return tr("\(Plural.files(p.repo.changes.count)) не закоммичено больше суток", "\(Plural.files(p.repo.changes.count)) uncommitted for over a day")
        }
        if p.repo.behindMain >= 20 { return tr("Ветка отстала от main на \(Plural.commits(p.repo.behindMain))", "Branch is \(Plural.commits(p.repo.behindMain)) behind main") }
        if testsGrowing(p) { return tr("Стабильный прогресс, тесты растут", "Steady progress, tests growing") }
        let week = p.sessions(in: 7)
        if week.isEmpty && p.commits(in: 7).isEmpty { return tr("Тихая неделя", "Quiet week") }
        let done = week.filter { $0.status == .done }.count
        if !week.isEmpty && done == week.count { return tr("Стабильный прогресс: \(Plural.sessions(week.count)) без проблем", "Steady progress: \(Plural.sessions(week.count)) without issues") }
        if let last = p.sessions.first, last.status == .done, last.commitsInWindow.isEmpty == false {
            return tr("Работа идёт, последняя сессия закоммичена", "Work in progress, last session committed")
        }
        return tr("Работа идёт: \(Plural.sessions(week.count)), \(Plural.commits(p.commits(in: 7).count)) за неделю", "Work in progress: \(Plural.sessions(week.count)), \(Plural.commits(p.commits(in: 7).count)) this week")
    }

    /// Two-sentence summary for project cards.
    static func cardSummary(_ p: ProjectSnapshot) -> String {
        var parts: [String] = []
        let idle = p.idleDays()
        if idle >= 7 && idle < 999 { parts.append(tr("\(Plural.days(idle).capitalizedFirst) без работы.", "Idle for \(Plural.days(idle)).")) }
        if let last = p.sessions.first, idle < 7 {
            parts.append(tr("Последняя сессия — «\(last.title)»", "Last session: “\(last.title)”") + (last.status == .done ? "." : " (\(last.status.title.lowercased())).") )
        }
        if let loop = loopingFile(p) {
            parts.append(tr("Агент \(Plural.times(loop.reverts)) откатывал правки в \(loop.name) — стоит точнее сформулировать задачу.", "The agent reverted its edits in \(loop.name) \(Plural.times(loop.reverts)) — the task needs a sharper definition."))
        } else if p.testsFailing > 0 {
            parts.append(tr("Падают \(Plural.tests(p.testsFailing)).", "\(Plural.tests(p.testsFailing)) failing."))
        }
        if p.repo.behindMain >= 10 { parts.append(tr("Ветка \(p.repo.branch) отстала от main на \(Plural.commits(p.repo.behindMain)).", "Branch \(p.repo.branch) is \(Plural.commits(p.repo.behindMain)) behind main.")) }
        if let age = p.repo.changesAgeHours, age > 24 { parts.append(tr("Изменения не закоммичены \(Duration.age(hours: age)).", "Changes uncommitted for \(Duration.age(hours: age)).")) }
        if parts.isEmpty { parts.append(headline(p) + ".") }
        return parts.prefix(2).joined(separator: " ")
    }

    /// Digest over the latest sessions for the project page.
    static func sessionsDigest(_ p: ProjectSnapshot, count: Int = 5) -> String? {
        let recent = Array(p.sessions.prefix(count))
        guard !recent.isEmpty else { return nil }
        let done = recent.filter { $0.status == .done }.count
        let unfinished = recent.filter { $0.status == .unfinished }.count
        let rolled = recent.filter { $0.status == .rolledBack }.count
        var text = tr("Из \(Plural.sessions(recent.count)): \(done) готово", "Of \(Plural.sessions(recent.count)): \(done) done")
        if unfinished > 0 { text += tr(", \(unfinished) не завершено", ", \(unfinished) unfinished") }
        if rolled > 0 { text += tr(", \(rolled) с откатом", ", \(rolled) rolled back") }
        text += "."
        let dirs = topDirectories(recent)
        if !dirs.isEmpty { text += tr(" Основная работа — в \(dirs.joined(separator: ", ")).", " Most work happened in \(dirs.joined(separator: ", ")).") }
        if let loop = loopingFile(p) {
            text += tr(" Агенты \(Plural.times(loop.reverts)) возвращались к \(loop.name) — дайте им пример или критерий готовности.", " Agents came back to \(loop.name) \(Plural.times(loop.reverts)) — give them an example or a definition of done.")
        } else if let hot = recent.compactMap(\.hottestFile).max(by: { $0.edits < $1.edits }), hot.edits >= 6 {
            text += tr(" Чаще всего правился \((hot.path as NSString).lastPathComponent) (\(Plural.times(hot.edits))).", " Most edited: \((hot.path as NSString).lastPathComponent) (\(Plural.times(hot.edits))).")
        }
        if let age = p.repo.changesAgeHours, age > 24 {
            text += tr(" Изменения не закоммичены больше суток.", " Changes have been uncommitted for over a day.")
        }
        return text
    }

    static func nextSteps(_ p: ProjectSnapshot) -> [String] {
        var steps: [String] = []
        if let s = p.lastTestedSession, (s.testsFailed ?? 0) > 0 {
            if let name = s.lastFailingTest { steps.append(tr("Починить тест \((name as NSString).lastPathComponent)", "Fix test \((name as NSString).lastPathComponent)")) }
            else { steps.append(tr("Починить \(Plural.tests(s.testsFailed!)) из последней сессии", "Fix \(Plural.tests(s.testsFailed!)) from the last session")) }
        }
        if let last = p.sessions.first, last.status == .unfinished || last.status == .rolledBack, steps.count < 2 {
            steps.append(tr("Продолжить: \(last.title)", "Continue: \(last.title)"))
        }
        if !p.repo.changes.isEmpty {
            steps.append(tr("Закоммитить \(Plural.files(p.repo.changes.count))", "Commit \(Plural.files(p.repo.changes.count))") + (p.repo.upstream != nil ? tr(" и запушить", " and push") : ""))
        } else if p.repo.ahead > 0 {
            steps.append(tr("Запушить \(Plural.commits(p.repo.ahead))", "Push \(Plural.commits(p.repo.ahead))"))
        }
        if p.repo.behindMain >= 10, let main = p.repo.mainBranch {
            steps.append(tr("Rebase \(p.repo.branch) на \(main) (−\(p.repo.behindMain))", "Rebase \(p.repo.branch) onto \(main) (−\(p.repo.behindMain))"))
        }
        if let b = p.abandonedBranches.first { steps.append(tr("Разобрать ветку \(b.name)", "Sort out branch \(b.name)")) }
        if steps.isEmpty { steps.append(tr("Выбрать следующую задачу и запустить агента", "Pick the next task and start an agent")) }
        return Array(steps.prefix(3))
    }

    static func workDaysAdvice(_ p: ProjectSnapshot) -> String {
        let sessions = p.sessions(in: 45)
        guard sessions.count >= 3 else { return tr("Мало данных — после нескольких сессий Orbit подскажет лучшие дни.", "Not enough data yet — after a few sessions Orbit will suggest your best days.") }
        let cal = Week.calendar
        var byDay: [Date: (hours: Double, done: Int, total: Int)] = [:]
        for s in sessions {
            let d = cal.startOfDay(for: s.start)
            var v = byDay[d] ?? (0, 0, 0)
            v.hours += s.activeSeconds / 3600
            v.total += 1
            if s.status == .done { v.done += 1 }
            byDay[d] = v
        }
        let long = byDay.values.filter { $0.hours >= 3 }
        let short = byDay.values.filter { $0.hours < 3 }
        func rate(_ xs: [(hours: Double, done: Int, total: Int)]) -> Double {
            let t = xs.reduce(0) { $0 + $1.total }
            return t == 0 ? 0 : Double(xs.reduce(0) { $0 + $1.done }) / Double(t)
        }
        if !long.isEmpty && !short.isEmpty {
            let l = rate(long), s = rate(short)
            if l - s > 0.15 { return tr("По сессиям прогресс лучше в дни с блоками от 3 ч — стоит объединять короткие дни в один длинный.", "Sessions go better on days with 3 h+ blocks — consider merging short days into one long one.") }
            if s - l > 0.15 { return tr("Короткие блоки работают лучше: в длинные дни растёт доля незавершённых сессий.", "Short blocks work better: long days end with more unfinished sessions.") }
        }
        var weekday: [Int: Int] = [:]
        for s in sessions where s.status == .done { weekday[Week.weekdayIndex(s.start), default: 0] += 1 }
        let best = weekday.sorted { $0.value > $1.value }.prefix(2).map { Week.shortNames[$0.key] }
        return best.isEmpty ? tr("Завершённых сессий пока нет.", "No finished sessions yet.") : tr("Больше всего завершённых сессий: \(best.joined(separator: ", ")).", "Most finished sessions: \(best.joined(separator: ", ")).")
    }

    /// Short note for the planner row.
    static func plannerNote(_ p: ProjectSnapshot, signals: [Signal]) -> String {
        if let s = signals.first(where: { $0.severity == .critical }) {
            switch s.kind {
            case .behindMain: return tr("срочно: rebase", "urgent: rebase")
            case .uncommitted: return tr("срочно: закоммитить", "urgent: commit")
            case .testsFailing: return tr("срочно: тесты", "urgent: tests")
            default: return tr("срочно", "urgent")
            }
        }
        if p.idleDays() >= 7 && p.idleDays() < 999 { return tr("давно не трогали", "untouched for a while") }
        if p.testsFailing > 0 { return tr("починить тесты", "fix tests") }
        if let last = p.sessions.first, last.status == .unfinished { return tr("довести сессию", "finish the session") }
        return HealthEngine.score(p) >= 85 ? tr("по желанию", "optional") : tr("плановая работа", "planned work")
    }

    // MARK: - Sessions

    /// "Перенёс токены в Redis, добавил 14 тестов…" — agent's own final message when present.
    static func sessionSummary(_ s: AgentSession, limit: Int = 220) -> String {
        if let msg = s.finalMessage {
            let plain = msg.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•#")) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return plain.count > limit ? String(plain.prefix(limit - 1)) + "…" : plain
        }
        return factualSummary(s)
    }

    static func factualSummary(_ s: AgentSession) -> String {
        var parts: [String] = []
        if !s.filesTouched.isEmpty { parts.append(tr("Изменил \(Plural.files(s.filesTouched.count)) (+\(s.linesAdded) −\(s.linesRemoved))", "Changed \(Plural.files(s.filesTouched.count)) (+\(s.linesAdded) −\(s.linesRemoved))")) }
        else if s.filesRead > 0 { parts.append(tr("Изучил \(Plural.files(s.filesRead))", "Read \(Plural.files(s.filesRead))")) }
        if let f = s.testsFailed, f > 0 { parts.append(tr("\(Plural.tests(f)) падают", "\(Plural.tests(f)) failing")) }
        else if let p = s.testsPassed, p > 0 { parts.append(tr("тесты: \(p) ✓", "tests: \(p) ✓")) }
        if s.reverts > 0 { parts.append(tr("\(Plural.times(s.reverts)) откатывал правки", "reverted edits \(Plural.times(s.reverts))")) }
        if parts.isEmpty { return s.firstPrompt.isEmpty ? tr("Без изменений в файлах.", "No file changes.") : tr("Задача: ", "Task: ") + s.firstPrompt.prefix(160) }
        return parts.joined(separator: ", ") + "."
    }

    /// Bullet points for "Что сделано".
    static func doneBullets(_ s: AgentSession) -> [String] {
        var bullets: [String] = []
        if let msg = s.finalMessage {
            let lines = msg.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*#")) }
                .filter { $0.count > 8 && !$0.hasPrefix("|") }
            bullets += lines.prefix(4).map { String($0.prefix(220)) }
        }
        if !s.filesTouched.isEmpty {
            let names = s.filesTouched.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            bullets.append(tr("Изменено \(Plural.files(s.filesTouched.count)): \(names)\(s.filesTouched.count > 3 ? "…" : "")", "Changed \(Plural.files(s.filesTouched.count)): \(names)\(s.filesTouched.count > 3 ? "…" : "")"))
        }
        if let p = s.testsPassed, (s.testsFailed ?? 0) == 0, p > 0 { bullets.append(tr("Тесты зелёные: \(p) ✓", "Tests green: \(p) ✓")) }
        if !s.commitsInWindow.isEmpty { bullets.append(tr("Создано \(Plural.commits(s.commitsInWindow.count))", "Created \(Plural.commits(s.commitsInWindow.count))")) }
        if bullets.isEmpty { bullets.append(factualSummary(s)) }
        return bullets
    }

    /// "Где застрял" — only for sessions that did not finish cleanly.
    static func stuck(_ s: AgentSession) -> String? {
        guard s.status == .unfinished || s.status == .rolledBack else { return nil }
        var parts: [String] = []
        if let hot = s.hottestFile, hot.edits >= 3 {
            parts.append(tr("Файл \((hot.path as NSString).lastPathComponent) правился \(Plural.times(hot.edits))", "\((hot.path as NSString).lastPathComponent) was edited \(Plural.times(hot.edits))") + (s.reverts > 0 ? tr(", откатов: \(s.reverts).", ", rollbacks: \(s.reverts).") : "."))
        } else if s.reverts > 0 {
            parts.append(tr("Агент \(Plural.times(s.reverts)) откатывал изменения.", "The agent reverted changes \(Plural.times(s.reverts))."))
        }
        if let f = s.testsFailed, f > 0 {
            var t = tr("Последний прогон тестов: \(f) падают", "Last test run: \(f) failing")
            if let name = s.lastFailingTest { t += " (\(name))" }
            parts.append(t + ".")
        }
        if let e = s.lastError { parts.append(tr("Последняя ошибка: \(e)", "Last error: \(e)")) }
        if parts.isEmpty { parts.append(tr("Изменения остались незакоммиченными после сессии.", "Changes were left uncommitted after the session.")) }
        return parts.joined(separator: " ")
    }

    static func recommendation(_ s: AgentSession) -> String {
        switch s.status {
        case .unfinished, .rolledBack:
            var text = ""
            if let hot = s.hottestFile, hot.edits >= 3 {
                text = tr("Начните следующую сессию с файла \((hot.path as NSString).lastPathComponent) и сразу дайте агенту вывод упавших тестов и критерий готовности.", "Start the next session with \((hot.path as NSString).lastPathComponent) and give the agent the failing test output and a definition of done right away.")
            } else if (s.testsFailed ?? 0) > 0 {
                text = tr("Передайте агенту вывод упавших тестов и попросите сначала воспроизвести ошибку отдельным тестом.", "Give the agent the failing test output and ask it to reproduce the bug in a separate test first.")
            } else {
                text = tr("Проверьте незакоммиченные изменения и либо закоммитьте их, либо попросите агента довести задачу.", "Review the uncommitted changes and either commit them or ask the agent to finish the task.")
            }
            if s.agent == .claude || s.agent == .codex {
                text += tr(" «Продолжить с контекстом» откроет эту же сессию в \(s.agent.title).", " “Continue with context” reopens this same session in \(s.agent.title).")
            }
            return text
        case .active:
            return tr("Сессия ещё идёт.", "The session is still running.")
        case .done:
            return s.commitsInWindow.isEmpty
                ? tr("Сессия завершена. Не забудьте закоммитить результат.", "Session finished. Don’t forget to commit the result.")
                : tr("Сессия завершена и закоммичена — можно брать следующую задачу.", "Session finished and committed — ready for the next task.")
        }
    }

    struct TimelineItem: Identifiable {
        let id = UUID()
        var time: Date
        var symbol: String
        var text: String
        var tone: Tone
        enum Tone { case normal, good, warn, bad }
    }

    static func timeline(_ s: AgentSession, limit: Int = 12) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var consecutiveReverts = 0
        for e in s.events {
            switch e.kind {
            case .prompt:
                items.append(.init(time: e.time, symbol: "text.bubble", text: String(e.text.prefix(60)), tone: .normal))
            case .read:
                items.append(.init(time: e.time, symbol: "doc.text.magnifyingglass", text: tr("Изучил \(Plural.files(max(e.files.count, 1)))", "Read \(Plural.files(max(e.files.count, 1)))"), tone: .normal))
            case .edit:
                let label = e.files.count == 1 ? (e.files[0] as NSString).lastPathComponent : Plural.files(e.files.count)
                items.append(.init(time: e.time, symbol: "pencil", text: tr("Правки: \(label)", "Edits: \(label)"), tone: .normal))
            case .bash:
                items.append(.init(time: e.time, symbol: "terminal", text: e.count > 1 ? tr("\(e.count) команд", "\(e.count) commands") : String(e.text.prefix(40)), tone: .normal))
            case .test:
                let f = e.failed ?? 0
                let txt = f > 0 ? tr("Тесты: \(e.passed ?? 0) ✓ · \(f) ✗", "Tests: \(e.passed ?? 0) ✓ · \(f) ✗") : (e.passed.map { tr("Тесты: \($0) ✓", "Tests: \($0) ✓") } ?? tr("Тесты прошли", "Tests passed"))
                items.append(.init(time: e.time, symbol: "flask", text: txt, tone: f > 0 ? .bad : .good))
            case .revert:
                consecutiveReverts += 1
                if let last = items.last, last.symbol == "arrow.counterclockwise" {
                    items[items.count - 1].text = tr("\(consecutiveReverts) \(Plural.ru(consecutiveReverts, "откат", "отката", "откатов")) подряд", "\(plural(consecutiveReverts, ru: ("откат", "отката", "откатов"), en: ("rollback", "rollbacks"))) in a row")
                    continue
                }
                items.append(.init(time: e.time, symbol: "arrow.counterclockwise", text: tr("Откат правки", "Edit reverted"), tone: .warn))
                continue
            case .commit:
                items.append(.init(time: e.time, symbol: "checkmark.circle", text: tr("Коммит: \(e.text.prefix(40))", "Commit: \(e.text.prefix(40))"), tone: .good))
            case .error:
                items.append(.init(time: e.time, symbol: "exclamationmark.triangle", text: e.text, tone: .bad))
            case .stop:
                items.append(.init(time: e.time, symbol: "pause.circle", text: s.status == .done ? tr("Завершено", "Finished") : (s.status == .active ? tr("Идёт", "Running") : tr("Остановлено", "Stopped")), tone: .normal))
            }
            consecutiveReverts = 0
        }
        if items.count <= limit { return items }
        // Keep the first few and the tail, which matters most.
        return Array(items.prefix(3)) + Array(items.suffix(limit - 3))
    }

    // MARK: - Helpers

    /// A file the agents keep coming back to with reverts in recent sessions.
    static func loopingFile(_ p: ProjectSnapshot) -> (name: String, reverts: Int)? {
        let recent = p.sessions(in: 7).prefix(5)
        let reverts = recent.reduce(0) { $0 + $1.reverts }
        guard reverts >= 2 || recent.filter({ $0.status == .rolledBack }).count >= 2 else { return nil }
        var counts: [String: Int] = [:]
        for s in recent { for (f, n) in s.editsPerFile { counts[f, default: 0] += n } }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return ((top.key as NSString).lastPathComponent, max(reverts, 2))
    }

    static func testsGrowing(_ p: ProjectSnapshot) -> Bool {
        let tested = p.sessions(in: 14).filter { $0.testsPassed != nil }
        guard tested.count >= 2, let newest = tested.first?.testsPassed, let oldest = tested.last?.testsPassed else { return false }
        return newest > oldest && (tested.first?.testsFailed ?? 0) == 0
    }

    static func topDirectories(_ sessions: [AgentSession]) -> [String] {
        var counts: [String: Int] = [:]
        for s in sessions {
            for f in s.filesTouched {
                let rel = SessionAnalyzer.relative(f, session: s)
                if rel.hasPrefix("/") { continue }
                let dir = (rel as NSString).deletingLastPathComponent
                counts[dir.isEmpty ? tr("корне", "the root") : dir + "/", default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(2).map(\.key)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
