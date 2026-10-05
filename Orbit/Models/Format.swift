import Foundation

enum DateFormat {
    static let isoDay: DateFormatter = make("yyyy-MM-dd", locale: Locale(identifier: "en_US_POSIX"))
    static let time: DateFormatter = make("HH:mm", locale: Locale(identifier: "en_US_POSIX"))

    /// "пятница" / "Friday"
    static var weekdayFull: DateFormatter { localized("EEEE") }
    /// "2 октября" / "October 2"
    static var dayMonthFull: DateFormatter { localized(L10n.current == .ru ? "d MMMM" : "MMMM d") }
    /// "сентябрь" / "September"
    static var monthStandalone: DateFormatter { localized("LLLL") }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601NoFraction = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        iso8601.date(from: s) ?? iso8601NoFraction.date(from: s)
    }

    private static func make(_ format: String, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    /// One formatter per (pattern, language), created lazily.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func localized(_ format: String) -> DateFormatter {
        let lang = L10n.current
        let key = "\(lang.rawValue)|\(format)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let f = cache[key] { return f }
        let f = make(format, locale: lang.locale)
        cache[key] = f
        return f
    }

    static var shortMonths: [String] {
        tr("янв фев мар апр мая июн июл авг сен окт ноя дек", "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec")
            .split(separator: " ").map(String.init)
    }

    /// "28 сен" / "Sep 28"
    static func short(_ date: Date) -> String {
        let c = Week.calendar.dateComponents([.day, .month], from: date)
        let month = shortMonths[(c.month ?? 1) - 1]
        return L10n.current == .ru ? "\(c.day ?? 1) \(month)" : "\(month) \(c.day ?? 1)"
    }

    /// "вчера, 22:14" / "yesterday, 22:14" / "23 сен"
    static func relativeDay(_ date: Date, withTime: Bool = true) -> String {
        let cal = Week.calendar
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return withTime ? tr("сегодня, \(t)", "today, \(t)") : tr("сегодня", "today") }
        if cal.isDateInYesterday(date) { return withTime ? tr("вчера, \(t)", "yesterday, \(t)") : tr("вчера", "yesterday") }
        return short(date)
    }

    /// "Ср, 30 сен" / "Wed, Sep 30"
    static func weekdayShort(_ date: Date) -> String {
        "\(Week.shortNames[Week.weekdayIndex(date)]), \(short(date))"
    }

    /// "2 мин назад" / "2 min ago"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return tr("только что", "just now") }
        if s < 3600 { return tr("\(Int(s / 60)) мин назад", "\(Int(s / 60)) min ago") }
        if s < 86400 { return tr("\(Int(s / 3600)) ч назад", "\(Int(s / 3600)) h ago") }
        return tr("\(Int(s / 86400)) дн. назад", "\(Int(s / 86400)) d ago")
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

    static func files(_ n: Int) -> String { plural(n, ru: ("файл", "файла", "файлов"), en: ("file", "files")) }
    static func commits(_ n: Int) -> String { plural(n, ru: ("коммит", "коммита", "коммитов"), en: ("commit", "commits")) }
    static func sessions(_ n: Int) -> String { plural(n, ru: ("сессия", "сессии", "сессий"), en: ("session", "sessions")) }
    static func days(_ n: Int) -> String { plural(n, ru: ("день", "дня", "дней"), en: ("day", "days")) }
    static func tests(_ n: Int) -> String { plural(n, ru: ("тест", "теста", "тестов"), en: ("test", "tests")) }
    static func times(_ n: Int) -> String { plural(n, ru: ("раз", "раза", "раз"), en: ("time", "times")) }
    static func projects(_ n: Int) -> String { plural(n, ru: ("проект", "проекта", "проектов"), en: ("project", "projects")) }
    static func repos(_ n: Int) -> String { plural(n, ru: ("репозиторий", "репозитория", "репозиториев"), en: ("repository", "repositories")) }
}

enum Duration {
    /// 47 мин, 1 ч 12 мин / 47 min, 1 h 12 min
    static func text(minutes: Int) -> String {
        let h = tr("ч", "h"), min = tr("мин", "min")
        if minutes < 60 { return "\(minutes) \(min)" }
        let hh = minutes / 60, m = minutes % 60
        return m == 0 ? "\(hh) \(h)" : "\(hh) \(h) \(String(format: "%02d", m)) \(min)"
    }

    /// Age of something: "26 ч" / "26 h" up to two days, then "9 дн." / "9 d"
    static func age(hours: Double) -> String {
        hours < 48 ? tr("\(Int(hours)) ч", "\(Int(hours)) h") : tr("\(Int(hours / 24)) дн.", "\(Int(hours / 24)) d")
    }

    /// Hours rounded to a half: "6", "1,5" / "1.5"
    static func hours(_ h: Double) -> String {
        let r = (h * 2).rounded() / 2
        if r == r.rounded() { return "\(Int(r))" }
        let s = String(format: "%.1f", r)
        return L10n.current == .ru ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    /// Unit after `hours(_:)`: "ч" / "h"
    static var h: String { tr("ч", "h") }
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
        f.groupingSeparator = L10n.current == .ru ? " " : ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
