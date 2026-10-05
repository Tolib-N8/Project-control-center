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

    var done: Bool { completedAt != nil }
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
