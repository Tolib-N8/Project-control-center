import Foundation

/// Accumulates parsed log events and splits them into working sessions.
/// Shared by all agent log parsers.
final class SessionBuilder {
    /// A pause longer than this starts a new session.
    static let sessionGap: TimeInterval = 3 * 3600
    /// Pauses longer than this do not count as active time.
    static let idleCap: TimeInterval = 10 * 60

    private struct Segment {
        var start: Date
        var lastTime: Date
        var active: TimeInterval = 0
        var cwdCounts: [String: Int] = [:]
        var firstPrompt: String?
        var finalMessage: String?
        var title: String?
        var model: String?
        var files: [String] = []
        var filesSet: Set<String> = []
        var filesRead: Set<String> = []
        var added = 0
        var removed = 0
        var tokens = 0
        var testsPassed: Int?
        var testsFailed: Int?
        var lastFailingTest: String?
        var reverts = 0
        var editsPerFile: [String: Int] = [:]
        var lastError: String?
        var events: [SessionEvent] = []
        var hasActivity = false
    }

    let agent: AgentKind
    let logPath: String
    var resumeId: String?
    var defaultCwd: String
    /// Title for the whole log (e.g. Claude ai-title, Codex thread name).
    var globalTitle: String?

    private var segments: [Segment] = []
    private var current: Segment?
    private var editHistory: [String: [(old: String, new: String)]] = [:]

    init(agent: AgentKind, logPath: String, resumeId: String?, cwd: String) {
        self.agent = agent
        self.logPath = logPath
        self.resumeId = resumeId
        self.defaultCwd = cwd
    }

    // MARK: - Timeline

    func touch(_ time: Date, cwd: String? = nil) {
        if var seg = current {
            let gap = time.timeIntervalSince(seg.lastTime)
            if gap > Self.sessionGap {
                segments.append(seg)
                current = Segment(start: time, lastTime: time)
            } else if gap > 0 {
                seg.active += min(gap, Self.idleCap)
                seg.lastTime = time
                current = seg
            }
        } else {
            current = Segment(start: time, lastTime: time)
        }
        if let cwd, !cwd.isEmpty, var seg = current {
            seg.cwdCounts[cwd, default: 0] += 1
            current = seg
        }
    }

    func setTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        globalTitle = t
        update { $0.title = t }
    }

    func setModel(_ model: String) {
        guard !model.isEmpty, !model.hasPrefix("<") else { return }
        update { $0.model = model }
    }

    func addTokens(_ n: Int) { update { $0.tokens += n } }

    func setTokens(_ n: Int) {
        guard var seg = current else { return }
        seg.tokens = max(seg.tokens, n)
        current = seg
    }

    private func update(_ body: (inout Segment) -> Void) {
        guard var seg = current else { return }
        body(&seg)
        current = seg
    }

    // MARK: - Events

    func prompt(_ time: Date, _ text: String) {
        let clean = Self.cleanPrompt(text)
        guard !clean.isEmpty else { return }
        touch(time)
        update { if $0.firstPrompt == nil { $0.firstPrompt = clean } }
        update { $0.hasActivity = true }
        append(SessionEvent(time: time, kind: .prompt, text: String(clean.prefix(200))))
    }

    func assistantText(_ time: Date, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 20 else { return }
        update { $0.finalMessage = t }
    }

    func read(_ time: Date, file: String) {
        touch(time)
        update { _ = $0.filesRead.insert(file) }
        update { $0.hasActivity = true }
        merge(SessionEvent(time: time, kind: .read, text: "", files: [file]))
    }

    func edit(_ time: Date, file: String, old: String, new: String) {
        touch(time)
        let (a, r) = Self.lineDiff(old: old, new: new)
        let isRevert = editHistory[file]?.contains { $0.old == new && $0.new == old && !old.isEmpty } ?? false
        editHistory[file, default: []].append((old, new))
        recordEdit(time, file: file, added: a, removed: r, isRevert: isRevert)
    }

    func patch(_ time: Date, file: String, added: Int, removed: Int) {
        touch(time)
        recordEdit(time, file: file, added: added, removed: removed, isRevert: false)
    }

    private func recordEdit(_ time: Date, file: String, added: Int, removed: Int, isRevert: Bool) {
        guard var seg = current else { return }
        seg.hasActivity = true
        if !seg.filesSet.contains(file) {
            seg.filesSet.insert(file)
            seg.files.append(file)
        }
        seg.added += added
        seg.removed += removed
        seg.editsPerFile[file, default: 0] += 1
        current = seg
        if isRevert {
            update { $0.reverts += 1 }
            append(SessionEvent(time: time, kind: .revert, text: tr("Откат правки", "Edit reverted"), files: [file]))
        } else {
            merge(SessionEvent(time: time, kind: .edit, text: "", files: [file]))
        }
    }

    func command(_ time: Date, _ command: String) {
        touch(time)
        update { $0.hasActivity = true }
        if Self.isRevertCommand(command) {
            update { $0.reverts += 1 }
            append(SessionEvent(time: time, kind: .revert, text: String(command.prefix(120))))
        } else if Self.isCommitCommand(command) {
            append(SessionEvent(time: time, kind: .commit, text: Self.commitMessage(command) ?? "git commit"))
        } else if !Self.isTestCommand(command) {
            merge(SessionEvent(time: time, kind: .bash, text: String(command.prefix(300))))
        }
    }

    /// Result of a shell command; parses test output when the command ran tests.
    func commandResult(_ time: Date, command: String, output: String, isError: Bool) {
        if Self.isTestCommand(command) {
            touch(time)
            var result = TestOutput.parse(output)
            if result.passed == nil && result.failed == nil {
                result.failed = isError ? 1 : 0
            }
            update { $0.testsPassed = result.passed }
            update { $0.testsFailed = result.failed }
            if (result.failed ?? 0) > 0 {
                update { $0.lastFailingTest = result.failingName }
                if let e = result.firstError { update { $0.lastError = e } }
            } else {
                update { $0.lastFailingTest = nil }
            }
            append(SessionEvent(time: time, kind: .test, text: String(command.prefix(300)),
                                passed: result.passed, failed: result.failed))
        } else if isError {
            let line = output.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let line { update { $0.lastError = String(line.prefix(240)) } }
        }
    }

    private func append(_ event: SessionEvent) {
        update { $0.events.append(event) }
    }

    /// Merges consecutive reads/edits/commands into one timeline entry.
    private func merge(_ event: SessionEvent) {
        guard var seg = current else { return }
        if var last = seg.events.last, last.kind == event.kind,
           [.read, .edit, .bash].contains(event.kind),
           event.time.timeIntervalSince(last.time) < 15 * 60 {
            for f in event.files where !last.files.contains(f) && last.files.count < 50 { last.files.append(f) }
            last.count += 1
            if event.kind == .bash { last.text = event.text }
            seg.events[seg.events.count - 1] = last
        } else {
            seg.events.append(event)
        }
        current = seg
    }

    // MARK: - Output

    func finish() -> [AgentSession] {
        if let current { segments.append(current) }
        current = nil
        let useful = segments.filter { $0.hasActivity }
        return useful.enumerated().map { index, seg in
            let cwd = seg.cwdCounts.max { $0.value < $1.value }?.key ?? defaultCwd
            let prompt = seg.firstPrompt ?? ""
            let title: String
            // Resumed segments get their own title, unless the prompt is just "continue"-like.
            if useful.count > 1 && index > 0 && prompt.count >= 20 {
                title = Self.titleFromPrompt(prompt)
            } else {
                title = seg.title ?? globalTitle ?? (prompt.isEmpty ? tr("Сессия \(agent.title)", "\(agent.title) session") : Self.titleFromPrompt(prompt))
            }
            var events = seg.events
            events.append(SessionEvent(time: seg.lastTime, kind: .stop, text: ""))
            return AgentSession(
                id: "\(agent.rawValue):\(resumeId ?? logPath):\(index)",
                agent: agent,
                resumeId: resumeId,
                logPath: logPath,
                cwd: cwd,
                title: title,
                firstPrompt: String(prompt.prefix(600)),
                finalMessage: seg.finalMessage.map { String($0.prefix(1200)) },
                model: seg.model,
                start: seg.start,
                end: seg.lastTime,
                activeSeconds: max(seg.active, 60),
                filesTouched: seg.files,
                filesRead: seg.filesRead.count,
                linesAdded: seg.added,
                linesRemoved: seg.removed,
                tokens: seg.tokens,
                testsPassed: seg.testsPassed,
                testsFailed: seg.testsFailed,
                lastFailingTest: seg.lastFailingTest,
                reverts: seg.reverts,
                editsPerFile: seg.editsPerFile,
                lastError: seg.lastError,
                events: Array(events.suffix(300))
            )
        }
    }

    // MARK: - Helpers

    static func cleanPrompt(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted") { return "" }
        return t
    }

    static func titleFromPrompt(_ prompt: String) -> String {
        var firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        // Drop attachment markers like "[Image #1]".
        firstLine = firstLine.replacingOccurrences(of: #"\[(Image|Pasted text|File) #\d+[^\]]*\]\s*"#, with: "", options: .regularExpression)
        let t = firstLine.trimmingCharacters(in: .whitespaces)
        return t.count > 70 ? String(t.prefix(67)) + "…" : t
    }

    static func lineDiff(old: String, new: String) -> (Int, Int) {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        if a.count * b.count > 4_000_000 { return (b.count, a.count) }
        let diff = b.difference(from: a)
        return (diff.insertions.count, diff.removals.count)
    }

    private static let testRegex = try! NSRegularExpression(pattern:
        #"(pytest|\bjest\b|vitest|mocha|rspec|phpunit|playwright test|go test|cargo (nextest|test)|swift test|xcodebuild[^|;&]*\btest\b|(npm|pnpm|yarn|bun)( run)? test|make test|gradlew? test|mix test|deno test|python3? -m (unittest|pytest)|\btest\.sh\b)"#)

    static func isTestCommand(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return testRegex.firstMatch(in: command, range: range) != nil
    }

    private static let revertRegex = try! NSRegularExpression(pattern:
        #"git (restore\b|reset --hard|revert\b|checkout -- |checkout \.(\s|$)|stash(\s+push)?(\s|$|;|&))"#)

    static func isRevertCommand(_ command: String) -> Bool {
        revertRegex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    static func isCommitCommand(_ command: String) -> Bool {
        command.contains("git commit")
    }

    static func commitMessage(_ command: String) -> String? {
        // Heredoc form: git commit -m "$(cat <<'EOF'\nsubject\n…EOF\n)"
        if let heredoc = command.range(of: "<<'EOF'\n") ?? command.range(of: "<<EOF\n") {
            return command[heredoc.upperBound...].split(separator: "\n").first.map(String.init)
        }
        guard let r = command.range(of: #"-m\s+["']([^"'\n]+)"#, options: .regularExpression) else { return nil }
        let m = command[r].dropFirst(2).trimmingCharacters(in: .whitespaces)
        let message = String(m.dropFirst())
        return message.hasPrefix("$(") ? nil : message
    }
}

struct TestOutput {
    var passed: Int?
    var failed: Int?
    var failingName: String?
    var firstError: String?

    static func parse(_ output: String) -> TestOutput {
        var r = TestOutput()
        func ints(_ pattern: String) -> [Int] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return re.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                Range($0.range(at: 1), in: output).flatMap { Int(output[$0]) }
            }
        }

        let executed = ints(#"Executed (\d+) tests?, with \d+ failures?"#)
        let executedFail = ints(#"Executed \d+ tests?, with (\d+) failures?"#)
        if let total = executed.last, let failed = executedFail.last {
            r.passed = total - failed
            r.failed = failed
        } else {
            let passed = ints(#"(\d+) (?:tests? )?(?:passed|passing)"#)
            let failed = ints(#"(\d+) (?:tests? )?(?:failed|failing|failures?)"#)
            if let p = passed.last { r.passed = p }
            if let f = failed.last { r.failed = f }
            if r.passed != nil && r.failed == nil { r.failed = 0 }
            if r.passed == nil && r.failed == nil {
                let goFails = output.components(separatedBy: "--- FAIL").count - 1
                let goPasses = output.components(separatedBy: "--- PASS").count - 1
                if goFails + goPasses > 0 { r.passed = goPasses; r.failed = goFails }
            }
        }

        for line in output.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if r.failingName == nil, l.hasPrefix("FAIL ") || l.hasPrefix("FAILED ") || l.hasPrefix("--- FAIL") || l.hasPrefix("✕") || l.hasPrefix("✘") {
                r.failingName = String(l.split(separator: " ", maxSplits: 1).last ?? Substring(l)).trimmingCharacters(in: .whitespaces).prefix(160).description
            }
            if r.firstError == nil, l.contains("Error:") || l.hasPrefix("error:") || l.contains("AssertionError") || l.hasPrefix("Expected") {
                r.firstError = String(l.prefix(240))
            }
        }
        return r
    }
}
