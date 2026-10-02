import Foundation

enum SessionEventKind: String, Codable, Hashable {
    case prompt, read, edit, bash, test, revert, commit, error, stop
}

struct SessionEvent: Codable, Hashable {
    var time: Date
    var kind: SessionEventKind
    var text: String
    /// Files involved; consecutive reads/edits/commands are merged into one event.
    var files: [String] = []
    var count: Int = 1
    var passed: Int?
    var failed: Int?
}

enum SessionStatus: String, Codable, Hashable {
    case active, done, unfinished, rolledBack

    var title: String {
        switch self {
        case .active: "Идёт"
        case .done: "Готово"
        case .unfinished: "Не завершено"
        case .rolledBack: "Откат"
        }
    }
}

/// One continuous working session of an agent on a project (a log file can split into several).
struct AgentSession: Codable, Hashable, Identifiable {
    var id: String
    var agent: AgentKind
    /// Id understood by the agent CLI for resuming (`claude --resume <id>`).
    var resumeId: String?
    var logPath: String
    var cwd: String
    var title: String
    var firstPrompt: String
    var finalMessage: String?
    var model: String?
    var start: Date
    var end: Date
    var activeSeconds: Double
    var filesTouched: [String]
    var filesRead: Int
    var linesAdded: Int
    var linesRemoved: Int
    var tokens: Int
    var testsPassed: Int?
    var testsFailed: Int?
    var lastFailingTest: String?
    var reverts: Int
    var editsPerFile: [String: Int]
    var lastError: String?
    var events: [SessionEvent]

    // Filled in by SessionAnalyzer, not cached.
    var projectId: String = ""
    var status: SessionStatus = .done
    var commitsInWindow: [String] = []

    var durationMinutes: Int { max(1, Int((activeSeconds / 60).rounded())) }

    var hottestFile: (path: String, edits: Int)? {
        editsPerFile.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, resumeId, logPath, cwd, title, firstPrompt, finalMessage, model, start, end
        case activeSeconds, filesTouched, filesRead, linesAdded, linesRemoved, tokens
        case testsPassed, testsFailed, lastFailingTest, reverts, editsPerFile, lastError, events
    }
}
