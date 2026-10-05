import Foundation

/// Rule-based weekly planner: spreads the week's capacity across projects by urgency.
enum Planner {
    struct Demand {
        var projectId: String
        var priority: Double
        var hours: Int
        var urgent: Bool
        var preferredDays: [Int]
    }

    static func demands(projects: [ProjectSnapshot], signals: [Signal], capacity: Int) -> [Demand] {
        guard !projects.isEmpty, capacity > 0 else { return [] }
        var raw: [(ProjectSnapshot, Double, Bool)] = projects.map { p in
            let health = HealthEngine.score(p)
            let own = signals.filter { $0.projectId == p.config.id && $0.state == .active }
            let urgent = own.contains { $0.severity == .critical }
            var priority = Double(100 - health)
            priority += Double(own.filter { $0.severity == .critical }.count) * 30
            priority += Double(own.filter { $0.severity == .warning }.count) * 12
            let idle = min(p.idleDays(), 21)
            priority += Double(idle) * 1.5
            // Recently active projects keep momentum.
            let recentHours = p.sessions(in: 14).reduce(0) { $0 + $1.activeSeconds } / 3600
            priority += min(25, recentHours * 1.5)
            return (p, max(priority, 8), urgent)
        }
        raw.sort { $0.1 > $1.1 }
        let total = raw.reduce(0) { $0 + $1.1 }
        var result = raw.map { p, prio, urgent in
            Demand(projectId: p.config.id, priority: prio,
                   hours: max(2, Int((Double(capacity) * prio / total).rounded())),
                   urgent: urgent, preferredDays: p.config.workDays)
        }
        // Trim to capacity, taking hours from the least urgent projects first.
        var overflow = result.reduce(0) { $0 + $1.hours } - capacity
        var i = result.count - 1
        while overflow > 0 && i >= 0 {
            let cut = min(overflow, result[i].hours - 2)
            if cut > 0 { result[i].hours -= cut; overflow -= cut }
            i -= 1
        }
        if overflow > 0 {
            while overflow > 0, let last = result.last, last.hours <= 2 {
                overflow -= last.hours
                result.removeLast()
            }
        }
        return result
    }

    static func makePlan(weekKey: String, projects: [ProjectSnapshot], signals: [Signal], rhythm: Rhythm,
                         startDay: Int = 0, seed: Int = 0) -> WeekPlan {
        var capacity = rhythm.hours
        for d in 0..<min(startDay, 7) { capacity[d] = 0 }
        let totalCapacity = capacity.reduce(0, +)
        var demands = demands(projects: projects, signals: signals, capacity: totalCapacity)
        if seed != 0 {
            // "Другой вариант": shuffle non-urgent projects and favour other days.
            var rng = SeededRandom(seed: UInt64(seed))
            let urgent = demands.filter(\.urgent)
            demands = urgent + demands.filter { !$0.urgent }.shuffled(using: &rng)
        }

        var blocks: [PlanBlock] = []
        var free = capacity
        var projectsOnDay = Array(repeating: 0, count: 7)
        let maxPerDay = max(1, rhythm.maxProjectsPerDay)
        let workDays = (0..<7).filter { capacity[$0] > 0 }
        let rotation = seed == 0 ? 0 : seed % max(1, workDays.count)

        for demand in demands {
            var remaining = demand.hours
            let minBlock = demand.hours >= 8 ? 4 : 2
            var order = workDays
            if demand.urgent {
                order = workDays.sorted()
            } else {
                order = Array(order[rotation...] + order[..<rotation])
                if !demand.preferredDays.isEmpty {
                    order.sort { demand.preferredDays.contains($0) && !demand.preferredDays.contains($1) }
                }
            }
            for day in order where remaining > 0 {
                guard projectsOnDay[day] < maxPerDay, free[day] >= min(minBlock, remaining) else { continue }
                // Blocks of at most 6 h leave room for a second project that day.
                let chunk = min(remaining, free[day], 6)
                guard chunk > 0 else { continue }
                blocks.append(PlanBlock(projectId: demand.projectId, day: day, hours: Double(chunk)))
                free[day] -= chunk
                projectsOnDay[day] += 1
                remaining -= chunk
                if demand.urgent && remaining > 0 && remaining < minBlock { break }
            }
        }
        assignStartTimes(&blocks, rhythm: rhythm)

        var plan = WeekPlan(weekKey: weekKey, blocks: blocks, generated: true)
        plan.rationale = rationale(demands: demands, blocks: blocks, projects: projects)
        plan.rationaleLang = L10n.current.rawValue
        return plan
    }

    static func assignStartTimes(_ blocks: inout [PlanBlock], rhythm: Rhythm) {
        var cursor: [Int: Double] = [:]
        for i in blocks.indices {
            let day = blocks[i].day
            let start = cursor[day] ?? Double(rhythm.dayStartHour)
            blocks[i].startHour = start
            cursor[day] = start + blocks[i].hours
        }
    }

    static func rationale(demands: [Demand], blocks: [PlanBlock], projects: [ProjectSnapshot]) -> String {
        func name(_ id: String) -> String { projects.first { $0.config.id == id }?.config.name ?? id }
        var parts: [String] = []
        if let urgent = demands.first(where: \.urgent), let first = blocks.filter({ $0.projectId == urgent.projectId }).map(\.day).min() {
            parts.append(tr("\(name(urgent.projectId)) поставлен на \(dayName(first).lowercased()): есть критичный сигнал.", "\(name(urgent.projectId)) goes on \(dayName(first)): it has a critical signal."))
        }
        if let big = demands.max(by: { $0.hours < $1.hours }), big.hours >= 8 {
            parts.append(tr("\(name(big.projectId)) — длинными блоками от 4 ч, у него больше всего работы.", "\(name(big.projectId)) gets long blocks of 4 h or more: it has the most work."))
        }
        let skipped = projects.filter { p in !blocks.contains { $0.projectId == p.config.id } }
        if !skipped.isEmpty {
            parts.append(tr("Без времени на этой неделе: \(skipped.map(\.config.name).joined(separator: ", ")).", "No time this week: \(skipped.map(\.config.name).joined(separator: ", "))."))
        }
        if parts.isEmpty { parts.append(tr("Время распределено по здоровью проектов и давности последней работы.", "Time is split by project health and how long ago each was last worked on.")) }
        return parts.joined(separator: " ")
    }

    /// "рекомендуем 10—12 ч"
    static func recommendation(for projectId: String, demands: [Demand]) -> String? {
        guard let d = demands.first(where: { $0.projectId == projectId }) else { return nil }
        return tr("рекомендуем \(max(1, d.hours - 1))—\(d.hours + 1) ч", "suggested \(max(1, d.hours - 1))–\(d.hours + 1) h")
    }

    static func dayName(_ index: Int) -> String {
        [tr("Понедельник", "Monday"), tr("Вторник", "Tuesday"), tr("Среду", "Wednesday"), tr("Четверг", "Thursday"), tr("Пятницу", "Friday"), tr("Субботу", "Saturday"), tr("Воскресенье", "Sunday")][index]
    }
}

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
