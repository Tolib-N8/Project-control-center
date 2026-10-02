import Foundation

/// Aider keeps a markdown history in the repository root.
enum AiderParser {
    static let fileName = ".aider.chat.history.md"

    static func historyFile(in repo: String) -> URL? {
        let path = (repo as NSString).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static let startFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parse(_ url: URL, repo: String) -> [AgentSession] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var sessions: [AgentSession] = []
        var builder: SessionBuilder?
        var clock = Date.distantPast
        var index = 0

        func close() {
            if let b = builder { sessions += b.finish() }
            builder = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("# aider chat started at ") {
                close()
                let stamp = String(line.dropFirst("# aider chat started at ".count)).trimmingCharacters(in: .whitespaces)
                clock = startFormatter.date(from: stamp) ?? clock
                index += 1
                builder = SessionBuilder(agent: .aider, logPath: url.path + "#\(index)", resumeId: nil, cwd: repo)
                builder?.touch(clock, cwd: repo)
            } else if line.hasPrefix("#### ") {
                // Aider does not log timestamps per message; assume ~2 minutes per exchange.
                clock = clock.addingTimeInterval(120)
                builder?.prompt(clock, String(line.dropFirst(5)))
            } else if line.hasPrefix("> Applied edit to ") {
                let file = String(line.dropFirst("> Applied edit to ".count))
                builder?.patch(clock, file: (repo as NSString).appendingPathComponent(file), added: 0, removed: 0)
            } else if line.hasPrefix("> Commit ") {
                builder?.command(clock, "git commit -m \"\(line.dropFirst(9))\"")
            }
        }
        close()
        return sessions
    }
}

/// Cursor stores chats in SQLite (state.vscdb). v1 only detects whether Cursor is present.
enum CursorDetector {
    static func defaultRoot() -> String { "~/Library/Application Support/Cursor".expandingTilde }

    static func isInstalled(path: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: path ?? defaultRoot())
    }
}
