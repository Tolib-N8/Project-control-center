import Foundation

enum DateFormat {
    static let ru = Locale(identifier: "ru_RU")

    static let isoDay: DateFormatter = make("yyyy-MM-dd", locale: Locale(identifier: "en_US_POSIX"))
    static let time: DateFormatter = make("HH:mm")
    static let dayMonth: DateFormatter = make("d MMM")
    static let dayMonthFull: DateFormatter = make("d MMMM")
    static let weekdayFull: DateFormatter = make("EEEE")
    static let monthStandalone: DateFormatter = make("LLLL")

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601NoFraction = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        iso8601.date(from: s) ?? iso8601NoFraction.date(from: s)
    }

    private static func make(_ format: String, locale: Locale = ru) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    static let shortMonths = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]

    /// "28 сен"
    static func short(_ date: Date) -> String {
        let c = Week.calendar.dateComponents([.day, .month], from: date)
        return "\(c.day ?? 1) \(shortMonths[(c.month ?? 1) - 1])"
    }

    /// "вчера, 22:14" / "сегодня, 08:00" / "23 сен"
    static func relativeDay(_ date: Date, withTime: Bool = true) -> String {
        let cal = Week.calendar
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return withTime ? "сегодня, \(t)" : "сегодня" }
        if cal.isDateInYesterday(date) { return withTime ? "вчера, \(t)" : "вчера" }
        return short(date)
    }

    /// "Ср, 30 сен"
    static func weekdayShort(_ date: Date) -> String {
        "\(Week.shortNames[Week.weekdayIndex(date)]), \(short(date))"
    }

    /// "2 мин назад", "3 ч назад", "9 дн. назад"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "только что" }
        if s < 3600 { return "\(Int(s / 60)) мин назад" }
        if s < 86400 { return "\(Int(s / 3600)) ч назад" }
        return "\(Int(s / 86400)) дн. назад"
    }
}

enum Plural {
    /// Russian plural: forms for 1, 2-4, 5+.
    static func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = abs(n) % 10, n100 = abs(n) % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    static func files(_ n: Int) -> String { "\(n) \(ru(n, "файл", "файла", "файлов"))" }
    static func commits(_ n: Int) -> String { "\(n) \(ru(n, "коммит", "коммита", "коммитов"))" }
    static func sessions(_ n: Int) -> String { "\(n) \(ru(n, "сессия", "сессии", "сессий"))" }
    static func days(_ n: Int) -> String { "\(n) \(ru(n, "день", "дня", "дней"))" }
    static func tests(_ n: Int) -> String { "\(n) \(ru(n, "тест", "теста", "тестов"))" }
    static func times(_ n: Int) -> String { "\(n) \(ru(n, "раз", "раза", "раз"))" }
    static func projects(_ n: Int) -> String { "\(n) \(ru(n, "проект", "проекта", "проектов"))" }
    static func repos(_ n: Int) -> String { "\(n) \(ru(n, "репозиторий", "репозитория", "репозиториев"))" }
}

enum Duration {
    /// 47 мин, 1 ч 12 мин, 9 ч 40 мин
    static func text(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) мин" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(String(format: "%02d", m)) мин"
    }

    /// Age of something: "26 ч" up to two days, then "9 дн."
    static func age(hours: Double) -> String {
        hours < 48 ? "\(Int(hours)) ч" : "\(Int(hours / 24)) дн."
    }

    static func hours(_ h: Double) -> String {
        let r = (h * 2).rounded() / 2
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
    }
}

enum NumberText {
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
