import Foundation

/// A to-do inside a project, kept locally in ~/.orbit/tasks.json.
struct ProjectTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectId: String
    var title: String
    var urgent = false
    /// Top-level folder the task is about, without the trailing slash ("auth").
    var area: String?
    /// Day key (yyyy-MM-dd) the task is due, nil for no due date.
    var due: String?
    var createdAt = Date()
    var completedAt: Date?
    /// The agent the task was handed to, and when.
    var agent: AgentKind?
    var assignedAt: Date?

    var done: Bool { completedAt != nil }
}

/// A task suggested by AI, reviewed in the goal sheet before it is added.
struct TaskDraft: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var area: String?
    var urgent = false
    var selected = true

    /// Tasks for the ticked drafts; creation times step by a millisecond so their order survives sorting.
    static func tasks(_ drafts: [TaskDraft], projectId: String, now: Date = Date()) -> [ProjectTask] {
        drafts.filter(\.selected)
            .map { ($0, $0.title.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .enumerated()
            .map { i, item in
                ProjectTask(projectId: projectId, title: item.1, urgent: item.0.urgent, area: item.0.area,
                            createdAt: now.addingTimeInterval(Double(i) / 1000))
            }
    }
}

/// Where a task handed to an agent stands, judged from the agent's session logs.
struct TaskAgentState: Hashable {
    enum Phase: Hashable { case starting, working, review, stalled }

    var agent: AgentKind
    var phase: Phase
    var session: AgentSession?

    var label: String {
        let phase = switch phase {
        case .starting: tr("запускается", "starting")
        case .working: tr("в работе", "working")
        case .review: tr("на проверку", "to review")
        case .stalled: tr("не запустился", "didn’t start")
        }
        return "\(agent.title) · \(phase)"
    }

    var inFlight: Bool { phase == .starting || phase == .working }
}

enum TaskAgent {
    /// Agents that can take a task from the terminal.
    static let supported: [AgentKind] = [.claude, .codex]
    /// Without a session this long after the hand-off, the launch is considered failed.
    static let startWindow: TimeInterval = 20 * 60

    /// The prompt the agent starts with; it carries the title so the session can be matched back.
    static func prompt(for task: ProjectTask) -> String {
        var lines = [tr("Задача из Orbit: «\(task.title)».", "Task from Orbit: “\(task.title)”.")]
        if let area = task.area { lines.append(tr("Касается папки \(area)/.", "It concerns the \(area)/ folder.")) }
        if task.urgent { lines.append(tr("Это срочно.", "This is urgent.")) }
        lines.append(tr("Выполни её в этом репозитории. Если в проекте есть тесты — прогони их. В конце коротко опиши, что изменено и как это проверить.",
                        "Do it in this repository. If the project has tests, run them. When you finish, briefly describe what changed and how to check it."))
        return lines.joined(separator: "\n")
    }

    /// The session the agent ran for this task: started after the hand-off, preferably with the title in its first prompt.
    static func session(for task: ProjectTask, in sessions: [AgentSession]) -> AgentSession? {
        guard let agent = task.agent, let assigned = task.assignedAt else { return nil }
        let candidates = sessions
            .filter { $0.agent == agent && $0.start >= assigned.addingTimeInterval(-120) }
            .sorted { $0.start < $1.start }
        return candidates.first { $0.firstPrompt.contains(task.title) }
            ?? candidates.first { $0.start <= assigned.addingTimeInterval(5 * 60) }
    }

    static func state(for task: ProjectTask, sessions: [AgentSession], now: Date = Date()) -> TaskAgentState? {
        guard let agent = task.agent, let assigned = task.assignedAt else { return nil }
        if let s = session(for: task, in: sessions) {
            return TaskAgentState(agent: agent, phase: s.status == .active ? .working : .review, session: s)
        }
        let phase: TaskAgentState.Phase = now.timeIntervalSince(assigned) < startWindow ? .starting : .stalled
        return TaskAgentState(agent: agent, phase: phase, session: nil)
    }
}

enum TaskOrdering {
    /// Urgent first, then by due date (no date last), then oldest first.
    static func open(_ tasks: [ProjectTask]) -> [ProjectTask] {
        tasks.filter { !$0.done }.sorted { a, b in
            if a.urgent != b.urgent { return a.urgent }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.createdAt < b.createdAt
            }
        }
    }

    /// Most recently finished first.
    static func done(_ tasks: [ProjectTask]) -> [ProjectTask] {
        tasks.filter(\.done).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
}

enum TaskDue {
    enum Tone { case overdue, today, normal, none }

    /// "Сегодня" / "Завтра" / "Ср" (this week) / "12 окт" / "—"; overdue shows its date in red.
    static func label(_ due: String?, now: Date = Date()) -> (text: String, tone: Tone) {
        guard let due, let date = DateFormat.isoDay.date(from: due) else { return ("—", .none) }
        let cal = Week.calendar
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return (DateFormat.short(date), .overdue)
        case 0: return (tr("Сегодня", "Today"), .today)
        case 1: return (tr("Завтра", "Tomorrow"), .normal)
        default:
            if Week.monday(of: date) == Week.monday(of: now) {
                return (Week.shortNames[Week.weekdayIndex(date)], .normal)
            }
            return (DateFormat.short(date), .normal)
        }
    }

    /// Choices for the "Due" menu: today, tomorrow, the rest of this week (or the next few days).
    static func choices(now: Date = Date()) -> [(key: String, title: String)] {
        let cal = Week.calendar
        let today = cal.startOfDay(for: now)
        let remaining = max(5 - Week.weekdayIndex(now), 3)
        return (0...remaining).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            let title: String
            switch offset {
            case 0: title = tr("Сегодня", "Today")
            case 1: title = tr("Завтра", "Tomorrow")
            default: title = DateFormat.weekdayFull.string(from: d).capitalized(with: L10n.current.locale) + ", " + DateFormat.short(d)
            }
            return (DateFormat.isoDay.string(from: d), title)
        }
    }
}

enum TaskArea {
    private static let ignored: Set<String> = ["node_modules", "build", "dist", "out", "target", "vendor", "venv", "Pods", "DerivedData", "coverage"]

    /// Visible top-level folders of a repository, sorted by name.
    static func folders(in path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !ignored.contains($0) && !$0.hasSuffix(".xcodeproj") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The first folder mentioned as a whole word in the title ("тесты в auth" → "auth").
    static func detect(title: String, folders: [String]) -> String? {
        let words = Set(title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty })
        // Longer names first so "api-docs" wins over "api".
        return folders.sorted { $0.count > $1.count }.first { words.contains($0.lowercased()) }
    }
}
