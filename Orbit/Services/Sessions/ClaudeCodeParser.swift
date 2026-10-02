import Foundation

/// Parses Claude Code transcripts: ~/.claude/projects/<escaped-cwd>/<session>.jsonl
enum ClaudeCodeParser {
    static func defaultRoot() -> String { "~/.claude/projects".expandingTilde }

    /// Claude Code escapes the cwd by replacing every non-alphanumeric character with "-".
    static func escape(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Log files that belong to any of the given project paths.
    static func discover(root: String, projectPaths: [String]) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let escaped = projectPaths.map(escape)
        var result: [URL] = []
        for dir in dirs where escaped.contains(where: { dir == $0 || dir.hasPrefix($0 + "-") }) {
            let dirPath = (root as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                result.append(URL(fileURLWithPath: (dirPath as NSString).appendingPathComponent(f)))
            }
        }
        return result
    }

    /// Number of session files per project path (for onboarding).
    static func countSessions(root: String, projectPath: String) -> Int {
        discover(root: root, projectPaths: [projectPath]).count
    }

    static func parse(_ url: URL) -> [AgentSession] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let sessionId = url.deletingPathExtension().lastPathComponent
        let builder = SessionBuilder(agent: .claude, logPath: url.path, resumeId: sessionId, cwd: "")

        var pendingTools: [String: (name: String, command: String)] = [:]
        var seenMessageIds = Set<String>()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let ptr = base + offset
                let remaining = total - offset
                let nl = memchr(ptr, 0x0A, remaining)
                let len = nl.map { UnsafeRawPointer($0) - ptr } ?? remaining
                offset += len + 1
                guard len > 0, shouldParse(ptr, len, pending: pendingTools) else { continue }
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr), count: len, deallocator: .none)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                handle(obj, builder: builder, pending: &pendingTools, seen: &seenMessageIds)
            }
        }
        return builder.finish()
    }

    /// Cheap byte search so that large irrelevant lines (attachments, tool output) skip JSON parsing.
    private static func shouldParse(_ ptr: UnsafeRawPointer, _ len: Int, pending: [String: (name: String, command: String)]) -> Bool {
        func has(_ needle: String) -> Bool {
            needle.utf8CString.withUnsafeBufferPointer { n in
                memmem(ptr, len, n.baseAddress!, n.count - 1) != nil
            }
        }
        if has("\"isSidechain\":true") { return false }
        if has("\"type\":\"ai-title\"") || has("\"type\":\"summary\"") { return true }
        if has("\"type\":\"assistant\"") { return true }
        guard has("\"type\":\"user\"") else { return false }
        if has("\"tool_result\"") {
            // Only Bash results matter (test output); other tool results are skipped.
            return pending.keys.contains { has($0) }
        }
        return true
    }

    private static func handle(_ obj: [String: Any], builder: SessionBuilder,
                               pending: inout [String: (name: String, command: String)],
                               seen: inout Set<String>) {
        let type = obj["type"] as? String ?? ""
        if type == "ai-title", let t = obj["aiTitle"] as? String { builder.setTitle(t); return }
        if type == "summary", let t = obj["summary"] as? String { builder.setTitle(t); return }
        guard type == "user" || type == "assistant" else { return }
        if obj["isSidechain"] as? Bool == true { return }
        guard let ts = obj["timestamp"] as? String, let time = DateFormat.parseISO(ts) else { return }
        let cwd = obj["cwd"] as? String
        if builder.defaultCwd.isEmpty, let cwd { builder.defaultCwd = cwd }
        guard let message = obj["message"] as? [String: Any] else { return }

        if type == "user" {
            builder.touch(time, cwd: cwd)
            if obj["isMeta"] as? Bool == true { return }
            if let text = message["content"] as? String {
                builder.prompt(time, text)
                return
            }
            guard let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { builder.prompt(time, t) }
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let tool = pending.removeValue(forKey: id) else { continue }
                    let isError = block["is_error"] as? Bool ?? false
                    if tool.name == "Bash" {
                        builder.commandResult(time, command: tool.command, output: resultText(block["content"]), isError: isError)
                    }
                default: break
                }
            }
            return
        }

        // assistant
        builder.touch(time, cwd: cwd)
        if let model = message["model"] as? String { builder.setModel(model) }
        if let id = message["id"] as? String, !seen.contains(id), let usage = message["usage"] as? [String: Any] {
            seen.insert(id)
            let tokens = ["input_tokens", "cache_creation_input_tokens", "output_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            builder.addTokens(tokens)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { builder.assistantText(time, t) }
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let id = block["id"] as? String ?? UUID().uuidString
                handleTool(name: name, input: input, id: id, time: time, builder: builder, pending: &pending)
            default: break
            }
        }
    }

    private static func handleTool(name: String, input: [String: Any], id: String, time: Date,
                                   builder: SessionBuilder, pending: inout [String: (name: String, command: String)]) {
        let file = input["file_path"] as? String ?? input["notebook_path"] as? String
        switch name {
        case "Edit":
            guard let file else { return }
            builder.edit(time, file: file, old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
        case "MultiEdit":
            guard let file, let edits = input["edits"] as? [[String: Any]] else { return }
            for e in edits {
                builder.edit(time, file: file, old: e["old_string"] as? String ?? "", new: e["new_string"] as? String ?? "")
            }
        case "Write":
            guard let file else { return }
            builder.patch(time, file: file, added: (input["content"] as? String ?? "").components(separatedBy: "\n").count, removed: 0)
        case "NotebookEdit":
            guard let file else { return }
            builder.patch(time, file: file, added: (input["new_source"] as? String ?? "").components(separatedBy: "\n").count, removed: 0)
        case "Read":
            if let file { builder.read(time, file: file) }
        case "Bash":
            let command = input["command"] as? String ?? ""
            builder.command(time, command)
            pending[id] = (name, command)
        default:
            break
        }
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Readable transcript (user prompts and assistant replies) for the "Транскрипт" sheet.
    static func transcript(_ path: String, from: Date, to: Date) -> [TranscriptEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var entries: [TranscriptEntry] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                  let ts = obj["timestamp"] as? String, let time = DateFormat.parseISO(ts),
                  time >= from.addingTimeInterval(-1), time <= to.addingTimeInterval(1),
                  let message = obj["message"] as? [String: Any] else { continue }
            if let s = message["content"] as? String {
                let clean = SessionBuilder.cleanPrompt(s)
                if !clean.isEmpty { entries.append(TranscriptEntry(time: time, role: type, text: clean)) }
            } else if let blocks = message["content"] as? [[String: Any]] {
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String {
                        let clean = type == "user" ? SessionBuilder.cleanPrompt(t) : t
                        if !clean.isEmpty { entries.append(TranscriptEntry(time: time, role: type, text: clean)) }
                    } else if b["type"] as? String == "tool_use", let name = b["name"] as? String {
                        let input = b["input"] as? [String: Any] ?? [:]
                        let arg = (input["command"] as? String) ?? (input["file_path"] as? String) ?? ""
                        entries.append(TranscriptEntry(time: time, role: "tool", text: "\(name) \(arg)"))
                    }
                }
            }
        }
        return entries
    }
}

struct TranscriptEntry: Identifiable, Hashable {
    let id = UUID()
    var time: Date
    /// user | assistant | tool
    var role: String
    var text: String
}
