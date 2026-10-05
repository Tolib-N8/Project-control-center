import Foundation

/// The user's choice in Settings.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    /// Shown in the picker in its own language, so anyone can find theirs.
    var title: String {
        switch self {
        case .system: tr("Как в системе", "System")
        case .ru: "Русский"
        case .en: "English"
        }
    }

    var resolved: Lang {
        switch self {
        case .ru: .ru
        case .en: .en
        case .system: Lang.system
        }
    }
}

/// The language the interface is actually shown in.
enum Lang: String {
    case ru, en

    /// Russian if the user's first preferred macOS language is Russian, English otherwise.
    static var system: Lang {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }

    var locale: Locale { Locale(identifier: self == .ru ? "ru_RU" : "en_US") }
}

/// Current interface language. Set by `AppState` from the config; views rebuild when it changes.
enum L10n {
    nonisolated(unsafe) static var current: Lang = .system
}

/// The string for the current interface language. Both versions sit side by side in the code,
/// which keeps a two-language app easy to keep in sync and switches instantly at runtime.
func tr(_ ru: String, _ en: String) -> String {
    L10n.current == .ru ? ru : en
}

/// Count with a correctly inflected word: `plural(3, ru: ("файл", "файла", "файлов"), en: ("file", "files"))`.
func plural(_ n: Int, ru: (one: String, few: String, many: String), en: (one: String, other: String)) -> String {
    "\(n) \(pluralWord(n, ru: ru, en: en))"
}

/// Just the word, without the number.
func pluralWord(_ n: Int, ru: (one: String, few: String, many: String), en: (one: String, other: String)) -> String {
    switch L10n.current {
    case .ru: Plural.ru(n, ru.one, ru.few, ru.many)
    case .en: abs(n) == 1 ? en.one : en.other
    }
}
