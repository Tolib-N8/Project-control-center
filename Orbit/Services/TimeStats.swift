import Foundation

/// A week (Monday-based) or a calendar month on the "Время" screen.
struct TimePeriod: Hashable {
    enum Kind: Hashable { case week, month }

    var kind: Kind
    /// Start of the first day.
    var start: Date

    static func containing(_ date: Date, kind: Kind) -> TimePeriod {
        let cal = Week.calendar
        switch kind {
        case .week: return TimePeriod(kind: kind, start: Week.monday(of: date))
        case .month: return TimePeriod(kind: kind, start: cal.date(from: cal.dateComponents([.year, .month], from: date))!)
        }
    }

    /// Exclusive.
    var end: Date {
        Week.calendar.date(byAdding: kind == .week ? .day : .month, value: kind == .week ? 7 : 1, to: start)!
    }

    var days: [Date] {
        var result: [Date] = [], d = start
        while d < end {
            result.append(d)
            d = Week.calendar.date(byAdding: .day, value: 1, to: d)!
        }
        return result
    }

    func shifted(_ n: Int) -> TimePeriod {
        TimePeriod(kind: kind, start: Week.calendar.date(byAdding: kind == .week ? .day : .month, value: kind == .week ? 7 * n : n, to: start)!)
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// "6 — 12 окт" / "Октябрь 2026"
    var title: String {
        switch kind {
        case .week:
            let last = Week.calendar.date(byAdding: .day, value: 6, to: start)!
            return "\(DateFormat.short(start)) — \(DateFormat.short(last))"
        case .month:
            let name = DateFormat.monthStandalone.string(from: start)
            return name.prefix(1).uppercased() + name.dropFirst() + " \(Week.calendar.component(.year, from: start))"
        }
    }
}

/// Everything the "Время" screen shows for one period.
struct TimeStats {
    struct Day: Identifiable, Hashable {
        var date: Date
        /// Hours per project id.
        var byProject: [String: Double]
        var planned: Double
        var id: Date { date }
        var total: Double { byProject.values.reduce(0, +) }
    }

    struct ProjectRow: Identifiable, Hashable {
        var id: String
        var hours: Double
        var planned: Double
        var sessions: Int
    }

    var days: [Day]
    var previousTotal: Double
    var projects: [ProjectRow]
    /// Hours by weekday (0 = Monday) and hour of the day.
    var heat: [[Double]]
    /// Time with the timer running — you at the keyboard.
    var timerHours: Double
    /// Agent activity outside the timer, per agent.
    var agentHours: [AgentKind: Double]
    var sessions: Int
    var sessionsWithCommit: Int
    var streak: (current: Int, best: Int)

    var total: Double { days.reduce(0) { $0 + $1.total } }
    var planned: Double { days.reduce(0) { $0 + $1.planned } }
    /// Planned up to and including `day` — the fair yardstick while the period is still running.
    func planned(through day: Date) -> Double { days.filter { $0.date <= day }.reduce(0) { $0 + $1.planned } }
    var bestDay: Day? { days.filter { $0.total > 0 }.max { $0.total < $1.total } }
    /// Mean over the days that had any work.
    var averagePerWorkedDay: Double {
        let worked = days.filter { $0.total >= TimeEngine.workedThreshold }
        return worked.isEmpty ? 0 : worked.reduce(0) { $0 + $1.total } / Double(worked.count)
    }
    var isEmpty: Bool { total < 0.01 && sessions == 0 }

    /// "вт–чт, 14–18": the weekdays and hours that carry most of the work; nil without enough data.
    var peak: (days: ClosedRange<Int>, hours: ClosedRange<Int>)? {
        let byDay = heat.map { $0.reduce(0, +) }, byHour = (0..<24).map { h in heat.reduce(0) { $0 + $1[h] } }
        guard byDay.reduce(0, +) >= 2, let d = TimeEngine.densestRun(byDay, share: 0.6), let h = TimeEngine.densestRun(byHour, share: 0.6) else { return nil }
        return (d, h)
    }
}

enum TimeEngine {
    /// A day counts as worked from half an hour.
    static let workedThreshold = 0.5

    /// "37 мин", "1 ч 12 мин" up to ten hours, then whole and half hours ("21,5 ч").
    static func text(hours: Double) -> String {
        hours < 10 ? Duration.text(minutes: Int((hours * 60).rounded())) : "\(Duration.hours(hours)) \(Duration.h)"
    }

    static func compute(period: TimePeriod, projects: [ProjectSnapshot], worklog: [WorkInterval], plans: [String: WeekPlan], now: Date) -> TimeStats {
        let cal = Week.calendar
        var perProject: [String: [Date: Double]] = [:]
        for p in projects {
            perProject[p.config.id] = dailySeconds(p.sessions, timer: worklog.filter { $0.projectId == p.config.id }, now: now)
        }
        func total(_ from: Date, _ to: Date) -> Double {
            perProject.values.reduce(0) { sum, days in sum + days.filter { $0.key >= from && $0.key < to }.values.reduce(0, +) } / 3600
        }

        let days = period.days.map { day -> TimeStats.Day in
            var by: [String: Double] = [:]
            for (id, map) in perProject { if let s = map[day], s > 0 { by[id] = s / 3600 } }
            return TimeStats.Day(date: day, byProject: by, planned: plannedHours(nil, from: day, to: cal.date(byAdding: .day, value: 1, to: day)!, plans: plans))
        }

        let rows = projects.map { p -> TimeStats.ProjectRow in
            let id = p.config.id
            return TimeStats.ProjectRow(id: id, hours: days.reduce(0) { $0 + ($1.byProject[id] ?? 0) },
                                        planned: plannedHours(id, from: period.start, to: period.end, plans: plans),
                                        sessions: p.sessions.filter { period.contains($0.start) }.count)
        }
        .filter { $0.hours > 0.01 || $0.planned > 0 || $0.sessions > 0 }
        .sorted { ($0.hours, $0.planned) > ($1.hours, $1.planned) }

        // Streak looks at every day on record, not just this period.
        var allDays: [Date: Double] = [:]
        for map in perProject.values { for (d, s) in map { allDays[d, default: 0] += s / 3600 } }

        var agentHours: [AgentKind: Double] = [:]
        var sessionCount = 0, withCommit = 0
        for p in projects {
            let timer = worklog.filter { $0.projectId == p.config.id }
            for s in p.sessions where period.contains(s.start) {
                sessionCount += 1
                if !s.commitsInWindow.isEmpty || s.events.contains(where: { $0.kind == .commit }) { withCommit += 1 }
                agentHours[s.agent, default: 0] += agentSeconds(s, timer: timer, now: now) / 3600
            }
        }
        let timerHours = worklog.reduce(0) { $0 + $1.overlap(from: period.start, to: period.end, now: now) } / 3600

        return TimeStats(days: days, previousTotal: total(period.shifted(-1).start, period.start), projects: rows,
                         heat: heat(projects: projects, worklog: worklog, from: period.start, to: period.end, now: now),
                         timerHours: timerHours, agentHours: agentHours.filter { $0.value > 0.01 },
                         sessions: sessionCount, sessionsWithCommit: withCommit,
                         streak: streak(allDays, today: cal.startOfDay(for: now)))
    }

    /// Seconds per calendar day, the same rule as `Activity.hours`: timer time, plus each agent session's
    /// active time not already covered by the timer, counted on the day the session started.
    static func dailySeconds(_ sessions: [AgentSession], timer: [WorkInterval], now: Date) -> [Date: Double] {
        let cal = Week.calendar
        var result: [Date: Double] = [:]
        for interval in timer {
            var day = cal.startOfDay(for: interval.start)
            let stop = interval.end ?? now
            while day < stop {
                let next = cal.date(byAdding: .day, value: 1, to: day)!
                result[day, default: 0] += interval.overlap(from: day, to: next, now: now)
                day = next
            }
        }
        for s in sessions {
            result[cal.startOfDay(for: s.start), default: 0] += agentSeconds(s, timer: timer, now: now)
        }
        return result.filter { $0.value > 0 }
    }

    /// A session's active time that the timer didn't already count.
    static func agentSeconds(_ s: AgentSession, timer: [WorkInterval], now: Date) -> Double {
        let covered = timer.reduce(0) { $0 + $1.overlap(from: s.start, to: s.end, now: now) }
        return max(0, s.activeSeconds - covered)
    }

    /// Planned hours from the week plans; nil project means all of them.
    static func plannedHours(_ projectId: String?, from: Date, to: Date, plans: [String: WeekPlan]) -> Double {
        plans.values.reduce(0) { sum, plan in
            guard let monday = Week.date(fromKey: plan.weekKey) else { return sum }
            return sum + plan.blocks.filter { b in
                let d = Week.day(b.day, of: monday)
                return (projectId == nil || b.projectId == projectId) && d >= from && d < to
            }.reduce(0) { $0 + $1.hours }
        }
    }

    /// Days in a row with at least half an hour of work. Today doesn't break the run while it is still short.
    static func streak(_ hoursByDay: [Date: Double], today: Date) -> (current: Int, best: Int) {
        let cal = Week.calendar
        let worked = Set(hoursByDay.filter { $0.value >= workedThreshold }.keys.map { cal.startOfDay(for: $0) })
        var current = 0
        var day = worked.contains(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while worked.contains(day) {
            current += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        var best = 0, run = 0
        var previous: Date?
        for d in worked.sorted() {
            if let p = previous, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = d
        }
        return (current, max(best, current))
    }

    /// Hours by weekday and hour: timer intervals cut exactly, agent time spread evenly over the session's window.
    static func heat(projects: [ProjectSnapshot], worklog: [WorkInterval], from: Date, to: Date, now: Date) -> [[Double]] {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        let cal = Week.calendar
        func add(_ start: Date, _ end: Date, weight: Double) {
            var cursor = max(start, from)
            let stop = min(end, to)
            while cursor < stop {
                let hourStart = cal.dateInterval(of: .hour, for: cursor)!.start
                let next = min(hourStart.addingTimeInterval(3600), stop)
                grid[Week.weekdayIndex(cursor)][cal.component(.hour, from: cursor)] += next.timeIntervalSince(cursor) * weight / 3600
                cursor = next
            }
        }
        for interval in worklog { add(interval.start, interval.end ?? now, weight: 1) }
        for p in projects {
            let timer = worklog.filter { $0.projectId == p.config.id }
            for s in p.sessions where s.end > from && s.start < to {
                let window = max(60, s.end.timeIntervalSince(s.start))
                add(s.start, max(s.end, s.start.addingTimeInterval(60)), weight: min(1, agentSeconds(s, timer: timer, now: now) / window))
            }
        }
        return grid
    }

    /// The shortest run of consecutive buckets that holds at least `share` of the total.
    static func densestRun(_ values: [Double], share: Double) -> ClosedRange<Int>? {
        let total = values.reduce(0, +)
        guard total > 0 else { return nil }
        var best: ClosedRange<Int>?
        for start in values.indices {
            var sum = 0.0
            for end in start..<values.count {
                sum += values[end]
                if sum >= total * share {
                    if best == nil || end - start < best!.count - 1 { best = start...end }
                    break
                }
            }
        }
        return best
    }
}
