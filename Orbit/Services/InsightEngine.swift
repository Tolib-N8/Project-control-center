import Foundation

/// Rule-based text conclusions about projects and sessions (stands in for an LLM in v1).
enum InsightEngine {
    // MARK: - Projects

    /// One line for tables ("Стабильный прогресс, тесты растут").
    static func headline(_ p: ProjectSnapshot) -> String {
        let idle = p.idleDays()
        if idle >= 999 { return "Нет данных об активности" }
        if idle >= 7 { return "Нет активности \(Plural.days(idle))" }
        if let loop = loopingFile(p) { return "Агент зацикливается на \(loop.name)" }
        if let last = p.sessions.first, last.status == .unfinished, (last.testsFailed ?? 0) > 0 {
            return "Остановились на падающих тестах: \(last.testsFailed!)"
        }
        if let age = p.repo.changesAgeHours, age > 24 {
            return "\(Plural.files(p.repo.changes.count)) не закоммичено больше суток"
        }
        if p.repo.behindMain >= 20 { return "Ветка отстала от main на \(Plural.commits(p.repo.behindMain))" }
        if testsGrowing(p) { return "Стабильный прогресс, тесты растут" }
        let week = p.sessions(in: 7)
        if week.isEmpty && p.commits(in: 7).isEmpty { return "Тихая неделя" }
        let done = week.filter { $0.status == .done }.count
        if !week.isEmpty && done == week.count { return "Стабильный прогресс: \(Plural.sessions(week.count)) без проблем" }
        if let last = p.sessions.first, last.status == .done, last.commitsInWindow.isEmpty == false {
            return "Работа идёт, последняя сессия закоммичена"
        }
        return "Работа идёт: \(Plural.sessions(week.count)), \(Plural.commits(p.commits(in: 7).count)) за неделю"
    }

    /// Two-sentence summary for project cards.
    static func cardSummary(_ p: ProjectSnapshot) -> String {
        var parts: [String] = []
        let idle = p.idleDays()
        if idle >= 7 && idle < 999 { parts.append("\(Plural.days(idle).capitalizedFirst) без работы.") }
        if let last = p.sessions.first, idle < 7 {
            parts.append("Последняя сессия — «\(last.title)»" + (last.status == .done ? "." : " (\(last.status.title.lowercased())).") )
        }
        if let loop = loopingFile(p) {
            parts.append("Агент \(Plural.times(loop.reverts)) откатывал правки в \(loop.name) — стоит точнее сформулировать задачу.")
        } else if p.testsFailing > 0 {
            parts.append("Падают \(Plural.tests(p.testsFailing)).")
        }
        if p.repo.behindMain >= 10 { parts.append("Ветка \(p.repo.branch) отстала от main на \(Plural.commits(p.repo.behindMain)).") }
        if let age = p.repo.changesAgeHours, age > 24 { parts.append("Изменения не закоммичены \(Duration.age(hours: age)).") }
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
        var text = "Из \(Plural.sessions(recent.count)): \(done) готово"
        if unfinished > 0 { text += ", \(unfinished) не завершено" }
        if rolled > 0 { text += ", \(rolled) с откатом" }
        text += "."
        let dirs = topDirectories(recent)
        if !dirs.isEmpty { text += " Основная работа — в \(dirs.joined(separator: ", "))." }
        if let loop = loopingFile(p) {
            text += " Агенты \(Plural.times(loop.reverts)) возвращались к \(loop.name) — дайте им пример или критерий готовности."
        } else if let hot = recent.compactMap(\.hottestFile).max(by: { $0.edits < $1.edits }), hot.edits >= 6 {
            text += " Чаще всего правился \((hot.path as NSString).lastPathComponent) (\(Plural.times(hot.edits)))."
        }
        if let age = p.repo.changesAgeHours, age > 24 {
            text += " Изменения не закоммичены больше суток."
        }
        return text
    }

    static func nextSteps(_ p: ProjectSnapshot) -> [String] {
        var steps: [String] = []
        if let s = p.lastTestedSession, (s.testsFailed ?? 0) > 0 {
            if let name = s.lastFailingTest { steps.append("Починить тест \((name as NSString).lastPathComponent)") }
            else { steps.append("Починить \(Plural.tests(s.testsFailed!)) из последней сессии") }
        }
        if let last = p.sessions.first, last.status == .unfinished || last.status == .rolledBack, steps.count < 2 {
            steps.append("Продолжить: \(last.title)")
        }
        if !p.repo.changes.isEmpty {
            steps.append("Закоммитить \(Plural.files(p.repo.changes.count))" + (p.repo.upstream != nil ? " и запушить" : ""))
        } else if p.repo.ahead > 0 {
            steps.append("Запушить \(Plural.commits(p.repo.ahead))")
        }
        if p.repo.behindMain >= 10, let main = p.repo.mainBranch {
            steps.append("Rebase \(p.repo.branch) на \(main) (−\(p.repo.behindMain))")
        }
        if let b = p.abandonedBranches.first { steps.append("Разобрать ветку \(b.name)") }
        if steps.isEmpty { steps.append("Выбрать следующую задачу и запустить агента") }
        return Array(steps.prefix(3))
    }

    static func workDaysAdvice(_ p: ProjectSnapshot) -> String {
        let sessions = p.sessions(in: 45)
        guard sessions.count >= 3 else { return "Мало данных — после нескольких сессий Orbit подскажет лучшие дни." }
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
            if l - s > 0.15 { return "По сессиям прогресс лучше в дни с блоками от 3 ч — стоит объединять короткие дни в один длинный." }
            if s - l > 0.15 { return "Короткие блоки работают лучше: в длинные дни растёт доля незавершённых сессий." }
        }
        var weekday: [Int: Int] = [:]
        for s in sessions where s.status == .done { weekday[Week.weekdayIndex(s.start), default: 0] += 1 }
        let best = weekday.sorted { $0.value > $1.value }.prefix(2).map { Week.shortNames[$0.key] }
        return best.isEmpty ? "Завершённых сессий пока нет." : "Больше всего завершённых сессий: \(best.joined(separator: ", "))."
    }

    /// Short note for the planner row.
    static func plannerNote(_ p: ProjectSnapshot, signals: [Signal]) -> String {
        if let s = signals.first(where: { $0.severity == .critical }) {
            switch s.kind {
            case .behindMain: return "срочно: rebase"
            case .uncommitted: return "срочно: закоммитить"
            case .testsFailing: return "срочно: тесты"
            default: return "срочно"
            }
        }
        if p.idleDays() >= 7 && p.idleDays() < 999 { return "давно не трогали" }
        if p.testsFailing > 0 { return "починить тесты" }
        if let last = p.sessions.first, last.status == .unfinished { return "довести сессию" }
        return HealthEngine.score(p) >= 85 ? "по желанию" : "плановая работа"
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
        if !s.filesTouched.isEmpty { parts.append("Изменил \(Plural.files(s.filesTouched.count)) (+\(s.linesAdded) −\(s.linesRemoved))") }
        else if s.filesRead > 0 { parts.append("Изучил \(Plural.files(s.filesRead))") }
        if let f = s.testsFailed, f > 0 { parts.append("\(Plural.tests(f)) падают") }
        else if let p = s.testsPassed, p > 0 { parts.append("тесты: \(p) ✓") }
        if s.reverts > 0 { parts.append("\(Plural.times(s.reverts)) откатывал правки") }
        if parts.isEmpty { return s.firstPrompt.isEmpty ? "Без изменений в файлах." : "Задача: " + s.firstPrompt.prefix(160) }
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
            bullets.append("Изменено \(Plural.files(s.filesTouched.count)): \(names)\(s.filesTouched.count > 3 ? "…" : "")")
        }
        if let p = s.testsPassed, (s.testsFailed ?? 0) == 0, p > 0 { bullets.append("Тесты зелёные: \(p) ✓") }
        if !s.commitsInWindow.isEmpty { bullets.append("Создано \(Plural.commits(s.commitsInWindow.count))") }
        if bullets.isEmpty { bullets.append(factualSummary(s)) }
        return bullets
    }

    /// "Где застрял" — only for sessions that did not finish cleanly.
    static func stuck(_ s: AgentSession) -> String? {
        guard s.status == .unfinished || s.status == .rolledBack else { return nil }
        var parts: [String] = []
        if let hot = s.hottestFile, hot.edits >= 3 {
            parts.append("Файл \((hot.path as NSString).lastPathComponent) правился \(Plural.times(hot.edits))" + (s.reverts > 0 ? ", откатов: \(s.reverts)." : "."))
        } else if s.reverts > 0 {
            parts.append("Агент \(Plural.times(s.reverts)) откатывал изменения.")
        }
        if let f = s.testsFailed, f > 0 {
            var t = "Последний прогон тестов: \(f) падают"
            if let name = s.lastFailingTest { t += " (\(name))" }
            parts.append(t + ".")
        }
        if let e = s.lastError { parts.append("Последняя ошибка: \(e)") }
        if parts.isEmpty { parts.append("Изменения остались незакоммиченными после сессии.") }
        return parts.joined(separator: " ")
    }

    static func recommendation(_ s: AgentSession) -> String {
        switch s.status {
        case .unfinished, .rolledBack:
            var text = ""
            if let hot = s.hottestFile, hot.edits >= 3 {
                text = "Начните следующую сессию с файла \((hot.path as NSString).lastPathComponent) и сразу дайте агенту вывод упавших тестов и критерий готовности."
            } else if (s.testsFailed ?? 0) > 0 {
                text = "Передайте агенту вывод упавших тестов и попросите сначала воспроизвести ошибку отдельным тестом."
            } else {
                text = "Проверьте незакоммиченные изменения и либо закоммитьте их, либо попросите агента довести задачу."
            }
            if s.agent == .claude || s.agent == .codex {
                text += " «Продолжить с контекстом» откроет эту же сессию в \(s.agent.title)."
            }
            return text
        case .active:
            return "Сессия ещё идёт."
        case .done:
            return s.commitsInWindow.isEmpty
                ? "Сессия завершена. Не забудьте закоммитить результат."
                : "Сессия завершена и закоммичена — можно брать следующую задачу."
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
                items.append(.init(time: e.time, symbol: "doc.text.magnifyingglass", text: "Изучил \(Plural.files(max(e.files.count, 1)))", tone: .normal))
            case .edit:
                let label = e.files.count == 1 ? (e.files[0] as NSString).lastPathComponent : Plural.files(e.files.count)
                items.append(.init(time: e.time, symbol: "pencil", text: "Правки: \(label)", tone: .normal))
            case .bash:
                items.append(.init(time: e.time, symbol: "terminal", text: e.count > 1 ? "\(e.count) команд" : String(e.text.prefix(40)), tone: .normal))
            case .test:
                let f = e.failed ?? 0
                let txt = f > 0 ? "Тесты: \(e.passed ?? 0) ✓ · \(f) ✗" : (e.passed.map { "Тесты: \($0) ✓" } ?? "Тесты прошли")
                items.append(.init(time: e.time, symbol: "flask", text: txt, tone: f > 0 ? .bad : .good))
            case .revert:
                consecutiveReverts += 1
                if let last = items.last, last.symbol == "arrow.counterclockwise" {
                    items[items.count - 1].text = "\(consecutiveReverts) \(Plural.ru(consecutiveReverts, "откат", "отката", "откатов")) подряд"
                    continue
                }
                items.append(.init(time: e.time, symbol: "arrow.counterclockwise", text: "Откат правки", tone: .warn))
                continue
            case .commit:
                items.append(.init(time: e.time, symbol: "checkmark.circle", text: "Коммит: \(e.text.prefix(40))", tone: .good))
            case .error:
                items.append(.init(time: e.time, symbol: "exclamationmark.triangle", text: e.text, tone: .bad))
            case .stop:
                items.append(.init(time: e.time, symbol: "pause.circle", text: s.status == .done ? "Завершено" : (s.status == .active ? "Идёт" : "Остановлено"), tone: .normal))
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
                counts[dir.isEmpty ? "корне" : dir + "/", default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(2).map(\.key)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
