import Foundation

/// Parses Codex rollouts: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
enum CodexParser {
    static func defaultRoot() -> String { "~/.codex/sessions".expandingTilde }

    /// All rollout files with their cwd (read from the session_meta header).
    static func discover(root: String) -> [(url: URL, cwd: String)] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return [] }
        var result: [(URL, String)] = []
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(rel))
            if let cwd = headerCwd(url) { result.append((url, cwd)) }
        }
        return result
    }

    private static let cwdRegex = try! NSRegularExpression(pattern: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    static func headerCwd(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 96 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let m = cwdRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).replacingOccurrences(of: "\\/", with: "/")
    }

    /// thread id → thread name from ~/.codex/session_index.jsonl
    static func threadNames() -> [String: String] {
        let path = "~/.codex/session_index.jsonl".expandingTilde
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let name = obj["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }

    static func parse(_ url: URL, names: [String: String]) -> [AgentSession] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let builder = SessionBuilder(agent: .codex, logPath: url.path, resumeId: nil, cwd: "")
        var pending: [String: String] = [:] // call_id → shell command

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["timestamp"] as? String, let time = DateFormat.parseISO(ts) else { continue }
            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                let id = payload["id"] as? String ?? payload["session_id"] as? String
                builder.resumeId = id
                if let cwd = payload["cwd"] as? String { builder.defaultCwd = cwd }
                if let id, let name = names[id] { builder.setTitle(name) }
            case "turn_context":
                builder.touch(time, cwd: payload["cwd"] as? String)
                if let model = payload["model"] as? String { builder.setModel(model) }
            case "world_state":
                if let state = payload["state"] as? [String: Any],
                   let mode = state["collaboration_mode"] as? [String: Any],
                   let model = mode["model"] as? String { builder.setModel(model) }
            case "event_msg":
                switch payload["type"] as? String {
                case "token_count":
                    if let info = payload["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        let input = (total["input_tokens"] as? Int ?? 0) - (total["cached_input_tokens"] as? Int ?? 0)
                        builder.setTokens(input + (total["output_tokens"] as? Int ?? 0))
                    }
                case "task_complete":
                    if let msg = payload["last_agent_message"] as? String { builder.assistantText(time, msg) }
                default: break
                }
            case "response_item":
                handleItem(payload, time: time, builder: builder, pending: &pending)
            default:
                break
            }
        }
        if let id = builder.resumeId, let name = names[id] { builder.setTitle(name) }
        return builder.finish()
    }

    private static func handleItem(_ p: [String: Any], time: Date, builder: SessionBuilder, pending: inout [String: String]) {
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String
            let texts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if role == "user" { texts.forEach { builder.prompt(time, $0) } }
            if role == "assistant" { texts.forEach { builder.assistantText(time, $0) } }
        case "custom_tool_call", "function_call":
            let name = p["name"] as? String ?? ""
            let input = (p["input"] as? String) ?? (p["arguments"] as? String) ?? ""
            let callId = p["call_id"] as? String ?? UUID().uuidString
            builder.touch(time)
            if input.contains("*** Begin Patch") {
                applyPatch(input, time: time, builder: builder)
            }
            for cmd in commands(name: name, input: input) where !cmd.contains("*** Begin Patch") {
                builder.command(time, cmd)
                pending[callId] = cmd
            }
        case "custom_tool_call_output", "function_call_output":
            guard let callId = p["call_id"] as? String, let cmd = pending.removeValue(forKey: callId) else { return }
            let output: String
            if let s = p["output"] as? String { output = s }
            else { output = (p["output"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
            let exit = output.range(of: #"(?:Exit code|exit_code|Process exited with code):?\s*(\d+)"#, options: .regularExpression)
            let isError = exit.map { !output[$0].hasSuffix(" 0") && !output[$0].hasSuffix(":0") } ?? false
            builder.commandResult(time, command: cmd, output: output, isError: isError)
        default:
            break
        }
    }

    private static let cmdRegex = try! NSRegularExpression(pattern: #"\bcmd\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// Shell commands from an exec / shell tool call.
    static func commands(name: String, input: String) -> [String] {
        if let data = input.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let cmd = obj["cmd"] as? String { return [cmd] }
            if let arr = obj["command"] as? [String] { return [arr.last ?? arr.joined(separator: " ")] }
            if let cmd = obj["command"] as? String { return [cmd] }
        }
        let matches = cmdRegex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        return matches.compactMap { m in
            Range(m.range(at: 1), in: input).map {
                String(input[$0]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
    }

    static func applyPatch(_ patch: String, time: Date, builder: SessionBuilder) {
        var file: String?
        var added = 0, removed = 0
        func flush() {
            if let file { builder.patch(time, file: file, added: added, removed: removed) }
            added = 0; removed = 0
        }
        let normalized = patch.replacingOccurrences(of: "\\n", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let r = line.range(of: #"\*\*\* (Update|Add|Delete) File: "#, options: .regularExpression) {
                flush()
                file = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("*** ") {
                continue
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        flush()
    }
}
