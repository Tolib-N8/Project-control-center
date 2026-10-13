import Foundation

// MARK: - Configuration

/// What keeps the project running on the server; decides how Orbit reads its state and its log.
enum ServerRuntime: String, Codable, CaseIterable, Identifiable {
    case compose, systemd, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compose: "Docker Compose"
        case .systemd: tr("Служба systemd", "systemd service")
        case .none: tr("Другое", "Other")
        }
    }
}

enum StepPlace: String, Codable, Hashable {
    case mac, server

    var title: String { self == .mac ? "Mac" : tr("Сервер", "Server") }
}

/// One editable step of a deploy: the built-in code update, or a command of the user's own.
struct DeployStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case code, command }

    var id = UUID()
    var kind: Kind = .command
    var name: String
    var command = ""
    var place: StepPlace = .server
    var enabled = true

    init(id: UUID = UUID(), kind: Kind = .command, name: String, command: String = "", place: StepPlace = .server, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.command = command
        self.place = place
        self.enabled = enabled
    }

    /// Every key is optional so steps written by other versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .command
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        place = try c.decodeIfPresent(StepPlace.self, forKey: .place) ?? .server
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    static func code() -> DeployStep {
        DeployStep(kind: .code, name: tr("Код", "Code"))
    }
}

/// A production server of a project. Persisted inside the project in ~/.orbit/config.json.
struct ServerConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// `user@1.2.3.4`, or a host alias from ~/.ssh/config.
    var host: String
    var port: Int?
    /// The project folder on the server.
    var directory: String
    /// The site address Orbit opens to see that it answers.
    var url: String?
    /// The branch production runs.
    var branch: String
    var runtime: ServerRuntime
    /// The systemd unit, for `runtime == .systemd`.
    var unit: String?
    var steps: [DeployStep]
    var monitor = true
    var autoDeploy = false

    init(id: UUID = UUID(), name: String, host: String = "", port: Int? = nil, directory: String = "", url: String? = nil,
         branch: String = "main", runtime: ServerRuntime = .compose, unit: String? = nil, steps: [DeployStep] = [],
         monitor: Bool = true, autoDeploy: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.directory = directory
        self.url = url
        self.branch = branch
        self.runtime = runtime
        self.unit = unit
        self.steps = steps
        self.monitor = monitor
        self.autoDeploy = autoDeploy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        runtime = try c.decodeIfPresent(ServerRuntime.self, forKey: .runtime) ?? .none
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        steps = try c.decodeIfPresent([DeployStep].self, forKey: .steps) ?? []
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? true
        autoDeploy = try c.decodeIfPresent(Bool.self, forKey: .autoDeploy) ?? false
    }

    /// The address with a scheme, or nil when there is nothing to check.
    var siteURL: String? { ServerConfig.normalizedURL(url) }

    /// "smena.example.ru" → "https://smena.example.ru"; anything but http(s) is refused.
    static func normalizedURL(_ text: String?) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if !s.contains("://") { s = (s.hasPrefix("localhost") || s.first?.isNumber == true ? "http://" : "https://") + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host?.isEmpty == false else { return nil }
        return s
    }

    /// What is missing before the server can be saved and checked.
    var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return tr("Укажите адрес сервера", "Enter the server address") }
        if h.hasPrefix("-") || h.contains(where: { $0.isWhitespace }) { return tr("В адресе не должно быть пробелов", "The address can’t contain spaces") }
        if !directory.trimmingCharacters(in: .whitespaces).hasPrefix("/") { return tr("Папка на сервере — полный путь, например /opt/app", "The server folder is a full path, e.g. /opt/app") }
        if branch.trimmingCharacters(in: .whitespaces).isEmpty || branch.hasPrefix("-") { return tr("Укажите боевую ветку", "Enter the production branch") }
        if runtime == .systemd, (unit ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return tr("Укажите имя службы", "Enter the service name") }
        if let url, !url.trimmingCharacters(in: .whitespaces).isEmpty, siteURL == nil { return tr("Адрес сайта не похож на ссылку", "The site address doesn’t look like a link") }
        return nil
    }
}

// MARK: - State

struct SiteCheck: Codable, Hashable {
    /// HTTP status; nil when there was no answer at all.
    var code: Int?
    var ms: Int?
    var error: String?

    /// Any answer below 500 means the server is alive (a login page answering 401 is still up).
    var up: Bool { code.map { $0 >= 100 && $0 < 500 } ?? false }
}

struct ServiceState: Codable, Hashable, Identifiable {
    var name: String
    /// running, exited, restarting, paused, dead, created — or active, failed, inactive for systemd.
    var state: String
    /// healthy / unhealthy / starting, when the container has a health check.
    var health: String?
    var restarts: Int?

    var id: String { name }

    var ok: Bool { ["running", "active"].contains(state) && health != "unhealthy" }
    var restarting: Bool { state == "restarting" || state == "activating" }
}

/// Why SSH didn't work, in terms the user can act on.
enum SSHProblem: String, Codable, Hashable {
    case auth, hostKey, unknownHost, refused, timeout, noDirectory, other

    var title: String {
        switch self {
        case .auth: tr("Нужен вход по ключу", "Key login needed")
        case .hostKey: tr("Ключ сервера изменился", "The server’s key changed")
        case .unknownHost: tr("Адрес не найден", "Address not found")
        case .refused: tr("Сервер не принимает SSH", "The server refuses SSH")
        case .timeout: tr("Сервер не отвечает по SSH", "No SSH answer from the server")
        case .noDirectory: tr("Папки на сервере нет", "No such folder on the server")
        case .other: tr("SSH не сработал", "SSH failed")
        }
    }

    var hint: String {
        switch self {
        case .auth: tr("Сервер не пустил без пароля или парольной фразы ключа. Положите на него ключ Orbit — кнопка рядом.", "The server wouldn’t let Orbit in without a password or a key passphrase. Install Orbit’s key — the button is right here.")
        case .hostKey: tr("Сервер переустановили или адрес теперь у другой машины. Убедитесь, что это ваш сервер, и удалите старую запись командой ниже.", "The server was reinstalled or the address now belongs to another machine. Make sure it is your server, then remove the old entry with the command below.")
        case .unknownHost: tr("Проверьте адрес: имя не находится в сети.", "Check the address: the name doesn’t resolve.")
        case .refused: tr("На этом адресе и порту SSH не слушает. Проверьте порт.", "Nothing listens for SSH at this address and port. Check the port.")
        case .timeout: tr("Сервер выключен, закрыт файрволом или адрес неверный.", "The server is off, firewalled, or the address is wrong.")
        case .noDirectory: tr("Проверьте путь к папке проекта на сервере.", "Check the path of the project folder on the server.")
        case .other: tr("Подробности — в сообщении ниже.", "Details are in the message below.")
        }
    }

    /// The server itself can't be reached, as opposed to "reached but not let in".
    var unreachable: Bool { [.unknownHost, .refused, .timeout].contains(self) }
}

/// What one SSH visit read from the server.
struct HostFacts: Codable, Hashable {
    var load1: Double?
    var cores: Int?
    var memTotalMB: Int?
    var memAvailableMB: Int?
    var diskTotalKB: Int?
    var diskUsedKB: Int?
    var commit: String?
    var commitSubject: String?
    var commitDate: Date?
    var branch: String?
    /// Tracked files changed on the server by hand.
    var dirty = 0
    var directoryMissing = false
    var services: [ServiceState] = []
    /// Why containers or the service couldn't be read (no docker, no permission).
    var runtimeError: String?

    var cpuFraction: Double? {
        guard let load1, let cores, cores > 0 else { return nil }
        return min(1, load1 / Double(cores))
    }

    var memFraction: Double? {
        guard let memTotalMB, let memAvailableMB, memTotalMB > 0 else { return nil }
        return max(0, min(1, Double(memTotalMB - memAvailableMB) / Double(memTotalMB)))
    }

    var diskFraction: Double? {
        guard let diskTotalKB, let diskUsedKB, diskTotalKB > 0 else { return nil }
        return max(0, min(1, Double(diskUsedKB) / Double(diskTotalKB)))
    }

    var shortCommit: String? { commit.map { String($0.prefix(7)) } }
    var failingServices: [ServiceState] { services.filter { !$0.ok } }
}

struct ServerStatus: Codable, Hashable {
    var site: SiteCheck?
    var siteCheckedAt: Date?
    /// Failed site checks in a row; a signal is raised from the second.
    var siteFailures = 0
    var host: HostFacts?
    var hostCheckedAt: Date?
    var sshProblem: SSHProblem?
    var sshMessage: String?
    var sshFailures = 0
    /// Tip of the production branch on origin.
    var remoteCommit: String?
    /// Commits on origin's branch that the server doesn't have; nil when unknown.
    var behind: Int?

    enum Overall { case unknown, up, degraded, down, noAccess }

    /// One word for the dot and the title of a server card.
    func overall(_ server: ServerConfig) -> Overall {
        let hasSite = server.siteURL != nil
        if hasSite, let site, !site.up, siteFailures >= 2 { return .down }
        if let p = sshProblem {
            if p.unreachable, sshFailures >= 2, !(hasSite && site?.up == true) { return .down }
            return hasSite && site?.up == true ? .degraded : (hostCheckedAt == nil && siteCheckedAt == nil ? .unknown : .noAccess)
        }
        if let host {
            if host.directoryMissing || !host.failingServices.isEmpty { return .degraded }
            if hasSite, let site, !site.up { return .degraded }
            return .up
        }
        if hasSite, let site { return site.up ? .up : .degraded }
        return .unknown
    }
}

/// A server with everything known about it, as the signal rules see it.
struct ServerSnapshot: Hashable {
    var config: ServerConfig
    var status: ServerStatus?
    var lastRun: DeployRun?
}

/// One availability sample; kept for a week.
struct ServerSample: Codable, Hashable {
    var t: Date
    var up: Bool
    var ms: Int?
}

enum Uptime {
    /// Fewer checks than this say nothing about availability yet.
    static let enoughSamples = 20

    /// Share of successful checks since `from`; nil until there are enough of them to mean something.
    static func share(_ samples: [ServerSample], from: Date) -> Double? {
        let recent = samples.filter { $0.t >= from }
        guard recent.count >= enoughSamples else { return nil }
        return Double(recent.filter(\.up).count) / Double(recent.count)
    }

    /// `count` equal slices of the last `hours`: true = all checks passed, false = at least one failed, nil = no checks.
    static func strip(_ samples: [ServerSample], hours: Double = 24, count: Int = 48, now: Date) -> [Bool?] {
        let span = hours * 3600, slice = span / Double(count)
        let start = now.addingTimeInterval(-span)
        var result = [Bool?](repeating: nil, count: count)
        for s in samples where s.t >= start && s.t <= now {
            let i = min(count - 1, Int(s.t.timeIntervalSince(start) / slice))
            result[i] = (result[i] ?? true) && s.up
        }
        return result
    }

    /// "99,8 %" — never rounds a real outage up to a clean 100.
    static func text(_ share: Double) -> String {
        if share >= 1 { return "100 %" }
        let v = min(99.9, (share * 1000).rounded(.down) / 10)
        let s = String(format: "%.1f", v)
        return (L10n.current == .ru ? s.replacingOccurrences(of: ".", with: ",") : s) + " %"
    }

    static func averageMs(_ samples: [ServerSample], from: Date) -> Int? {
        let values = samples.filter { $0.t >= from && $0.up }.compactMap(\.ms)
        return values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
}

/// ~/.orbit/servers.json
struct ServerStore: Codable {
    var status: [String: ServerStatus] = [:]
    var samples: [String: [ServerSample]] = [:]
}

// MARK: - Deploys

enum StepState: String, Codable, Hashable {
    case pending, running, success, failed, skipped, cancelled
}

struct StepRun: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var place: StepPlace
    var state: StepState = .pending
    var startedAt: Date?
    var seconds: Double?
    /// The reason in one line, shown under a failed step.
    var note: String?
}

enum DeployTrigger: String, Codable, Hashable {
    case manual, auto, rollback

    var title: String {
        switch self {
        case .manual: tr("вручную", "manual")
        case .auto: tr("автоматически", "automatic")
        case .rollback: tr("откат", "rollback")
        }
    }
}

enum DeployState: String, Codable, Hashable {
    case running, success, failed, cancelled
}

struct DeployRun: Codable, Hashable, Identifiable {
    var id = UUID()
    var projectId: String
    var serverId: UUID
    var trigger: DeployTrigger
    var startedAt: Date
    var finishedAt: Date?
    /// What the server ran before the deploy.
    var fromCommit: String?
    var toCommit: String?
    var toSubject: String?
    var steps: [StepRun]
    var state: DeployState = .running

    var seconds: Double? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
    var failedStep: StepRun? { steps.first { $0.state == .failed } }
    var shortTo: String? { toCommit.map { String($0.prefix(7)) } }
}

/// "1 мин 48 с", "12 с"
enum Elapsed {
    static func text(_ seconds: Double) -> String {
        let sec = tr("с", "s"), min = tr("мин", "min")
        if seconds < 0.95 { return "<1 \(sec)" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) \(sec)" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) \(min)" : "\(s / 60) \(min) \(s % 60) \(sec)" }
        return Duration.text(minutes: s / 60)
    }
}

// MARK: - Templates and checks

/// The steps Orbit suggests for a project, from the files in its repository.
enum DeployTemplate {
    static func detect(projectPath: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                       read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> (runtime: ServerRuntime, steps: [DeployStep]) {
        func has(_ name: String) -> Bool { fileExists((projectPath as NSString).appendingPathComponent(name)) }
        var steps: [DeployStep] = []

        if has("package.json"), let data = read((projectPath as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any], let test = scripts["test"] as? String, !test.contains("no test specified") {
            steps.append(DeployStep(name: tr("Тесты", "Tests"), command: (has("package-lock.json") ? "npm ci" : "npm install") + " && npm test", place: .mac))
        }

        let compose = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains(where: has)
        if has("deploy/update.sh") && !compose {
            // The script pulls the code itself, so the built-in code step stays off.
            var code = DeployStep.code()
            code.enabled = false
            steps.append(code)
            steps.append(DeployStep(name: tr("Обновление", "Update"), command: "sudo bash deploy/update.sh"))
            return (.systemd, steps)
        }
        steps.append(.code())
        if compose {
            steps.append(DeployStep(name: tr("Сборка", "Build"), command: "docker compose build"))
            steps.append(DeployStep(name: tr("Запуск", "Start"), command: "docker compose up -d"))
            return (.compose, steps)
        }
        steps.append(DeployStep(name: tr("Сборка и запуск", "Build and start"), command: "", enabled: false))
        return (.none, steps)
    }
}

/// Commands that destroy data when run on a production server.
enum DeployLint {
    static func warning(_ command: String) -> String? {
        let c = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ; ") + " "
        func matches(_ pattern: String) -> Bool { c.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"\bdown\b[^;&|]*\s(-v|--volumes)\b"#) {
            return tr("«down -v» удалит тома Docker вместе с базой данных.", "“down -v” deletes the Docker volumes, the database included.")
        }
        if matches(#"\b(volume|system)\s+prune\b"#) || matches(#"\bprune\b[^;&|]*--volumes\b"#) {
            return tr("prune удалит тома Docker, которые сейчас не подключены.", "prune deletes Docker volumes that aren’t attached right now.")
        }
        if matches(#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r)[a-z]*\s+(/|~|\$home|/\*)(\s|;|$)"#) {
            return tr("Эта команда удалит всё на сервере.", "This command deletes everything on the server.")
        }
        if matches(#"\bgit\s+reset\s+--hard\b"#) || matches(#"\bgit\s+clean\b[^;&|]*-[a-z]*f"#) {
            return tr("Команда сотрёт правки, сделанные на сервере руками.", "The command wipes edits made by hand on the server.")
        }
        if matches(#"\bdrop\s+(database|table)\b"#) {
            return tr("Команда удаляет данные из базы.", "The command deletes data from the database.")
        }
        return nil
    }
}

/// Whether Orbit should start a deploy on its own.
enum AutoDeploy {
    /// One attempt per commit: a commit that was already tried (and failed, or was stopped) is never retried automatically.
    static func decide(server: ServerConfig, status: ServerStatus?, remoteTip: String?, runs: [DeployRun], deploying: Bool, online: Bool) -> Bool {
        guard server.autoDeploy, online, !deploying, let tip = remoteTip, !tip.isEmpty else { return false }
        guard let status, status.sshProblem == nil, let current = status.host?.commit, !current.isEmpty else { return false }
        guard current != tip else { return false }
        return !runs.contains { $0.serverId == server.id && $0.toCommit == tip }
    }
}
