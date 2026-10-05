import Foundation

/// Evaluates monitoring rules and keeps signal state (active / snoozed / resolved) across runs.
enum SignalEngine {
    /// `plans`: the current week's plan first, then the next week's.
    static func evaluate(config: OrbitConfig, projects: [ProjectSnapshot], plans: [WeekPlan], existing: [Signal], now: Date = Date()) -> [Signal] {
        var candidates: [Signal] = []
        for p in projects where !p.config.archived {
            for rule in config.rules where rule.enabled {
                candidates += detect(rule, p, plans: plans, now: now)
            }
        }

        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidateIds = Set(candidates.map(\.id))

        for c in candidates {
            if var old = byId[c.id] {
                let keepDetected = old.state != .resolved
                old.title = c.title
                old.detail = c.detail
                old.metrics = c.metrics
                old.severity = c.severity
                if old.state == .resolved {
                    old.state = .active
                    old.detectedAt = now
                    old.resolvedAt = nil
                    old.resolution = nil
                    old.notified = false
                } else if old.state == .snoozed, let until = old.snoozedUntil, until <= now {
                    old.state = .active
                    old.snoozedUntil = nil
                }
                if !keepDetected { old.detectedAt = now }
                byId[c.id] = old
            } else {
                byId[c.id] = c
            }
        }

        // Conditions that disappeared resolve automatically.
        for (id, var s) in byId where s.state != .resolved && !candidateIds.contains(id) {
            s.state = .resolved
            s.resolvedAt = now
            s.resolution = autoResolution(s)
            byId[id] = s
        }

        let cutoff = now.addingTimeInterval(-60 * 86400)
        let knownProjects = Set(projects.map(\.config.id))
        return byId.values
            .filter { knownProjects.contains($0.projectId) && ($0.state != .resolved || ($0.resolvedAt ?? now) > cutoff) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity == .critical }
                return lhs.detectedAt > rhs.detectedAt
            }
    }

    static func detect(_ rule: SignalRuleConfig, _ p: ProjectSnapshot, plans: [WeekPlan], now: Date) -> [Signal] {
        let plan = plans.first
        let pid = p.config.id
        let t = rule.threshold
        func make(_ severity: SignalSeverity, _ title: String, _ detail: String, _ metrics: [SignalMetric], suffix: String = "") -> Signal {
            Signal(id: "\(rule.kind.rawValue):\(pid)\(suffix)", kind: rule.kind, projectId: pid, severity: severity,
                   title: title, detail: detail, metrics: metrics, detectedAt: now)
        }
        let plannedText = nextPlannedDay(pid, plans: plans, now: now)

        switch rule.kind {
        case .uncommitted:
            guard !p.repo.changes.isEmpty, let age = p.repo.changesAgeHours, age >= t else { return [] }
            let n = p.repo.changes.count
            let lastSession = p.sessions.first.map { DateFormat.relativeDay($0.end, withTime: false) }
            var detail = tr("Изменения лежат только локально", "Changes exist only locally")
            if let lastSession { detail += tr(" — после сессии \(lastSession)", " — since the session \(lastSession)") }
            detail += tr(". Сообщение коммита можно сгенерировать по списку файлов.", ". A commit message can be generated from the file list.")
            let lines = p.repo.linesAdded + p.repo.linesRemoved
            return [make(age > 72 && lines >= 50 ? .critical : .warning,
                         tr("\(Plural.files(n)) не закоммичено ", "\(Plural.files(n)) uncommitted for ") + (age > 48 ? tr("\(Int(age / 24)) дн.", "\(Plural.days(Int(age / 24)))") : tr("больше суток", "over a day")),
                         detail,
                         [.init(label: tr("Файлов", "Files"), value: "\(n)"),
                          .init(label: tr("Строк", "Lines"), value: lines == 0 ? "—" : "+\(p.repo.linesAdded) −\(p.repo.linesRemoved)"),
                          .init(label: tr("Возраст", "Age"), value: Duration.age(hours: age))])]

        case .behindMain:
            guard let main = p.repo.mainBranch, p.repo.branch != main, Double(p.repo.behindMain) >= t else { return [] }
            var detail = tr("Чем дольше ждать, тем сложнее rebase", "The longer you wait, the harder the rebase")
            detail += p.repo.conflictFiles > 0 ? tr(": уже есть конфликты в \(Plural.files(p.repo.conflictFiles)).", ": there are already conflicts in \(Plural.files(p.repo.conflictFiles)).") : "."
            if let plannedText { detail += tr(" Проект запланирован на \(plannedText) — лучше сделать rebase до начала работы.", " The project is planned for \(plannedText) — better rebase before you start.") }
            var metrics: [SignalMetric] = [.init(label: tr("Конфликты", "Conflicts"), value: p.repo.conflictFiles > 0 ? Plural.files(p.repo.conflictFiles) : tr("нет", "none"))]
            let idle = p.idleDays(at: now)
            if idle > 0 && idle < 999 { metrics.append(.init(label: tr("Без работы", "Idle"), value: Plural.days(idle))) }
            if let plannedText { metrics.append(.init(label: tr("В плане", "Planned"), value: plannedText)) }
            return [make(p.repo.conflictFiles > 0 || Double(p.repo.behindMain) >= t * 2 ? .critical : .warning,
                         tr("Ветка \(p.repo.branch) отстала от \(main) на \(Plural.commits(p.repo.behindMain))", "Branch \(p.repo.branch) is \(Plural.commits(p.repo.behindMain)) behind \(main)"),
                         detail, metrics)]

        case .agentReverts:
            let n = max(2, Int(t))
            let recent = Array(p.sessions.filter { $0.status != .active }.prefix(n))
            let streak = recent.count == n && recent.allSatisfy { ($0.reverts > 0 || $0.status == .rolledBack || $0.status == .unfinished) && $0.commitsInWindow.isEmpty }
            let single = p.sessions.first.flatMap { $0.reverts >= n ? $0 : nil }
            guard streak || single != nil else { return [] }
            let sessions = streak ? recent : [single!]
            let minutes = sessions.reduce(0) { $0 + $1.durationMinutes }
            let file = sessions.compactMap(\.hottestFile).max { $0.edits < $1.edits }.map { ($0.path as NSString).lastPathComponent }
            let agent = sessions.first!.agent.title
            let title = streak
                ? tr("Агент \(Plural.times(n)) подряд не довёл правки", "Agent left its edits unfinished \(Plural.times(n)) in a row") + (file.map { tr(" в \($0)", " in \($0)") } ?? "")
                : tr("Агент \(Plural.times(single!.reverts)) откатывал правки", "Agent reverted its edits \(Plural.times(single!.reverts))") + (file.map { tr(" в \($0)", " in \($0)") } ?? "")
            return [make(.warning, title,
                         tr("\(streak ? "\(Plural.sessions(n).capitalizedFirst) подряд" : "За одну сессию") \(agent) переделывал одно и то же без коммита. Скорее всего, в задаче нет критерия готовности.", "\(streak ? "For \(Plural.sessions(n)) in a row" : "Within one session") \(agent) kept redoing the same thing without committing. The task most likely lacks a definition of done."),
                         [.init(label: tr("Сессий", "Sessions"), value: "\(sessions.count)"),
                          .init(label: tr("Потрачено", "Time spent"), value: Duration.text(minutes: minutes)),
                          .init(label: tr("Коммитов", "Commits"), value: "\(sessions.reduce(0) { $0 + $1.commitsInWindow.count })")])]

        case .testsFailing:
            guard let s = p.lastTestedSession, let failed = s.testsFailed, failed > 0,
                  now.timeIntervalSince(s.end) < 14 * 86400 else { return [] }
            var detail = tr("В последней сессии \(s.agent.title) тесты остались красными", "Tests stayed red in the last \(s.agent.title) session")
            if let name = s.lastFailingTest { detail += ": \(name)" }
            detail += "."
            return [make(.warning, tr("Падают \(Plural.tests(failed))", "\(Plural.tests(failed)) failing"), detail,
                         [.init(label: tr("Падают", "Failing"), value: "\(failed)"),
                          .init(label: tr("Прошли", "Passed"), value: "\(s.testsPassed ?? 0)"),
                          .init(label: tr("Сессия", "Session"), value: DateFormat.relativeDay(s.end))])]

        case .idle:
            let idle = p.idleDays(at: now)
            guard Double(idle) >= t, idle < 999 else { return [] }
            var metrics: [SignalMetric] = [.init(label: tr("Без работы", "Idle"), value: Plural.days(idle))]
            if let c = p.repo.lastCommit { metrics.append(.init(label: tr("Последний коммит", "Last commit"), value: DateFormat.short(c.date))) }
            metrics.append(.init(label: tr("В плане", "Planned"), value: plannedText ?? tr("нет", "none")))
            let detail = plannedText == nil
                ? tr("Проекта нет в плане недели. Запланируйте хотя бы короткий блок или отправьте его в архив.", "The project isn’t in this week’s plan. Schedule at least a short block or archive it.")
                : tr("Проект стоит в плане на \(plannedText!) — стоит освежить контекст заранее.", "The project is planned for \(plannedText!) — worth refreshing the context beforehand.")
            return [make(idle >= Int(t) * 3 ? .critical : .warning, tr("Нет работы \(Plural.days(idle))", "No work for \(Plural.days(idle))"), detail, metrics)]

        case .skippedDay:
            guard let plan else { return [] }
            let today = Week.weekdayIndex(now)
            let monday = Week.date(fromKey: plan.weekKey) ?? Week.monday(of: now)
            var result: [Signal] = []
            for block in plan.blocks where block.projectId == pid && block.day < today {
                let date = Week.day(block.day, of: monday)
                let actual = Activity.hours(p.sessions, on: date)
                if actual < 0.25 {
                    result.append(make(.warning, tr("День пропущен: \(Week.shortNames[block.day]), \(DateFormat.short(date))", "Day skipped: \(Week.shortNames[block.day]), \(DateFormat.short(date))"),
                                       tr("По плану было \(Duration.hours(block.hours)) ч, сессий агентов в этот день нет. Перенесите блок на другой день.", "\(Duration.hours(block.hours)) h were planned, but there were no agent sessions that day. Move the block to another day."),
                                       [.init(label: tr("План", "Planned"), value: tr("\(Duration.hours(block.hours)) ч", "\(Duration.hours(block.hours)) h")), .init(label: tr("Факт", "Actual"), value: tr("0 ч", "0 h"))],
                                       suffix: ":\(plan.weekKey):\(block.day)"))
                }
            }
            return result

        case .tokens:
            guard let s = p.sessions(in: 7, before: now).first(where: { Double($0.tokens) >= t }) else { return [] }
            return [make(.warning, tr("Сессия «\(s.title)» потратила \(NumberText.compact(s.tokens)) токенов", "Session “\(s.title)” used \(NumberText.compact(s.tokens)) tokens"),
                         tr("Большой расход токенов обычно значит, что агент перечитывает много контекста. Разбейте задачу на части.", "Heavy token use usually means the agent keeps rereading a lot of context. Split the task into smaller parts."),
                         [.init(label: tr("Токены", "Tokens"), value: NumberText.compact(s.tokens)),
                          .init(label: tr("Длительность", "Duration"), value: Duration.text(minutes: s.durationMinutes))],
                         suffix: ":\(s.id)")]
        }
    }

    static func autoResolution(_ s: Signal) -> String {
        switch s.kind {
        case .uncommitted: tr("изменения закоммичены", "changes committed")
        case .behindMain: tr("ветка догнала main", "branch caught up with main")
        case .agentReverts: tr("агент довёл задачу", "agent finished the task")
        case .testsFailing: tr("тесты зелёные", "tests are green")
        case .idle: tr("работа возобновилась", "work resumed")
        case .skippedDay: tr("план обновлён", "plan updated")
        case .tokens: tr("расход в норме", "usage back to normal")
        }
    }

    /// "Сб, 3 окт" for the project's next planned block, from today on.
    static func nextPlannedDay(_ pid: String, plans: [WeekPlan], now: Date) -> String? {
        let today = Week.calendar.startOfDay(for: now)
        let dates = plans.flatMap { plan -> [Date] in
            guard let monday = Week.date(fromKey: plan.weekKey) else { return [] }
            return plan.blocks.filter { $0.projectId == pid }.map { Week.day($0.day, of: monday) }
        }
        return dates.filter { $0 >= today }.min().map(DateFormat.weekdayShort)
    }
}

enum Activity {
    /// Active agent hours on a calendar day.
    static func hours(_ sessions: [AgentSession], on date: Date) -> Double {
        let cal = Week.calendar
        return sessions.filter { cal.isDate($0.start, inSameDayAs: date) }.reduce(0) { $0 + $1.activeSeconds } / 3600
    }

    static func hours(_ sessions: [AgentSession], from: Date, to: Date) -> Double {
        sessions.filter { $0.start >= from && $0.start < to }.reduce(0) { $0 + $1.activeSeconds } / 3600
    }
}
