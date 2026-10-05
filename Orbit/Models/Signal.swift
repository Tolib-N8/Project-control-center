import Foundation

enum SignalRuleKind: String, Codable, CaseIterable, Identifiable {
    case uncommitted, behindMain, agentReverts, testsFailing, idle, skippedDay, tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommitted: tr("Незакоммиченные изменения", "Uncommitted changes")
        case .behindMain: tr("Ветка отстала от main", "Branch behind main")
        case .agentReverts: tr("Агент откатывает правки", "Agent reverts its edits")
        case .testsFailing: tr("Тесты падают", "Tests failing")
        case .idle: tr("Проект без работы", "Idle project")
        case .skippedDay: tr("День пропущен по плану", "Planned day skipped")
        case .tokens: tr("Расход токенов", "Token usage")
        }
    }

    func subtitle(_ threshold: Double) -> String {
        let t = Int(threshold)
        switch self {
        case .uncommitted: return tr("дольше \(t) ч", "longer than \(t) h")
        case .behindMain: return tr("больше \(t) коммитов", "more than \(t) commits")
        case .agentReverts: return tr("\(t) раза подряд", "\(t) times in a row")
        case .testsFailing: return tr("в последней сессии агента", "in the latest agent session")
        case .idle: return tr("дольше \(t) дней", "longer than \(t) days")
        case .skippedDay: return tr("в конце дня", "at the end of the day")
        case .tokens: return tr("больше \(t / 1_000_000)M за сессию", "over \(t / 1_000_000)M per session")
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .uncommitted: 24
        case .behindMain: 20
        case .agentReverts: 3
        case .testsFailing: 1
        case .idle: 7
        case .skippedDay: 1
        case .tokens: 1_000_000
        }
    }

    var defaultEnabled: Bool { self != .skippedDay && self != .tokens }

    var symbol: String {
        switch self {
        case .uncommitted: "doc.badge.plus"
        case .behindMain: "arrow.triangle.branch"
        case .agentReverts: "arrow.counterclockwise"
        case .testsFailing: "xmark.circle"
        case .idle: "moon"
        case .skippedDay: "calendar.badge.exclamationmark"
        case .tokens: "circle.hexagongrid"
        }
    }
}

struct SignalRuleConfig: Codable, Hashable {
    var kind: SignalRuleKind
    var enabled: Bool
    var threshold: Double

    init(kind: SignalRuleKind) {
        self.kind = kind
        enabled = kind.defaultEnabled
        threshold = kind.defaultThreshold
    }
}

enum SignalSeverity: String, Codable {
    case critical, warning

    var title: String { self == .critical ? tr("Критично", "Critical") : tr("Внимание", "Warning") }
}

enum SignalState: String, Codable {
    case active, snoozed, resolved
}

struct SignalMetric: Codable, Hashable {
    var label: String
    var value: String
}

struct Signal: Codable, Hashable, Identifiable {
    /// Fingerprint: rule + project (+ detail), so a recurring condition maps to the same signal.
    var id: String
    var kind: SignalRuleKind
    var projectId: String
    var severity: SignalSeverity
    var title: String
    var detail: String
    var metrics: [SignalMetric]
    var detectedAt: Date
    var state: SignalState = .active
    var snoozedUntil: Date?
    var resolvedAt: Date?
    var resolution: String?
    var notified = false
}
