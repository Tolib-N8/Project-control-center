import Foundation

/// What a step of a deploy actually does.
enum DeployAction: Hashable {
    /// SSH works, the folder is there; remembers what the server runs now.
    case connect
    /// The user's command on the Mac, in a clean copy of the commit being deployed.
    case local(String)
    /// A script in the project folder on the server.
    case remote(String)
    /// Waits for the site to answer and the services to be up.
    case verify
}

struct PlannedStep: Hashable {
    var run: StepRun
    var action: DeployAction
}

enum StepOutcome: Equatable {
    case success
    case failed(String)
    case cancelled
}

/// Turns a server's settings into the list of steps to run. Pure: nothing is executed here.
enum DeployPipeline {
    static func plan(_ server: ServerConfig, target: String?, previous: String?) -> [PlannedStep] {
        var steps = [PlannedStep(run: StepRun(name: tr("Подключение", "Connect"), place: .server), action: .connect)]
        let env = environment(server, target: target, previous: previous)
        for step in server.steps where step.enabled {
            switch step.kind {
            case .code:
                steps.append(PlannedStep(run: StepRun(name: step.name.isEmpty ? tr("Код", "Code") : step.name, place: .server),
                                         action: .remote(remoteScript(server, body: codeScript(server, target: target), env: env))))
            case .backup:
                steps.append(backupStep(server, step, env: env))
            case .command:
                let command = step.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { continue }
                let run = StepRun(name: step.name.isEmpty ? command : step.name, place: step.place)
                steps.append(PlannedStep(run: run, action: step.place == .mac ? .local(command) : .remote(remoteScript(server, body: command, env: env))))
            }
        }
        steps.append(PlannedStep(run: StepRun(name: tr("Проверка", "Check"), place: .server), action: .verify))
        return steps
    }

    private static func backupStep(_ server: ServerConfig, _ step: DeployStep, env: [String: String]) -> PlannedStep {
        PlannedStep(run: StepRun(name: step.name.isEmpty ? tr("Резервная копия", "Backup") : step.name, place: .server),
                    action: .remote(remoteScript(server, body: backupScript(command: step.command), env: env)))
    }

    /// Saves what a deploy can't bring back: the settings files and the version always, and whatever `command`
    /// dumps (a database, usually) into `$ORBIT_BACKUP_DIR`. An empty dump fails the step, so the deploy stops
    /// before anything on the server has changed. Old backups beyond `keep` are removed afterwards.
    static func backupScript(command: String, keep: Int = BackupTemplate.keep) -> String {
        let dump = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = Shell.quote(tr("Резервная копия не удалась. Выкладка остановлена, на сервере ничего не изменено.",
                                    "The backup failed. The deploy stopped; nothing on the server was changed."))
        var lines = [
            // A dump piped into gzip must fail the step when the dump itself fails.
            "if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi",
            "umask 077",
            "ORBIT_BACKUP_ROOT=\"${ORBIT_BACKUP_HOME:-$HOME/orbit-backups}/$(basename \"$PWD\")\"",
            "ORBIT_BACKUP_DIR=\"$ORBIT_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nogit)\"",
            "orbit_n=1; orbit_base=\"$ORBIT_BACKUP_DIR\"",
            "while [ -e \"$ORBIT_BACKUP_DIR\" ]; do orbit_n=$((orbit_n + 1)); ORBIT_BACKUP_DIR=\"$orbit_base-$orbit_n\"; done",
            "export ORBIT_BACKUP_DIR",
            "mkdir -p \"$ORBIT_BACKUP_DIR\"",
            "git rev-parse HEAD > \"$ORBIT_BACKUP_DIR/commit.txt\" 2>/dev/null || rm -f \"$ORBIT_BACKUP_DIR/commit.txt\"",
            "for f in .env .env.local .env.production docker-compose.yml docker-compose.yaml docker-compose.override.yml compose.yml compose.yaml; do",
            "  if [ -f \"$f\" ]; then cp -p \"$f\" \"$ORBIT_BACKUP_DIR/\"; fi",
            "done",
        ]
        if dump.isEmpty {
            lines.append("echo \(Shell.quote(tr("Команды для базы данных нет: сохраняю только настройки и версию.", "No database command: saving only the settings and the version.")))")
        } else {
            // In a subshell of its own, so a failure can be cleaned up after: a half-made backup is worse than none.
            lines += ["set +e", "(", "set -e", dump, ")", "orbit_status=$?", "set -e",
                      "if [ \"$orbit_status\" -ne 0 ]; then rm -rf \"$ORBIT_BACKUP_DIR\"; echo \(failed); exit \"$orbit_status\"; fi"]
        }
        lines += [
            // `cp -p` keeps the original's permissions; a copy of .env must not be readable by other users.
            "chmod -R go-rwx \"$ORBIT_BACKUP_DIR\"",
            "empty=$(find \"$ORBIT_BACKUP_DIR\" -type f -size 0 ! -name '.env*' ! -name '*.yml' ! -name '*.yaml' | head -n 3)",
            "if [ -n \"$empty\" ]; then echo \(Shell.quote(tr("Резервная копия пустая:", "The backup is empty:"))) $empty; rm -rf \"$ORBIT_BACKUP_DIR\"; echo \(failed); exit 1; fi",
            "echo \(Shell.quote(tr("Резервная копия сохранена:", "Backup saved:"))) \"$ORBIT_BACKUP_DIR\"",
            "ls -la \"$ORBIT_BACKUP_DIR\" | tail -n +2",
            "(ls -1dt \"$ORBIT_BACKUP_ROOT\"/*/ 2>/dev/null || true) | tail -n +\(keep + 1) | while read -r old; do rm -rf \"$old\"; done",
        ]
        return lines.joined(separator: "\n")
    }

    /// Back to `commit`: the code goes back, then the server-side commands run again. Checks on the Mac are skipped.
    static func rollback(_ server: ServerConfig, to commit: String, previous: String?) -> [PlannedStep] {
        var steps = [PlannedStep(run: StepRun(name: tr("Подключение", "Connect"), place: .server), action: .connect)]
        let env = environment(server, target: commit, previous: previous)
        // Going back changes the server too: the backup, where there is one, comes first.
        if let backup = server.steps.first(where: { $0.enabled && $0.kind == .backup }) { steps.append(backupStep(server, backup, env: env)) }
        let back = "git checkout -q --detach \(Shell.quote(commit))\ngit log -1 --format='%h %s'"
        steps.append(PlannedStep(run: StepRun(name: tr("Код назад", "Code back"), place: .server), action: .remote(remoteScript(server, body: back, env: env))))
        for step in server.steps where step.enabled && step.kind == .command && step.place == .server {
            let command = step.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            steps.append(PlannedStep(run: StepRun(name: step.name.isEmpty ? command : step.name, place: .server),
                                     action: .remote(remoteScript(server, body: command, env: env))))
        }
        steps.append(PlannedStep(run: StepRun(name: tr("Проверка", "Check"), place: .server), action: .verify))
        return steps
    }

    static func environment(_ server: ServerConfig, target: String?, previous: String?) -> [String: String] {
        var env = ["ORBIT_BRANCH": server.branch, "ORBIT_SERVER": server.name]
        if let target { env["ORBIT_COMMIT"] = target }
        if let previous { env["ORBIT_PREVIOUS"] = previous }
        return env
    }

    /// Fast-forwards the server's branch to the commit being deployed; never rewrites or merges.
    static func codeScript(_ server: ServerConfig, target: String?) -> String {
        let branch = Shell.quote(server.branch)
        let remoteRef = Shell.quote("origin/" + server.branch)
        return """
        git fetch --prune origin
        if git show-ref --verify --quiet \(Shell.quote("refs/heads/" + server.branch)); then git checkout -q \(branch); else git checkout -q -b \(branch) --track \(remoteRef); fi
        git merge --ff-only \(target.map(Shell.quote) ?? remoteRef)
        git log -1 --format='%h %s'
        """
    }

    /// Where a running remote step leaves its process id, so "Остановить" can reach it.
    static func pidFile(_ runId: UUID) -> String { "/tmp/orbit-\(runId.uuidString.prefix(8).lowercased()).pid" }

    /// `body` in the project folder; the first failing command stops the step.
    static func remoteScript(_ server: ServerConfig, body: String, env: [String: String], pidFile: String = "\"$ORBIT_PIDFILE\"") -> String {
        var lines = ["set -e", "cd \(Shell.quote(server.directory))"]
        lines.append("if [ -n \"$ORBIT_PIDFILE\" ]; then echo $$ > \(pidFile); trap 'rm -f \(pidFile)' EXIT; fi")
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { lines.append("export \(k)=\(Shell.quote(v))") }
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// Clean copy of the commit for the Mac steps: a clone of its own, the project's working folder isn't touched.
    static func localScript(projectPath: String, workDir: String, branch: String, target: String?, command: String, env: [String: String]) -> String {
        var lines = ["set -e", "P=\(Shell.quote(projectPath))", "W=\(Shell.quote(workDir))",
                     "if [ ! -d \"$W/.git\" ]; then mkdir -p \"$(dirname \"$W\")\"; git clone -q --no-checkout \"$P\" \"$W\"; fi",
                     "cd \"$W\"",
                     "git fetch -q \"$P\" \(Shell.quote("refs/remotes/origin/" + branch))",
                     "git checkout -q -f --detach \(target.map(Shell.quote) ?? "FETCH_HEAD")",
                     "git clean -q -fd",
                     "git log -1 --format='%h %s'"]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { lines.append("export \(k)=\(Shell.quote(v))") }
        lines.append(command)
        return lines.joined(separator: "\n")
    }
}

/// Runs the steps in order. A failed step stops the chain; the rest are marked skipped.
enum DeployEngine {
    static func run(_ steps: [PlannedStep], isCancelled: () -> Bool,
                    execute: (Int, PlannedStep) async -> StepOutcome,
                    update: @MainActor (Int, StepRun) -> Void) async -> DeployState {
        var result: DeployState = .success
        var stopped = false
        for (i, step) in steps.enumerated() {
            var run = step.run
            if stopped {
                run.state = .skipped
                await update(i, run)
                continue
            }
            if isCancelled() {
                run.state = .cancelled
                await update(i, run)
                result = .cancelled
                stopped = true
                continue
            }
            let started = Date()
            run.state = .running
            run.startedAt = started
            await update(i, run)
            let outcome = await execute(i, step)
            run.seconds = Date().timeIntervalSince(started)
            switch outcome {
            case .success:
                run.state = .success
            case .failed(let note):
                run.state = .failed
                run.note = note
                result = .failed
                stopped = true
            case .cancelled:
                run.state = .cancelled
                result = .cancelled
                stopped = true
            }
            await update(i, run)
        }
        return result
    }
}

/// One child process whose output goes to a log file, and which can be stopped from another thread.
final class StepProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Returns the exit status; -1 when the process couldn't start, -3 on timeout.
    func run(_ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:], log: URL, timeout: TimeInterval) -> Int32 {
        guard !cancelled else { return -2 }
        StepLog.create(log)
        guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }

        lock.lock()
        if stopped { lock.unlock(); return -2 }
        process = p
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        do { try p.run() } catch {
            StepLog.append("\(error.localizedDescription)\n", to: log)
            return -1
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Self.terminateTree(p.processIdentifier)
            _ = done.wait(timeout: .now() + 3)
            return -3
        }
        return p.terminationStatus
    }

    func cancel() {
        lock.lock()
        stopped = true
        let pid = process?.processIdentifier
        lock.unlock()
        if let pid { Self.terminateTree(pid) }
    }

    /// The process and everything it started: a shell doesn't pass SIGTERM on to its children.
    static func terminateTree(_ pid: Int32) {
        var all: [Int32] = [], queue = [pid]
        while let next = queue.popLast(), all.count < 500 {
            all.append(next)
            let r = Shell.run("/usr/bin/pgrep", ["-P", "\(next)"], timeout: 5)
            queue += r.stdout.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        }
        for p in all.reversed() { kill(p, SIGTERM) }
    }
}

enum StepLog {
    /// Step output can show what a command printed, tokens included: the files are for this user only.
    static func create(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    static func append(_ text: String, to url: URL) {
        create(url)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Failures Orbit recognises, explained in plain words; nil for everything else.
    static func hint(in text: String) -> String? {
        let t = text.lowercased()
        if let sudo = SSH.sudoHint(text) { return sudo }
        if t.contains("would be overwritten by") {
            return tr("На сервере руками изменены файлы — git не стал их затирать. Сохраните или отмените эти правки на сервере (git stash) и выкатите снова.",
                      "Files were edited by hand on the server — git refused to overwrite them. Stash or discard those edits on the server (git stash) and deploy again.")
        }
        if t.contains("not possible to fast-forward") || t.contains("diverging branches") {
            return tr("История на сервере разошлась с веткой: там есть коммиты, которых нет на GitHub. Разберитесь на сервере, прежде чем выкатывать.",
                      "The server’s history has diverged from the branch: it has commits that GitHub doesn’t. Sort it out on the server before deploying.")
        }
        if t.contains("could not read from remote repository") || t.contains("authentication failed for") || t.contains("could not read username") {
            return tr("Сервер не смог забрать код с GitHub. Проверьте его доступ к репозиторию: ключ или токен на самом сервере.",
                      "The server couldn’t fetch the code from GitHub. Check its access to the repository: a key or token on the server itself.")
        }
        if t.contains("no space left on device") {
            return tr("На сервере кончилось место на диске.", "The server ran out of disk space.")
        }
        if t.contains("permission denied while trying to connect to the docker") {
            return tr("У этого пользователя нет прав на Docker. Добавьте его в группу docker или заходите под root.",
                      "This user has no access to Docker. Add them to the docker group or log in as root.")
        }
        return nil
    }

    /// Why a step failed, in one line: the last line of its output that names an error,
    /// or simply the last line that says anything.
    static func reason(_ url: URL) -> String? { reason(in: LogText.tail(url, bytes: 6000)) }

    static func reason(in text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // Stack frames and closing brackets say nothing on their own.
                line.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 3 && !line.hasPrefix("at ")
            }
        let pattern = #"error|✖|not ok|\bfail|fatal|denied|refused|cannot|can't|no such|not found|exception|unable to|conflict"#
        return lines.suffix(40).last { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil } ?? lines.last
    }
}

/// The real thing: SSH, the clean copy on the Mac, the checks. One instance per deploy.
final class LiveDeploy: @unchecked Sendable {
    let run: UUID
    let server: ServerConfig
    let projectPath: String
    let target: String?
    let previous: String?
    let logDirectory: URL
    let workDirectory: String
    /// Called with what a visit to the server read (the connect and check steps).
    let onFacts: @Sendable (HostFacts) -> Void

    private let process = StepProcess()
    private let lock = NSLock()
    private var remoteActive = false

    /// How long the check step waits for the site and services to come up.
    var verifyTimeout: TimeInterval = 90
    var stepTimeout: TimeInterval = 30 * 60

    init(run: UUID, server: ServerConfig, projectPath: String, target: String?, previous: String?, logDirectory: URL, workDirectory: String,
         onFacts: @escaping @Sendable (HostFacts) -> Void) {
        self.run = run
        self.server = server
        self.projectPath = projectPath
        self.target = target
        self.previous = previous
        self.logDirectory = logDirectory
        self.workDirectory = workDirectory
        self.onFacts = onFacts
    }

    var cancelled: Bool { process.cancelled }

    static func logURL(_ directory: URL, step index: Int) -> URL { directory.appendingPathComponent("\(index).log") }

    func cancel() {
        process.cancel()
        lock.lock()
        let remote = remoteActive
        lock.unlock()
        guard remote else { return }
        // ssh is gone, the command on the server is not: stop its whole process group.
        let file = DeployPipeline.pidFile(run)
        _ = SSH.run(server, script: "p=$(cat \(file) 2>/dev/null) || exit 0; kill -TERM -- -\"$p\" 2>/dev/null || kill -TERM \"$p\" 2>/dev/null; rm -f \(file)", timeout: 20)
    }

    func execute(_ index: Int, _ step: PlannedStep) async -> StepOutcome {
        let log = Self.logURL(logDirectory, step: index)
        return await Task.detached(priority: .userInitiated) { [self] in
            switch step.action {
            case .connect: connect(log)
            case .local(let command): local(command, log)
            case .remote(let script): remote(script, log)
            case .verify: verify(log)
            }
        }.value
    }

    private func connect(_ log: URL) -> StepOutcome {
        StepLog.append("ssh \(server.host)\n", to: log)
        let r = ServerProbe.host(server)
        if cancelled { return .cancelled }
        if let problem = r.problem {
            let text = "\(problem.title): \(r.message ?? "")"
            StepLog.append(text + "\n" + problem.hint + "\n", to: log)
            return .failed(text)
        }
        guard let facts = r.facts else { return .failed(tr("сервер не ответил", "no answer from the server")) }
        onFacts(facts)
        var lines = [tr("Подключение есть.", "Connected.")]
        if let c = facts.shortCommit {
            lines.append(tr("Сейчас на сервере: \(c) \(facts.commitSubject ?? "")", "On the server now: \(c) \(facts.commitSubject ?? "")"))
        } else {
            lines.append(tr("В папке нет git-репозитория или git не установлен.", "No git repository in the folder, or git isn’t installed."))
        }
        if facts.dirty > 0 {
            lines.append(tr("Внимание: на сервере руками изменено файлов: \(facts.dirty). Обновление кода может на них споткнуться.",
                            "Warning: \(facts.dirty) files were edited by hand on the server. The code update may trip over them."))
        }
        if let disk = facts.diskFraction, disk > 0.95 {
            lines.append(tr("Внимание: диск заполнен на \(Int(disk * 100)) %.", "Warning: the disk is \(Int(disk * 100))% full."))
        }
        StepLog.append(lines.joined(separator: "\n") + "\n", to: log)
        return .success
    }

    private func local(_ command: String, _ log: URL) -> StepOutcome {
        let env = DeployPipeline.environment(server, target: target, previous: previous)
        let script = DeployPipeline.localScript(projectPath: projectPath, workDir: workDirectory, branch: server.branch, target: target, command: command, env: env)
        StepLog.append("$ \(command)\n", to: log)
        let status = process.run("/bin/zsh", ["-c", script], env: ["PATH": CLILocator.searchPATH(for: "/bin/zsh")], log: log, timeout: stepTimeout)
        return outcome(status, log)
    }

    private func remote(_ script: String, _ log: URL) -> StepOutcome {
        lock.lock()
        remoteActive = true
        lock.unlock()
        defer {
            lock.lock()
            remoteActive = false
            lock.unlock()
        }
        let wrapped = "export ORBIT_PIDFILE=\(DeployPipeline.pidFile(run))\n" + script
        SSH.prepare()
        let status = process.run(SSH.executable, SSH.command(server, script: wrapped, connectTimeout: 15), log: log, timeout: stepTimeout)
        if status == 255, !cancelled {
            let text = LogText.tail(log, bytes: 4000)
            let fake = ShellResult(status: 255, stdout: "", stderr: text)
            if let p = SSH.problem(fake), p.kind != .other { return .failed("\(p.kind.title): \(p.message)") }
        }
        return outcome(status, log)
    }

    private func outcome(_ status: Int32, _ log: URL) -> StepOutcome {
        if cancelled { return .cancelled }
        if status == 0 { return .success }
        if status == -3 {
            StepLog.append(tr("\nШаг остановлен: не уложился в \(Int(stepTimeout / 60)) мин.\n", "\nStep stopped: it took longer than \(Int(stepTimeout / 60)) min.\n"), to: log)
            return .failed(tr("слишком долго", "took too long"))
        }
        if let hint = StepLog.hint(in: LogText.tail(log, bytes: 6000)) {
            StepLog.append("\n" + hint + "\n", to: log)
            return .failed(hint)
        }
        let line = StepLog.reason(log).map { String($0.prefix(200)) }
        return .failed(line ?? tr("команда завершилась с кодом \(status)", "the command exited with code \(status)"))
    }

    /// Up to `verifyTimeout`: the site answers and nothing is down.
    private func verify(_ log: URL) -> StepOutcome {
        let url = server.siteURL
        let checkServices = server.runtime != .none
        if url == nil && !checkServices {
            StepLog.append(tr("Проверять нечего: не задан адрес сайта и тип запуска.\n", "Nothing to check: no site address and no runtime set.\n"), to: log)
            return .success
        }
        let deadline = Date().addingTimeInterval(verifyTimeout)
        var problem = ""
        while true {
            if cancelled { return .cancelled }
            var ok = true
            var parts: [String] = []
            if let url {
                let site = ServerProbe.site(url)
                if site.up {
                    parts.append(tr("сайт отвечает: \(site.code ?? 0) · \(site.ms ?? 0) мс", "site answers: \(site.code ?? 0) · \(site.ms ?? 0) ms"))
                } else {
                    ok = false
                    problem = tr("сайт не отвечает", "the site doesn’t answer") + " (\(site.code.map(String.init) ?? site.error ?? "—"))"
                    parts.append(problem)
                }
            }
            if checkServices {
                let r = ServerProbe.host(server)
                if let facts = r.facts, r.problem == nil {
                    onFacts(facts)
                    let failing = facts.failingServices
                    if let error = facts.runtimeError {
                        ok = false
                        problem = error
                        parts.append(error)
                    } else if failing.isEmpty {
                        parts.append(tr("запущено: \(facts.services.count) из \(facts.services.count)", "running: \(facts.services.count) of \(facts.services.count)"))
                    } else {
                        ok = false
                        problem = tr("не запущено: ", "not running: ") + failing.map { "\($0.name) (\($0.health == "unhealthy" ? "unhealthy" : $0.state))" }.joined(separator: ", ")
                        parts.append(problem)
                    }
                } else {
                    ok = false
                    problem = "\(r.problem?.title ?? "SSH"): \(r.message ?? "")"
                    parts.append(problem)
                }
            }
            StepLog.append(parts.joined(separator: " · ") + "\n", to: log)
            if ok { return .success }
            if Date() >= deadline { return .failed(problem) }
            Thread.sleep(forTimeInterval: 5)
        }
    }
}
