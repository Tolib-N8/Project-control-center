import Foundation

enum SignalRuleKind: String, Codable, CaseIterable, Identifiable {
    case uncommitted, behindMain, agentReverts, testsFailing, idle, skippedDay, tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommitted: "Незакоммиченные изменения"
        case .behindMain: "Ветка отстала от main"
        case .agentReverts: "Агент откатывает правки"
        case .testsFailing: "Тесты падают"
        case .idle: "Проект без работы"
        case .skippedDay: "День пропущен по плану"
        case .tokens: "Расход токенов"
        }
    }

    func subtitle(_ threshold: Double) -> String {
        let t = Int(threshold)
        switch self {
        case .uncommitted: return "дольше \(t) ч"
        case .behindMain: return "больше \(t) коммитов"
        case .agentReverts: return "\(t) раза подряд"
        case .testsFailing: return "в последней сессии агента"
        case .idle: return "дольше \(t) дней"
        case .skippedDay: return "в конце дня"
        case .tokens: return "больше \(t / 1_000_000)M за сессию"
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

    var title: String { self == .critical ? "Критично" : "Внимание" }
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
