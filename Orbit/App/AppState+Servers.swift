import AppKit
import Network

/// Production servers: watching them and deploying to them, step by step, over SSH.
extension AppState {
    struct ServerRef: Hashable, Identifiable {
        var projectId: String
        var server: ServerConfig
        var id: UUID { server.id }
    }

    // MARK: - Lookup

    /// Servers of the active projects, in sidebar order.
    var allServers: [ServerRef] {
        config.activeProjects.flatMap { p in (p.servers ?? []).map { ServerRef(projectId: p.id, server: $0) } }
    }

    func servers(for projectId: String) -> [ServerConfig] { project(projectId)?.servers ?? [] }

    func serverRef(_ id: UUID) -> ServerRef? {
        for p in config.projects {
            if let s = p.servers?.first(where: { $0.id == id }) { return ServerRef(projectId: p.id, server: s) }
        }
        return nil
    }

    /// Adds the server or replaces the one with the same id.
    func saveServer(_ projectId: String, _ server: ServerConfig) {
        updateProject(projectId) { p in
            var list = p.servers ?? []
            if let i = list.firstIndex(where: { $0.id == server.id }) { list[i] = server } else { list.append(server) }
            p.servers = list
        }
        Task { await checkServers(force: true, only: server.id) }
    }

    /// "Добавить шаг" in the deploy window: a backup before anything changes, with the dump the project suggests.
    func addBackupStep(_ id: UUID) {
        guard let ref = serverRef(id) else { return }
        var server = ref.server
        server.addBackup(DeployTemplate.detect(projectPath: ref.projectId).steps.first { $0.kind == .backup } ?? .backup())
        updateProject(ref.projectId) { p in
            if let i = p.servers?.firstIndex(where: { $0.id == id }) { p.servers?[i] = server }
        }
    }

    func removeServer(_ id: UUID) {
        guard let ref = serverRef(id) else { return }
        cancelDeploy(id)
        updateProject(ref.projectId) { p in
            p.servers?.removeAll { $0.id == id }
            if p.servers?.isEmpty == true { p.servers = nil }
        }
        serverStatus[id] = nil
        serverSamples[id] = nil
        for run in deployRuns where run.serverId == id { try? FileManager.default.removeItem(at: deployLogDirectory(run.id)) }
        deployRuns.removeAll { $0.serverId == id }
        saveServerState()
        saveDeploys()
        evaluateSignals()
    }

    var serverSnapshots: [String: [ServerSnapshot]] {
        var result: [String: [ServerSnapshot]] = [:]
        for ref in allServers {
            result[ref.projectId, default: []].append(ServerSnapshot(config: ref.server, status: serverStatus[ref.id], lastRun: lastRun(ref.id)))
        }
        return result
    }

    /// Servers that are down right now, for the sidebar badge and the menu bar.
    var serversDown: [ServerRef] {
        allServers.filter { $0.server.monitor && serverStatus[$0.id]?.overall($0.server) == .down }
    }

    // MARK: - Persistence

    /// Unit tests and snapshot runs never open a connection to anything.
    var serverChecksAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--snapshot") && !args.contains("--live-servers") { return false }
        #endif
        return true
    }

    func loadServers() {
        let store = Store.load(ServerStore.self, from: "servers.json") ?? ServerStore()
        serverStatus = Dictionary(uniqueKeysWithValues: store.status.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        serverSamples = Dictionary(uniqueKeysWithValues: store.samples.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        deployRuns = Store.load([DeployRun].self, from: "deploys.json") ?? []
        // A deploy that was running when Orbit quit never got its ending.
        var changed = false
        for i in deployRuns.indices where deployRuns[i].state == .running {
            deployRuns[i].state = .cancelled
            deployRuns[i].finishedAt = deployRuns[i].finishedAt ?? deployRuns[i].startedAt
            for j in deployRuns[i].steps.indices where [.running, .pending].contains(deployRuns[i].steps[j].state) {
                deployRuns[i].steps[j].state = deployRuns[i].steps[j].state == .running ? .cancelled : .skipped
            }
            changed = true
        }
        if changed { saveDeploys() }
    }

    func saveServerState() {
        let known = Set(config.projects.flatMap { ($0.servers ?? []).map(\.id) })
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        serverStatus = serverStatus.filter { known.contains($0.key) }
        serverSamples = serverSamples.filter { known.contains($0.key) }.mapValues { $0.filter { $0.t >= cutoff } }
        let store = ServerStore(status: Dictionary(uniqueKeysWithValues: serverStatus.map { ($0.key.uuidString, $0.value) }),
                                samples: Dictionary(uniqueKeysWithValues: serverSamples.map { ($0.key.uuidString, $0.value) }))
        Store.save(store, to: "servers.json", pretty: false)
    }

    /// Keeps the last 50 deploys of each server and drops the logs of the rest.
    func saveDeploys() {
        let known = Set(config.projects.flatMap { ($0.servers ?? []).map(\.id) })
        var kept: [DeployRun] = [], counts: [UUID: Int] = [:]
        for run in deployRuns.sorted(by: { $0.startedAt > $1.startedAt }) {
            counts[run.serverId, default: 0] += 1
            if known.contains(run.serverId), counts[run.serverId]! <= 50 { kept.append(run) } else { try? FileManager.default.removeItem(at: deployLogDirectory(run.id)) }
        }
        deployRuns = kept
        Store.save(deployRuns, to: "deploys.json", pretty: false)
    }

    func deployLogDirectory(_ run: UUID) -> URL {
        Store.root.appendingPathComponent("deploys", isDirectory: true).appendingPathComponent(run.uuidString, isDirectory: true)
    }

    func stepLogURL(_ run: UUID, step: Int) -> URL { LiveDeploy.logURL(deployLogDirectory(run), step: step) }

    // MARK: - Watching

    func startServerMonitoring() {
        guard serverChecksAllowed else { return }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in self?.macOnline = path.status == .satisfied }
            }
            monitor.start(queue: DispatchQueue(label: "orbit.network"))
            pathMonitor = monitor
        }
        serverTick()
    }

    /// Every minute: the site every 2 minutes, the server itself every 5, then a look at auto-deploys.
    func serverTick() {
        guard serverChecksAllowed, !allServers.isEmpty else { return }
        Task {
            await checkServers(force: false)
            await checkAutoDeploys()
        }
    }

    func checkServers(force: Bool, only: UUID? = nil) async {
        guard serverChecksAllowed, macOnline || force else { return }
        let due = allServers.filter { (only == nil || $0.id == only) && (force || $0.server.monitor) && !serverChecking.contains($0.id) }
        guard !due.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for ref in due { group.addTask { await self.check(ref, force: force) } }
        }
        saveServerState()
        evaluateSignals()
    }

    private func check(_ ref: ServerRef, force: Bool) async {
        let id = ref.id, server = ref.server, repo = ref.projectId
        let before = serverStatus[id] ?? ServerStatus()
        let now = Date()
        let siteDue = server.siteURL != nil && (force || before.siteCheckedAt.map { now.timeIntervalSince($0) >= 110 } ?? true)
        let hostDue = server.problem == nil && (force || before.hostCheckedAt.map { now.timeIntervalSince($0) >= 290 } ?? true)
        guard siteDue || hostDue else { return }
        serverChecking.insert(id)
        defer { serverChecking.remove(id) }

        async let siteResult: SiteCheck? = siteDue ? Task.detached { ServerProbe.site(server.siteURL ?? "") }.value : nil
        async let hostResult = hostDue ? Task.detached { ServerProbe.host(server) }.value : nil
        async let tipResult: String? = hostDue ? Task.detached { DeployGit.remoteTip(repo, branch: server.branch) }.value : nil
        let (site, host, tip) = await (siteResult, hostResult, tipResult)

        // The Mac lost its own network while the checks ran: that says nothing about the server.
        guard macOnline || (site?.up == true) || (host != nil && host?.problem == nil) else { return }
        // A deploy may have refreshed the status meanwhile; build on what is there now.
        var s = serverStatus[id] ?? ServerStatus()
        let checked = Date()
        if let site {
            s.site = site
            s.siteCheckedAt = checked
            s.siteFailures = site.up ? 0 : s.siteFailures + 1
            serverSamples[id, default: []].append(ServerSample(t: checked, up: site.up, ms: site.ms))
        }
        if let host {
            s.hostCheckedAt = checked
            if let problem = host.problem {
                s.sshProblem = problem
                s.sshMessage = host.message
                s.sshFailures += 1
                if problem == .noDirectory { s.host = host.facts }
            } else {
                s.host = host.facts
                s.sshProblem = nil
                s.sshMessage = nil
                s.sshFailures = 0
            }
            // Without a site address, reaching the server over SSH is the availability check.
            if server.siteURL == nil {
                serverSamples[id, default: []].append(ServerSample(t: checked, up: !(host.problem?.unreachable ?? false), ms: nil))
            }
        }
        if hostDue {
            if let tip { s.remoteCommit = tip }
            if let current = s.host?.commit, let tip = s.remoteCommit {
                s.behind = current == tip ? 0 : await Task.detached { DeployGit.behind(repo, from: current, to: tip) }.value
            } else {
                s.behind = nil
            }
        }
        serverStatus[id] = s
    }

    /// A deploy step read the server: keep the screen in step with it.
    func applyFacts(_ facts: HostFacts, serverId: UUID, runId: UUID) {
        var s = serverStatus[serverId] ?? ServerStatus()
        s.host = facts
        s.hostCheckedAt = Date()
        s.sshProblem = nil
        s.sshMessage = nil
        s.sshFailures = 0
        if let current = facts.commit, current == s.remoteCommit { s.behind = 0 }
        serverStatus[serverId] = s
        if let i = deployRuns.firstIndex(where: { $0.id == runId }), deployRuns[i].fromCommit == nil, deployRuns[i].steps.first?.state == .running {
            deployRuns[i].fromCommit = facts.commit
        }
    }

    // MARK: - Deploys

    func runs(_ serverId: UUID) -> [DeployRun] { deployRuns.filter { $0.serverId == serverId } }
    func lastRun(_ serverId: UUID) -> DeployRun? { deployRuns.first { $0.serverId == serverId } }
    func activeRun(_ serverId: UUID) -> DeployRun? { deployRuns.first { $0.serverId == serverId && $0.state == .running } }
    func isDeploying(_ serverId: UUID) -> Bool { activeRun(serverId) != nil }

    /// The commit to go back to: what the server ran before the most recent deploy that changed it.
    func rollbackTarget(_ serverId: UUID) -> String? {
        let current = serverStatus[serverId]?.host?.commit
        return runs(serverId).first { $0.state != .running && $0.fromCommit != nil && $0.fromCommit != current && $0.fromCommit != $0.toCommit }?.fromCommit
    }

    /// Fresh look at both ends before a deploy: origin's branch and the server.
    func deployPreview(_ serverId: UUID) async -> DeployPreview {
        guard let ref = serverRef(serverId) else { return DeployPreview(problem: tr("Сервер не найден", "Server not found")) }
        guard serverChecksAllowed else { return DeployPreview() }
        let server = ref.server, repo = ref.projectId
        async let fetched = Task.detached { DeployGit.fetch(repo, branch: server.branch) }.value
        async let checked: Void = checkServers(force: true, only: serverId)
        let (fetch, _) = await (fetched, checked)
        let status = serverStatus[serverId]
        var preview = DeployPreview(target: fetch.tip, current: status?.host?.commit)
        if let problem = status?.sshProblem {
            preview.problem = "\(problem.title). \(problem.hint)"
            return preview
        }
        guard let target = fetch.tip else {
            preview.problem = tr("Не нашёл ветку \(server.branch) на origin", "Couldn’t find branch \(server.branch) on origin") + (fetch.error.map { ": \($0)" } ?? "")
            return preview
        }
        if let error = fetch.error {
            preview.warning = tr("Не получилось обновить ветку с origin (\(error)) — показываю то, что уже скачано.", "Couldn’t refresh the branch from origin (\(error)) — showing what is already downloaded.")
        }
        preview.subject = await Task.detached { DeployGit.subject(repo, commit: target) }.value
        if let current = preview.current, current != target {
            preview.commits = await Task.detached { DeployGit.commits(repo, from: current, to: target) }.value
            if preview.commits?.isEmpty == true {
                preview.warning = tr("На сервере стоит коммит, которого нет в ветке \(server.branch): обновление кода перемоткой не пройдёт.",
                                     "The server runs a commit that isn’t in branch \(server.branch): the fast-forward code update won’t go through.")
            }
        }
        if (status?.host?.dirty ?? 0) > 0, preview.warning == nil {
            preview.warning = tr("На сервере руками изменено файлов: \(status?.host?.dirty ?? 0). Обновление кода может на них споткнуться.",
                                 "\(status?.host?.dirty ?? 0) files were edited by hand on the server. The code update may trip over them.")
        }
        return preview
    }

    @discardableResult
    func startDeploy(_ serverId: UUID, target: String?, subject: String?, trigger: DeployTrigger, rollbackTo: String? = nil) -> UUID? {
        guard serverChecksAllowed, let ref = serverRef(serverId), !isDeploying(serverId) else { return nil }
        let server = ref.server
        let previous = serverStatus[serverId]?.host?.commit
        let planned = rollbackTo.map { DeployPipeline.rollback(server, to: $0, previous: previous) }
            ?? DeployPipeline.plan(server, target: target, previous: previous)
        let run = DeployRun(projectId: ref.projectId, serverId: serverId, trigger: trigger, startedAt: Date(), fromCommit: previous,
                            toCommit: rollbackTo ?? target, toSubject: subject, steps: planned.map(\.run))
        let runId = run.id
        deployRuns.insert(run, at: 0)
        saveDeploys()

        let job = LiveDeploy(run: runId, server: server, projectPath: ref.projectId, target: rollbackTo ?? target, previous: previous,
                             logDirectory: deployLogDirectory(runId), workDirectory: deployWorkDirectory(ref.projectId)) { [weak self] facts in
            Task { @MainActor in self?.applyFacts(facts, serverId: serverId, runId: runId) }
        }
        deployJobs[serverId] = job
        Task {
            let state = await DeployEngine.run(planned, isCancelled: { job.cancelled },
                                               execute: { index, step in await job.execute(index, step) },
                                               update: { index, step in
                                                   if let i = self.deployRuns.firstIndex(where: { $0.id == runId }), self.deployRuns[i].steps.indices.contains(index) {
                                                       self.deployRuns[i].steps[index] = step
                                                   }
                                               })
            finishDeploy(runId, serverId: serverId, state: state)
        }
        return runId
    }

    private func finishDeploy(_ runId: UUID, serverId: UUID, state: DeployState) {
        deployJobs[serverId] = nil
        guard let i = deployRuns.firstIndex(where: { $0.id == runId }) else { return }
        deployRuns[i].state = state
        deployRuns[i].finishedAt = Date()
        let run = deployRuns[i]
        saveDeploys()
        let name = "\(projectName(run.projectId)) · \(serverRef(serverId)?.server.name ?? "")"
        if config.notifyMacOS, state == .failed || (state == .success && run.trigger == .auto) {
            let body = state == .success
                ? tr("Выкатил \(run.shortTo ?? "") за \(Elapsed.text(run.seconds ?? 0))", "Deployed \(run.shortTo ?? "") in \(Elapsed.text(run.seconds ?? 0))")
                : tr("Выкладка остановилась на шаге «\(run.failedStep?.name ?? "")»", "The deploy stopped at the “\(run.failedStep?.name ?? "")” step")
            Notifier.post(title: name, body: body, id: "deploy-\(runId.uuidString)")
        }
        Task { await checkServers(force: true, only: serverId) }
        evaluateSignals()
    }

    func startRollback(_ serverId: UUID) {
        guard let commit = rollbackTarget(serverId), let ref = serverRef(serverId) else { return }
        Task {
            let subject = await Task.detached { DeployGit.subject(ref.projectId, commit: commit) }.value
            startDeploy(serverId, target: nil, subject: subject, trigger: .rollback, rollbackTo: commit)
        }
    }

    func cancelDeploy(_ serverId: UUID) {
        guard let job = deployJobs[serverId] else { return }
        Task.detached { job.cancel() }
    }

    /// Where the Mac steps run: a clone of the project kept between deploys, so dependencies stay installed.
    func deployWorkDirectory(_ projectId: String) -> String {
        let name = (projectId as NSString).lastPathComponent.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        let tag = String(format: "%08x", UInt32(truncatingIfNeeded: projectId.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
        return Store.root.appendingPathComponent("deploy-work", isDirectory: true).appendingPathComponent("\(name)-\(tag)").path
    }

    /// A new commit on the production branch goes out by itself where the user asked for that.
    func checkAutoDeploys() async {
        guard serverChecksAllowed else { return }
        for ref in allServers where ref.server.autoDeploy {
            let status = serverStatus[ref.id]
            guard AutoDeploy.decide(server: ref.server, status: status, remoteTip: status?.remoteCommit, runs: deployRuns,
                                    deploying: isDeploying(ref.id), online: macOnline) else { continue }
            let repo = ref.projectId, branch = ref.server.branch
            let fetch = await Task.detached { DeployGit.fetch(repo, branch: branch) }.value
            guard let target = fetch.tip, target != status?.host?.commit, !isDeploying(ref.id),
                  !deployRuns.contains(where: { $0.serverId == ref.id && $0.toCommit == target }) else { continue }
            let subject = await Task.detached { DeployGit.subject(repo, commit: target) }.value
            if config.notifyMacOS {
                Notifier.post(title: "\(projectName(repo)) · \(ref.server.name)",
                              body: tr("Новый коммит в \(branch) — выкатываю: \(subject ?? String(target.prefix(7)))", "New commit on \(branch) — deploying: \(subject ?? String(target.prefix(7)))"))
            }
            startDeploy(ref.id, target: target, subject: subject, trigger: .auto)
        }
    }

    // MARK: - Terminal helpers

    /// Opens Terminal with `ssh-copy-id`; the password is typed there and never reaches Orbit.
    func installKey(_ server: ServerConfig) {
        let terminal = config.terminalApp
        Task {
            guard let key = await Task.detached(operation: { SSH.publicKey(create: true) }).value else {
                toast = tr("Не получилось создать ключ", "Couldn’t create a key")
                return
            }
            Shell.openTerminal(at: NSHomeDirectory(), command: SSH.installKeyCommand(server, publicKey: key), app: terminal)
        }
    }

    func openServerTerminal(_ server: ServerConfig) {
        Shell.openTerminal(at: NSHomeDirectory(), command: SSH.terminalCommand(server), app: config.terminalApp)
    }

    func openSite(_ server: ServerConfig) {
        guard let s = server.siteURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
