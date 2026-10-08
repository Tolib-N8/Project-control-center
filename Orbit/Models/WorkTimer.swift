import Foundation

// MARK: - What "Начать разработку" opens

enum LaunchKind: Codable, Hashable {
    /// The project's terminal with the agent: resumes an unfinished session or starts a new one.
    case terminalAgent
    case app(path: String)
    case url(String)
}

struct LaunchItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: LaunchKind
    var name: String
    var enabled = true
    /// Open the project folder in this app (editors) instead of just launching it.
    var opensFolder = false
}

enum LaunchSet {
    /// Apps that take a folder and open it as a project.
    static let editors = ["Cursor", "Visual Studio Code", "Zed", "Windsurf", "Xcode", "Sublime Text", "Nova", "Fleet",
                          "IntelliJ IDEA", "WebStorm", "PyCharm", "GoLand", "PhpStorm", "RubyMine", "CLion", "RustRover", "Android Studio"]
    /// Offered by default, first one installed wins.
    static let preferredEditors = ["Cursor", "Visual Studio Code", "Zed"]

    /// Terminals open a new window in a folder given to them.
    static let terminals = ["Terminal", "iTerm", "Ghostty", "Warp", "kitty", "WezTerm", "Alacritty"]

    static func isTerminal(_ appPath: String) -> Bool {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return terminals.contains { name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "2") }
    }

    static func isEditor(_ appPath: String) -> Bool {
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return editors.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    /// Path of an app in /Applications or ~/Applications.
    static func installedApp(_ name: String) -> String? {
        ["/Applications", "\(NSHomeDirectory())/Applications"]
            .map { "\($0)/\(name).app" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func terminalItem() -> LaunchItem {
        LaunchItem(kind: .terminalAgent, name: tr("Терминал с агентом", "Terminal with agent"))
    }

    static func appItem(_ path: String) -> LaunchItem {
        let name = (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
        return LaunchItem(kind: .app(path: path), name: name, opensFolder: isEditor(path) || isTerminal(path))
    }

    /// "localhost:3000" → "http://localhost:3000"; nil for text that isn't a link.
    static func urlItem(_ text: String) -> LaunchItem? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = (s.hasPrefix("localhost") || s.hasPrefix("127.") ? "http://" : "https://") + s }
        guard let url = URL(string: s), url.host != nil else { return nil }
        let host = url.host! + (url.port.map { ":\($0)" } ?? "")
        return LaunchItem(kind: .url(s), name: host)
    }

    /// Terminal with the agent plus the first editor that is installed.
    static func defaults(installed: (String) -> String? = installedApp) -> [LaunchItem] {
        var items = [terminalItem()]
        if let editor = preferredEditors.lazy.compactMap(installed).first { items.append(appItem(editor)) }
        return items
    }

    static func items(for project: ProjectConfig) -> [LaunchItem] {
        project.launch ?? defaults()
    }
}

// MARK: - Timer

struct WorkInterval: Codable, Hashable {
    var projectId: String
    var start: Date
    var end: Date?

    func seconds(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }

    /// Seconds of this interval inside [from, to).
    func overlap(from: Date, to: Date, now: Date) -> TimeInterval {
        max(0, min(end ?? now, to).timeIntervalSince(max(start, from)))
    }
}

/// Everything the timer has recorded, in ~/.orbit/worklog.json.
struct WorkLog: Codable, Hashable {
    struct Current: Codable, Hashable {
        var projectId: String
        var sessionStart: Date
        var paused: Bool
        /// Bundle ids "Начать разработку" launched, to quit on stop.
        var openedApps: [String]?
        /// The desktop it created, to remove on stop.
        var desktop: SpaceManager.Desktop?
    }

    var intervals: [WorkInterval] = []
    var current: Current?
    /// Last minute Orbit was alive with the timer running; an open interval is closed here after a quit or crash.
    var lastBeat: Date?

    var isRunning: Bool { current.map { !$0.paused } ?? false }

    /// Starts (or resumes) the timer on a project; another running project is closed first.
    mutating func start(_ projectId: String, at now: Date) {
        if let c = current, c.projectId == projectId {
            if c.paused { resume(at: now) }
            return
        }
        stop(at: now)
        current = Current(projectId: projectId, sessionStart: now, paused: false)
        intervals.append(WorkInterval(projectId: projectId, start: now))
        lastBeat = now
    }

    mutating func pause(at now: Date) {
        guard var c = current, !c.paused else { return }
        closeOpen(at: now)
        c.paused = true
        current = c
    }

    mutating func resume(at now: Date) {
        guard var c = current, c.paused else { return }
        intervals.append(WorkInterval(projectId: c.projectId, start: now))
        c.paused = false
        current = c
        lastBeat = now
    }

    /// Ends the session and returns how long it lasted.
    @discardableResult
    mutating func stop(at now: Date) -> TimeInterval? {
        guard current != nil else { return nil }
        closeOpen(at: now)
        let total = elapsed(at: now)
        current = nil
        return total
    }

    /// Time worked in the current session, pauses excluded.
    func elapsed(at now: Date) -> TimeInterval {
        guard let c = current else { return 0 }
        return intervals.filter { $0.projectId == c.projectId && $0.start >= c.sessionStart }.reduce(0) { $0 + $1.seconds(now: now) }
    }

    func seconds(_ projectId: String, from: Date, to: Date, now: Date) -> TimeInterval {
        intervals.filter { $0.projectId == projectId }.reduce(0) { $0 + $1.overlap(from: from, to: to, now: now) }
    }

    /// After Orbit was off for a while, the open interval ends at the last heartbeat and the timer waits on pause.
    mutating func recover(now: Date, maxGap: TimeInterval = 5 * 60) {
        guard isRunning else { return }
        let beat = lastBeat ?? intervals.last?.start ?? now
        guard now.timeIntervalSince(beat) > maxGap else { return }
        closeOpen(at: beat)
        current?.paused = true
    }

    /// Keeps a few months of history.
    mutating func prune(before date: Date) {
        intervals.removeAll { ($0.end ?? .distantFuture) < date }
    }

    private mutating func closeOpen(at now: Date) {
        for i in intervals.indices where intervals[i].end == nil {
            intervals[i].end = max(now, intervals[i].start)
        }
    }
}

// MARK: - Clock text

extension Duration {
    /// "12:05", "1:12:05"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// What "Стоп" is waiting on before it removes the project's desktop.
struct DesktopCleanup: Equatable {
    var desktop: SpaceManager.Desktop
    var apps: [String]
}
