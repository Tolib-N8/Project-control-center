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
            var detail = "Изменения лежат только локально"
            if let lastSession { detail += " — после сессии \(lastSession)" }
            detail += ". Сообщение коммита можно сгенерировать по списку файлов."
            let lines = p.repo.linesAdded + p.repo.linesRemoved
            return [make(age > 72 && lines >= 50 ? .critical : .warning,
                         "\(Plural.files(n)) не закоммичено " + (age > 48 ? "\(Int(age / 24)) дн." : "больше суток"),
                         detail,
                         [.init(label: "Файлов", value: "\(n)"),
                          .init(label: "Строк", value: lines == 0 ? "—" : "+\(p.repo.linesAdded) −\(p.repo.linesRemoved)"),
                          .init(label: "Возраст", value: Duration.age(hours: age))])]

        case .behindMain:
            guard let main = p.repo.mainBranch, p.repo.branch != main, Double(p.repo.behindMain) >= t else { return [] }
            var detail = "Чем дольше ждать, тем сложнее rebase"
            detail += p.repo.conflictFiles > 0 ? ": уже есть конфликты в \(Plural.files(p.repo.conflictFiles))." : "."
            if let plannedText { detail += " Проект запланирован на \(plannedText) — лучше сделать rebase до начала работы." }
            var metrics: [SignalMetric] = [.init(label: "Конфликты", value: p.repo.conflictFiles > 0 ? Plural.files(p.repo.conflictFiles) : "нет")]
            let idle = p.idleDays(at: now)
            if idle > 0 && idle < 999 { metrics.append(.init(label: "Без работы", value: Plural.days(idle))) }
            if let plannedText { metrics.append(.init(label: "В плане", value: plannedText)) }
            return [make(p.repo.conflictFiles > 0 || Double(p.repo.behindMain) >= t * 2 ? .critical : .warning,
                         "Ветка \(p.repo.branch) отстала от \(main) на \(Plural.commits(p.repo.behindMain))",
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
                ? "Агент \(Plural.times(n)) подряд не довёл правки" + (file.map { " в \($0)" } ?? "")
                : "Агент \(Plural.times(single!.reverts)) откатывал правки" + (file.map { " в \($0)" } ?? "")
            return [make(.warning, title,
                         "\(streak ? "\(Plural.sessions(n).capitalizedFirst) подряд" : "За одну сессию") \(agent) переделывал одно и то же без коммита. Скорее всего, в задаче нет критерия готовности.",
                         [.init(label: "Сессий", value: "\(sessions.count)"),
                          .init(label: "Потрачено", value: Duration.text(minutes: minutes)),
                          .init(label: "Коммитов", value: "\(sessions.reduce(0) { $0 + $1.commitsInWindow.count })")])]

        case .testsFailing:
            guard let s = p.lastTestedSession, let failed = s.testsFailed, failed > 0,
                  now.timeIntervalSince(s.end) < 14 * 86400 else { return [] }
            var detail = "В последней сессии \(s.agent.title) тесты остались красными"
            if let name = s.lastFailingTest { detail += ": \(name)" }
            detail += "."
            return [make(.warning, "Падают \(Plural.tests(failed))", detail,
                         [.init(label: "Падают", value: "\(failed)"),
                          .init(label: "Прошли", value: "\(s.testsPassed ?? 0)"),
                          .init(label: "Сессия", value: DateFormat.relativeDay(s.end))])]

        case .idle:
            let idle = p.idleDays(at: now)
            guard Double(idle) >= t, idle < 999 else { return [] }
            var metrics: [SignalMetric] = [.init(label: "Без работы", value: Plural.days(idle))]
            if let c = p.repo.lastCommit { metrics.append(.init(label: "Последний коммит", value: DateFormat.short(c.date))) }
            metrics.append(.init(label: "В плане", value: plannedText ?? "нет"))
            let detail = plannedText == nil
                ? "Проекта нет в плане недели. Запланируйте хотя бы короткий блок или отправьте его в архив."
                : "Проект стоит в плане на \(plannedText!) — стоит освежить контекст заранее."
            return [make(idle >= Int(t) * 3 ? .critical : .warning, "Нет работы \(Plural.days(idle))", detail, metrics)]

        case .skippedDay:
            guard let plan else { return [] }
            let today = Week.weekdayIndex(now)
            let monday = Week.date(fromKey: plan.weekKey) ?? Week.monday(of: now)
            var result: [Signal] = []
            for block in plan.blocks where block.projectId == pid && block.day < today {
                let date = Week.day(block.day, of: monday)
                let actual = Activity.hours(p.sessions, on: date)
                if actual < 0.25 {
                    result.append(make(.warning, "День пропущен: \(Week.shortNames[block.day]), \(DateFormat.short(date))",
                                       "По плану было \(Duration.hours(block.hours)) ч, сессий агентов в этот день нет. Перенесите блок на другой день.",
                                       [.init(label: "План", value: "\(Duration.hours(block.hours)) ч"), .init(label: "Факт", value: "0 ч")],
                                       suffix: ":\(plan.weekKey):\(block.day)"))
                }
            }
            return result

        case .tokens:
            guard let s = p.sessions(in: 7, before: now).first(where: { Double($0.tokens) >= t }) else { return [] }
            return [make(.warning, "Сессия «\(s.title)» потратила \(NumberText.compact(s.tokens)) токенов",
                         "Большой расход токенов обычно значит, что агент перечитывает много контекста. Разбейте задачу на части.",
                         [.init(label: "Токены", value: NumberText.compact(s.tokens)),
                          .init(label: "Длительность", value: Duration.text(minutes: s.durationMinutes))],
                         suffix: ":\(s.id)")]
        }
    }

    static func autoResolution(_ s: Signal) -> String {
        switch s.kind {
        case .uncommitted: "изменения закоммичены"
        case .behindMain: "ветка догнала main"
        case .agentReverts: "агент довёл задачу"
        case .testsFailing: "тесты зелёные"
        case .idle: "работа возобновилась"
        case .skippedDay: "план обновлён"
        case .tokens: "расход в норме"
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
