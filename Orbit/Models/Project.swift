import Foundation

/// A tracked repository. Persisted in ~/.orbit/config.json.
struct ProjectConfig: Codable, Identifiable, Hashable {
    /// Absolute path of the repository root; doubles as the stable id.
    var id: String { path }
    var path: String
    var name: String
    var colorIndex: Int
    var archived: Bool = false
    /// Preferred work days, 0 = Monday … 6 = Sunday.
    var workDays: [Int] = []
    /// What "Начать разработку" opens; nil means the default set (terminal with the agent and an editor).
    var launch: [LaunchItem]?
    /// Keep .orbit/memory.md and the agent blocks up to date; nil means on.
    var memory: Bool?

    var displayPath: String { path.abbreviatingHome }
}

/// Weekly rhythm from onboarding step 3.
struct Rhythm: Codable, Hashable {
    /// Hours available per weekday, 0 = Monday … 6 = Sunday.
    var hours: [Int] = [7, 7, 7, 7, 7, 0, 0]
    var dayStartHour: Int = 10
    var maxProjectsPerDay: Int = 2
    var autoPlanSunday: Bool = true
    var morningBrief: Bool = true
    var signalsEnabled: Bool = true

    var weeklyHours: Int { hours.reduce(0, +) }
}

enum AgentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude, codex, cursor, aider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .aider: "Aider"
        }
    }

    var defaultLogPath: String {
        switch self {
        case .claude: "~/.claude/projects"
        case .codex: "~/.codex/sessions"
        case .cursor: "~/Library/Application Support/Cursor"
        case .aider: ".aider.chat.history.md"
        }
    }
}

struct AgentSourceConfig: Codable, Hashable {
    var enabled: Bool = true
    var customPath: String?
}

struct OrbitConfig: Codable {
    var onboarded = false
    var scanRoots: [String] = ["~/Documents/Projects"]
    var projects: [ProjectConfig] = []
    var agentSources: [String: AgentSourceConfig] = [:]
    var rhythm = Rhythm()
    var rules: [SignalRuleConfig] = SignalRuleKind.allCases.map { SignalRuleConfig(kind: $0) }
    var notifyMacOS = true
    var terminalApp = "Terminal"
    var lastMorningBrief: String?
    var lastAutoPlanWeek: String?
    var ai = AIConfig()
    var autoCheckUpdates = true
    var autoInstallUpdates = false
    var skippedVersion: String?
    var notifiedUpdateVersion: String?
    var language: AppLanguage = .system
    /// "Начать разработку" opens the apps on a new desktop and removes it on "Стоп".
    var devNewDesktop = true
    /// "Стоп" quits the apps that "Начать разработку" launched (those that weren't running before).
    var devCloseOnStop = true

    init() {}

    /// Every key is optional so configs written by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrbitConfig()
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        scanRoots = try c.decodeIfPresent([String].self, forKey: .scanRoots) ?? d.scanRoots
        projects = try c.decodeIfPresent([ProjectConfig].self, forKey: .projects) ?? d.projects
        agentSources = try c.decodeIfPresent([String: AgentSourceConfig].self, forKey: .agentSources) ?? d.agentSources
        rhythm = try c.decodeIfPresent(Rhythm.self, forKey: .rhythm) ?? d.rhythm
        rules = try c.decodeIfPresent([SignalRuleConfig].self, forKey: .rules) ?? d.rules
        notifyMacOS = try c.decodeIfPresent(Bool.self, forKey: .notifyMacOS) ?? d.notifyMacOS
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? d.terminalApp
        lastMorningBrief = try c.decodeIfPresent(String.self, forKey: .lastMorningBrief)
        lastAutoPlanWeek = try c.decodeIfPresent(String.self, forKey: .lastAutoPlanWeek)
        ai = try c.decodeIfPresent(AIConfig.self, forKey: .ai) ?? d.ai
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? d.autoCheckUpdates
        autoInstallUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? d.autoInstallUpdates
        skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        notifiedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .notifiedUpdateVersion)
        // Configs from before the English interface existed keep Russian, even on an English macOS.
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? (onboarded ? .ru : .system)
        devNewDesktop = try c.decodeIfPresent(Bool.self, forKey: .devNewDesktop) ?? d.devNewDesktop
        devCloseOnStop = try c.decodeIfPresent(Bool.self, forKey: .devCloseOnStop) ?? d.devCloseOnStop
    }

    func source(_ kind: AgentKind) -> AgentSourceConfig {
        agentSources[kind.rawValue] ?? AgentSourceConfig()
    }

    func rule(_ kind: SignalRuleKind) -> SignalRuleConfig {
        rules.first { $0.kind == kind } ?? SignalRuleConfig(kind: kind)
    }

    var activeProjects: [ProjectConfig] { projects.filter { !$0.archived } }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }

    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
