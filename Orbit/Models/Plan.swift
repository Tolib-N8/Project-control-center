import Foundation

struct PlanBlock: Codable, Hashable, Identifiable {
    var id = UUID()
    var projectId: String
    /// 0 = Monday … 6 = Sunday
    var day: Int
    var hours: Double
    var startHour: Double?
    var goal: String?
    var note: String?
}

struct WeekPlan: Codable, Hashable {
    /// yyyy-MM-dd of the week's Monday
    var weekKey: String
    var blocks: [PlanBlock] = []
    var rationale: String?
    var generated = false

    func blocks(on day: Int) -> [PlanBlock] { blocks.filter { $0.day == day } }
    func hours(on day: Int) -> Double { blocks(on: day).reduce(0) { $0 + $1.hours } }
    var totalHours: Double { blocks.reduce(0) { $0 + $1.hours } }
    func hours(for projectId: String) -> Double {
        blocks.filter { $0.projectId == projectId }.reduce(0) { $0 + $1.hours }
    }
}

/// Monday-based week helpers.
enum Week {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "ru_RU")
        c.timeZone = .current
        return c
    }()

    static func monday(of date: Date) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    static func key(_ monday: Date) -> String { DateFormat.isoDay.string(from: monday) }

    static func date(fromKey key: String) -> Date? { DateFormat.isoDay.date(from: key) }

    static func day(_ index: Int, of monday: Date) -> Date {
        calendar.date(byAdding: .day, value: index, to: monday)!
    }

    /// 0 = Monday … 6 = Sunday
    static func weekdayIndex(_ date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func number(_ date: Date) -> Int { calendar.component(.weekOfYear, from: date) }

    static let shortNames = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
}
