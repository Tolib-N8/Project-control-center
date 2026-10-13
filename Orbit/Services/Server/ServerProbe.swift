import Foundation

/// Reads a server's state: one SSH visit for the machine and the project, one HTTP request for the site.
/// Nothing here changes anything on the server.
enum ServerProbe {
    // MARK: - Site

    /// Opens the address with curl: works for http and https alike and follows redirects.
    static func site(_ url: String, timeout: Int = 10) -> SiteCheck {
        let r = Shell.run("/usr/bin/curl", ["-sS", "-o", "/dev/null", "-L", "--max-redirs", "5", "--connect-timeout", "6",
                                            "--max-time", "\(timeout)", "-w", "%{http_code} %{time_total}", "--", url],
                          timeout: TimeInterval(timeout + 5))
        return parseSite(stdout: r.stdout, stderr: r.stderr, status: r.status)
    }

    static func parseSite(stdout: String, stderr: String, status: Int32) -> SiteCheck {
        let parts = stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let code = parts.first.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let ms = parts.count > 1 ? Double(parts[1].replacingOccurrences(of: ",", with: ".")).map { Int(($0 * 1000).rounded()) } : nil
        if status == 0, let code { return SiteCheck(code: code, ms: ms, error: nil) }
        return SiteCheck(code: code, ms: nil, error: siteError(status, stderr))
    }

    private static func siteError(_ status: Int32, _ stderr: String) -> String {
        switch status {
        case 6: tr("адрес не найден", "address not found")
        case 7: tr("соединение отклонено", "connection refused")
        case 28: tr("нет ответа", "no answer")
        case 35, 51, 58, 60: tr("ошибка сертификата", "certificate error")
        case 47: tr("слишком много переадресаций", "too many redirects")
        default:
            stderr.split(separator: "\n").last.map { String($0).replacingOccurrences(of: #"^curl: \(\d+\) "#, with: "", options: .regularExpression) }
                ?? tr("нет ответа", "no answer")
        }
    }

    // MARK: - Host

    /// A read-only script; every section starts with an `@@name` line so the answer can be cut apart.
    static func script(_ server: ServerConfig) -> String {
        let dir = Shell.quote(server.directory)
        var lines = [
            "D=\(dir)",
            "echo '@@load'; cat /proc/loadavg 2>/dev/null",
            "echo '@@cores'; (nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)",
            "echo '@@mem'; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null",
            "echo '@@disk'; df -Pk \"$D\" 2>/dev/null | tail -n 1",
            "echo '@@git'",
            "if [ -d \"$D\" ]; then cd \"$D\" || exit 0",
            "  git rev-parse HEAD 2>/dev/null || echo '-'",
            "  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-'",
            "  git log -1 --format='%ct%x09%s' 2>/dev/null || echo '-'",
            "  echo \"dirty $(git status --porcelain --untracked-files=no 2>/dev/null | wc -l)\"",
            "else echo 'nodir'; echo '@@end'; exit 0; fi",
            "echo '@@services'",
        ]
        switch server.runtime {
        case .compose:
            lines.append("docker compose ps -a --format json 2>&1 || echo \"@@error $?\"")
        case .systemd:
            let unit = Shell.quote((server.unit ?? "").trimmingCharacters(in: .whitespaces))
            lines.append("systemctl show \(unit) --no-pager -p Id,LoadState,ActiveState,SubState,NRestarts 2>&1 || echo \"@@error $?\"")
        case .none:
            break
        }
        lines.append("echo '@@end'")
        return lines.joined(separator: "\n")
    }

    static func host(_ server: ServerConfig, timeout: TimeInterval = 30) -> (facts: HostFacts?, problem: SSHProblem?, message: String?) {
        let r = SSH.run(server, script: script(server), timeout: timeout)
        if let p = SSH.problem(r) { return (nil, p.kind, p.kind == .hostKey ? SSH.forgetHostCommand(server) : p.message) }
        guard r.stdout.contains("@@end") else {
            let text = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, .other, text.split(separator: "\n").last.map(String.init) ?? tr("сервер ответил непонятно", "unexpected answer from the server"))
        }
        let facts = parse(r.stdout, runtime: server.runtime)
        if facts.directoryMissing { return (facts, .noDirectory, server.directory) }
        return (facts, nil, nil)
    }

    static func parse(_ text: String, runtime: ServerRuntime) -> HostFacts {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@"), !line.hasPrefix("@@error") {
                current = String(line.dropFirst(2))
                sections[current] = []
            } else {
                sections[current, default: []].append(line)
            }
        }
        var f = HostFacts()

        if let load = sections["load"]?.first?.split(separator: " ").first { f.load1 = Double(load) }
        if let cores = sections["cores"]?.first { f.cores = Int(cores) }
        for line in sections["mem"] ?? [] {
            let kb = line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            if line.hasPrefix("MemTotal") { f.memTotalMB = kb.map { $0 / 1024 } }
            if line.hasPrefix("MemAvailable") { f.memAvailableMB = kb.map { $0 / 1024 } }
        }
        // Filesystem 1024-blocks Used Available Capacity Mounted
        if let disk = sections["disk"]?.last?.split(separator: " "), disk.count >= 4, let total = Int(disk[1]), let used = Int(disk[2]) {
            f.diskTotalKB = total
            f.diskUsedKB = used
        }

        let git = sections["git"] ?? []
        if git.first == "nodir" {
            f.directoryMissing = true
            return f
        }
        // What the server says is later handed to the local git: nothing but a commit hash gets through.
        if git.count >= 1, git[0].range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil { f.commit = git[0] }
        if git.count >= 2, git[1] != "-" { f.branch = git[1] == "HEAD" ? nil : git[1] }
        if git.count >= 3, git[2] != "-" {
            let parts = git[2].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if let ts = parts.first.flatMap({ Double($0) }) { f.commitDate = Date(timeIntervalSince1970: ts) }
            if parts.count > 1 { f.commitSubject = String(parts[1]) }
        }
        if let dirty = git.first(where: { $0.hasPrefix("dirty") })?.split(separator: " ").last { f.dirty = Int(dirty) ?? 0 }

        let services = sections["services"] ?? []
        switch runtime {
        case .compose: (f.services, f.runtimeError) = parseCompose(services)
        case .systemd: (f.services, f.runtimeError) = parseSystemd(services)
        case .none: break
        }
        return f
    }

    /// `docker compose ps --format json`: one object per line in current versions, a single array in older ones.
    static func parseCompose(_ lines: [String]) -> ([ServiceState], String?) {
        var objects: [[String: Any]] = []
        var other: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
                if !line.hasPrefix("@@error") { other.append(line) }
                continue
            }
            if let one = json as? [String: Any] { objects.append(one) }
            if let many = json as? [[String: Any]] { objects += many }
        }
        let failed = lines.contains { $0.hasPrefix("@@error") }
        if objects.isEmpty {
            if failed { return ([], composeError(other)) }
            return ([], other.isEmpty ? tr("контейнеров нет", "no containers") : composeError(other))
        }
        let states = objects.map { o -> ServiceState in
            let health = (o["Health"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            return ServiceState(name: (o["Service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? o["Name"] as? String ?? "?",
                                state: (o["State"] as? String ?? "unknown").lowercased(), health: health, restarts: nil)
        }
        return (states.sorted { $0.name < $1.name }, nil)
    }

    private static func composeError(_ lines: [String]) -> String {
        let text = lines.joined(separator: " ").lowercased()
        if text.contains("permission denied") { return tr("нет прав на Docker у этого пользователя", "this user has no access to Docker") }
        if text.contains("no configuration file") { return tr("в папке нет docker-compose.yml", "no docker-compose.yml in the folder") }
        if text.contains("not found") || text.contains("is not a docker command") { return tr("Docker Compose не установлен", "Docker Compose isn’t installed") }
        if text.contains("cannot connect to the docker daemon") { return tr("Docker не запущен", "Docker isn’t running") }
        return lines.last ?? tr("Docker не ответил", "Docker didn’t answer")
    }

    /// `systemctl show -p Id,LoadState,ActiveState,SubState,NRestarts`
    static func parseSystemd(_ lines: [String]) -> ([ServiceState], String?) {
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let active = values["ActiveState"] else {
            return ([], lines.first { !$0.hasPrefix("@@error") } ?? tr("systemctl не ответил", "systemctl didn’t answer"))
        }
        if values["LoadState"] == "not-found" { return ([], tr("такой службы нет", "no such service")) }
        let name = (values["Id"] ?? "service").replacingOccurrences(of: ".service", with: "")
        return ([ServiceState(name: name, state: active, health: nil, restarts: values["NRestarts"].flatMap { Int($0) })], nil)
    }

    // MARK: - Log

    static func logScript(_ server: ServerConfig, lines: Int = 300) -> String? {
        switch server.runtime {
        case .compose: "cd \(Shell.quote(server.directory)) && docker compose logs --no-color --tail \(lines) 2>&1"
        case .systemd: "journalctl -u \(Shell.quote((server.unit ?? "").trimmingCharacters(in: .whitespaces))) -n \(lines) --no-pager -o short-iso 2>&1"
        case .none: nil
        }
    }

    static func log(_ server: ServerConfig, lines: Int = 300) -> (text: String, error: String?) {
        guard let script = logScript(server, lines: lines) else { return ("", nil) }
        let r = SSH.run(server, script: script, timeout: 40)
        if let p = SSH.problem(r) { return ("", "\(p.kind.title): \(p.message)") }
        return (LogText.clean(r.stdout), nil)
    }
}

/// Server and step output as shown on screen.
enum LogText {
    /// Drops terminal colour codes and keeps only what a line ended up showing after carriage returns.
    static func clean(_ text: String) -> String {
        // "\r\n" is one Character in Swift, so it has to go before the text is cut into lines.
        let noEscapes = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        return noEscapes.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            return trimmed.split(separator: "\r", omittingEmptySubsequences: true).last ?? ""
        }.joined(separator: "\n")
    }

    static func isError(_ line: String) -> Bool {
        line.range(of: #"error|exception|traceback|fatal|panic|\bcritical\b|\bfailed\b|refused|denied|unhandled"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The end of a file, at most `bytes` long, starting at a line break.
    static func tail(_ url: URL, bytes: Int = 96_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: from)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        if from > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return clean(text)
    }
}
