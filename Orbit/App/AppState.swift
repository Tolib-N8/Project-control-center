import AppKit
import Foundation
import Observation

enum Screen: Hashable {
    case week, projects, sessions, git, signals
    case project(String)

    /// Project pages sit one level below the sidebar sections.
    var depth: Int {
        if case .project = self { return 1 }
        return 0
    }
}

/// Which way the last navigation went; drives the screen transition.
enum NavDirection { case deeper, back, lateral }

struct ProjectProgress: Hashable {
    enum Phase: Hashable { case queued, running, done }
    var phase: Phase = .queued
    var detail = tr("в очереди", "queued")
}

/// Sheets presented over the main window.
enum ActiveSheet: Identifiable {
    case planner(weekKey: String)
    case commit(projectId: String)
    case diff(projectId: String)
    case brief(signalId: String)
    case transcript(sessionId: String)
    case addBlock(day: Int)
    case update
    case taskGoal(projectId: String)
    case launchSet(projectId: String)

    var id: String {
        switch self {
        case .planner(let w): "planner-\(w)"
        case .commit(let p): "commit-\(p)"
        case .diff(let p): "diff-\(p)"
        case .brief(let s): "brief-\(s)"
        case .transcript(let s): "transcript-\(s)"
        case .addBlock(let d): "add-\(d)"
        case .update: "update"
        case .taskGoal(let p): "task-goal-\(p)"
        case .launchSet(let p): "launch-\(p)"
        }
    }
}

@MainActor
@Observable
final class AppState {
    var config = OrbitConfig()
    var repos: [String: RepoStatus] = [:]
    var sessions: [AgentSession] = []
    var plans: [String: WeekPlan] = [:]
    var signals: [Signal] = []
    var tasks: [ProjectTask] = []
    /// GitHub pull requests and CI per project; cached so they show up at launch.
    var github: [String: GitHubRepo] = [:]
    var githubAccess: GitHubAccess = .unknown
    var githubSyncing = false
    /// The development timer and its history.
    var worklog = WorkLog()
    /// Ticks every second while the timer runs, so time on screen and in the menu bar stays live.
    var timerNow = Date()
    var clockTimer: Timer?
    /// "Стоп" is waiting for apps to confirm closing before it removes the project's desktop.
    var desktopCleanup: DesktopCleanup?
    private var lastGitHubSync: Date?

    // Derived, recomputed after every refresh.
    private(set) var snapshots: [String: ProjectSnapshot] = [:]
    private(set) var health: [String: Int] = [:]
    private(set) var healthHistory: [String: [Int]] = [:]

    /// Bumped when the interface language changes; the window rebuilds from it.
    var languageRevision = 0

    var screen: Screen = .week {
        didSet {
            guard screen != oldValue else { return }
            navDirection = screen.depth > oldValue.depth ? .deeper : screen.depth < oldValue.depth ? .back : .lateral
        }
    }
    var navDirection: NavDirection = .lateral
    var sheet: ActiveSheet?
    var toast: String?
    var sessionFilterProject: String?
    var selectedSessionId: String?

    // AI analysis
    var aiCache = AICache()
    /// Keys of running jobs: "project:<id>", "session:<id>".
    var aiBusy: Set<String> = []
    var aiError: String?

    // Self-update
    enum UpdatePhase: Equatable {
        case idle, checking, upToDate
        case downloading(Double)
        case installing
        case failed(String)
    }
    var availableUpdate: ReleaseInfo?
    var updatePhase: UpdatePhase = .idle
    var lastUpdateCheck: Date?
    private var updateTimer: Timer?

    var isSyncing = false
    var lastSync: Date?
    var progress: [String: ProjectProgress] = [:]
    var analysisFraction: Double = 0
    var now = Date()

    private var timer: Timer?
    private var ticker: Timer?

    // MARK: - Lifecycle

    func load() {
        config = Store.load(OrbitConfig.self, from: "config.json") ?? OrbitConfig()
        L10n.current = config.language.resolved
        // Rules added in later versions get their defaults.
        for kind in SignalRuleKind.allCases where !config.rules.contains(where: { $0.kind == kind }) {
            config.rules.append(SignalRuleConfig(kind: kind))
        }
        plans = Store.load([String: WeekPlan].self, from: "plans.json") ?? [:]
        signals = Store.load([Signal].self, from: "signals.json") ?? []
        tasks = Store.load([ProjectTask].self, from: "tasks.json") ?? []
        github = Store.load([String: GitHubRepo].self, from: "github.json") ?? [:]
        worklog = Store.load(WorkLog.self, from: "worklog.json") ?? WorkLog()
        worklog.recover(now: Date())
        worklog.prune(before: Date().addingTimeInterval(-120 * 86400))
        saveWorklog()
        syncClock()
        aiCache = Store.load(AICache.self, from: "ai-cache.json") ?? AICache()
        if config.onboarded { start() }
    }

    func start() {
        Notifier.requestAuthorization()
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        scheduleUpdateChecks()
        observeSleep()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.heartbeat()
                self?.runSchedules()
                self?.refreshForAgentTasks()
            }
        }
    }

    func saveConfig() { Store.save(config, to: "config.json") }
    func savePlans() { Store.save(plans, to: "plans.json") }
    func saveSignals() { Store.save(signals, to: "signals.json") }
    func saveTasks() { Store.save(tasks, to: "tasks.json") }

    // MARK: - Tasks

    func tasks(for projectId: String) -> [ProjectTask] { tasks.filter { $0.projectId == projectId } }

    @discardableResult
    func addTask(_ projectId: String, title: String) -> ProjectTask? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let folders = TaskArea.folders(in: project(projectId)?.path ?? projectId)
        let task = ProjectTask(projectId: projectId, title: title, area: TaskArea.detect(title: title, folders: folders))
        tasks.append(task)
        saveTasks()
        return task
    }

    /// Adds the selected drafts, keeping their order.
    func addTasks(_ projectId: String, _ drafts: [TaskDraft]) {
        tasks += TaskDraft.tasks(drafts, projectId: projectId)
        saveTasks()
    }

    func toggleTask(_ id: UUID) {
        updateTask(id) { $0.completedAt = $0.done ? nil : Date() }
    }

    func updateTask(_ id: UUID, _ change: (inout ProjectTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        saveTasks()
    }

    func agentState(_ task: ProjectTask) -> TaskAgentState? {
        TaskAgent.state(for: task, sessions: snapshots[task.projectId]?.sessions ?? [], now: now)
    }

    /// The agent to offer first: the one last used in the project, Claude Code otherwise.
    func preferredAgent(_ projectId: String) -> AgentKind {
        snapshots[projectId]?.sessions.first { TaskAgent.supported.contains($0.agent) }?.agent ?? .claude
    }

    /// Hands the task to an agent in the project's terminal.
    func assignTask(_ id: UUID, to agent: AgentKind) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        updateTask(id) { $0.agent = agent; $0.assignedAt = Date() }
        runAgent(task.projectId, prompt: TaskAgent.prompt(for: task), agent: agent)
        toast = tr("\(agent.title) получил задачу", "\(agent.title) got the task")
        // Pick up the new session soon instead of waiting for the regular refresh.
        Task {
            try? await Task.sleep(for: .seconds(45))
            await refresh()
        }
    }

    func unassignTask(_ id: UUID) {
        updateTask(id) { $0.agent = nil; $0.assignedAt = nil }
    }

    /// While an agent works on a task, refresh every couple of minutes so its status keeps up.
    func refreshForAgentTasks() {
        guard !isSyncing, tasks.contains(where: { !$0.done && agentState($0)?.inFlight == true }) else { return }
        if let last = lastSync, now.timeIntervalSince(last) < 120 { return }
        Task { await refresh() }
    }

    func deleteTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        saveTasks()
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let projects = config.projects
        let cfg = config
        for p in projects where progress[p.id] == nil || lastSync == nil {
            progress[p.id] = ProjectProgress()
        }

        // Git status per project, in parallel.
        let statuses = await withTaskGroup(of: (String, RepoStatus).self) { group in
            for p in projects {
                group.addTask { (p.id, GitService.status(p.path)) }
            }
            var result: [String: RepoStatus] = [:]
            for await (id, status) in group {
                result[id] = status
                await MainActor.run {
                    if self.progress[id]?.phase != .done {
                        self.progress[id] = ProjectProgress(phase: .running, detail: tr("git прочитан", "git read"))
                    }
                }
            }
            return result
        }

        let indexed = await Task.detached(priority: .userInitiated) { () -> [AgentSession] in
            SessionIndexer.index(projects: projects, config: cfg) { done, total in
                Task { @MainActor in self.analysisFraction = total == 0 ? 1 : Double(done) / Double(total) }
            }
        }.value
        let analyzed = SessionAnalyzer.analyze(indexed, repos: statuses)

        repos = analyzed.repos
        sessions = analyzed.sessions
        analysisFraction = 1
        recompute()
        for p in projects {
            let score = health[p.id] ?? 0
            progress[p.id] = ProjectProgress(phase: .done, detail: tr("\(score) · \(score >= 75 ? "хорошо" : score >= 50 ? "внимание" : "критично")", "\(score) · \(score >= 75 ? "good" : score >= 50 ? "attention" : "critical")"))
        }
        evaluateSignals()
        lastSync = Date()
        now = Date()
        runSchedules()
        if config.ai.autoAnalyze { analyzeProjects() }
        Task { await refreshGitHub() }
    }

    /// PRs and CI through `gh`, at most every 5 minutes unless forced; runs after the local refresh.
    func refreshGitHub(force: Bool = false) async {
        guard !githubSyncing else { return }
        if !force, let last = lastGitHubSync, Date().timeIntervalSince(last) < 5 * 60 { return }
        githubSyncing = true
        defer { githubSyncing = false }
        lastGitHubSync = Date()
        githubAccess = await Task.detached { GitHubService.access() }.value
        guard githubAccess.login != nil else { return }
        let targets = config.activeProjects.map { ($0.id, $0.path, repos[$0.id]?.branch ?? "") }
        let fetched = await withTaskGroup(of: (String, Bool, GitHubRepo?).self) { group in
            for (id, path, branch) in targets {
                group.addTask {
                    guard let slug = GitHubService.slug(forRepo: path) else { return (id, false, nil) }
                    return (id, true, GitHubService.fetch(slug: slug, branch: branch))
                }
            }
            var result: [(String, Bool, GitHubRepo?)] = []
            for await item in group { result.append(item) }
            return result
        }
        // A failed request keeps the last known data; a repo without a GitHub remote drops out.
        for (id, onGitHub, repo) in fetched {
            if !onGitHub { github[id] = nil } else if let repo { github[id] = repo }
        }
        github = github.filter { id, _ in config.activeProjects.contains { $0.id == id } }
        Store.save(github, to: "github.json", pretty: false)
    }

    /// Open pull requests across active projects, newest first.
    var openPulls: [(projectId: String, pr: PullRequest)] {
        github.flatMap { id, repo in repo.pulls.map { (id, $0) } }.sorted { $0.pr.updatedAt > $1.pr.updatedAt }
    }

    /// Opens Terminal with `gh auth login`.
    func signInToGitHub() {
        let terminal = config.terminalApp
        Task {
            let command = await Task.detached { CLILocator.terminalCommand("gh", "auth login") }.value
            Shell.openTerminal(at: NSHomeDirectory(), command: command, app: terminal)
        }
    }

    /// "Проанализировать": fresh data, then a forced AI pass (heuristics only refresh).
    func analyzeNow(projectId: String? = nil) {
        Task {
            await refresh()
            analyzeProjects(force: true, only: projectId)
        }
    }

    func recompute() {
        var snaps: [String: ProjectSnapshot] = [:]
        var scores: [String: Int] = [:]
        var histories: [String: [Int]] = [:]
        for p in config.projects {
            let snap = ProjectSnapshot(config: p, repo: repos[p.id] ?? RepoStatus(),
                                       sessions: sessions.filter { $0.projectId == p.id })
            snaps[p.id] = snap
            let history = HealthEngine.history(snap, days: 14)
            histories[p.id] = history
            scores[p.id] = history.last ?? HealthEngine.score(snap)
        }
        snapshots = snaps
        health = scores
        healthHistory = histories
    }

    func evaluateSignals() {
        guard config.rhythm.signalsEnabled else { return }
        let active = activeSnapshots
        let before = Set(signals.filter { $0.state == .active }.map(\.id))
        signals = SignalEngine.evaluate(config: config, projects: active, plans: [currentPlan, plan(nextWeekKey)], existing: signals, work: worklog.intervals)
        if config.notifyMacOS {
            for i in signals.indices where signals[i].state == .active && !signals[i].notified && !before.contains(signals[i].id) {
                let s = signals[i]
                Notifier.post(title: "\(projectName(s.projectId)): \(s.severity.title.lowercased())", body: s.title, id: s.id)
                signals[i].notified = true
            }
        }
        saveSignals()
    }

    // MARK: - Schedules (morning brief, Sunday plan)

    func runSchedules() {
        guard config.onboarded, lastSync != nil else { return }
        let cal = Week.calendar
        let hour = cal.component(.hour, from: now)
        let todayKey = DateFormat.isoDay.string(from: now)

        if config.rhythm.morningBrief, config.notifyMacOS, hour >= 9, hour < 12, config.lastMorningBrief != todayKey {
            config.lastMorningBrief = todayKey
            saveConfig()
            Notifier.post(title: tr("Orbit · утренняя сводка", "Orbit · morning brief"), body: morningBrief())
        }

        if config.rhythm.autoPlanSunday, Week.weekdayIndex(now) == 6, hour >= 20 {
            let nextMonday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let key = Week.key(nextMonday)
            if config.lastAutoPlanWeek != key {
                config.lastAutoPlanWeek = key
                saveConfig()
                if plans[key]?.blocks.isEmpty ?? true {
                    plans[key] = makePlan(weekKey: key)
                    savePlans()
                    Notifier.post(title: tr("Orbit · план на неделю \(Week.number(nextMonday))", "Orbit · plan for week \(Week.number(nextMonday))"), body: tr("План составлен — проверьте и сохраните.", "The plan is ready — review and save it."))
                }
            }
        }
    }

    func morningBrief() -> String {
        let today = Week.weekdayIndex(now)
        let blocks = currentPlan.blocks(on: today)
        guard !blocks.isEmpty else {
            return tr("На сегодня ничего не запланировано. Активных сигналов: \(activeSignals.count).", "Nothing planned for today. Active signals: \(activeSignals.count).")
        }
        var parts = blocks.map { b -> String in
            let name = projectName(b.projectId)
            let step = snapshots[b.projectId].map { nextSteps($0).first ?? "" } ?? ""
            return tr("\(name) \(Duration.hours(b.hours)) ч — \(step)", "\(name) \(Duration.hours(b.hours)) h — \(step)")
        }
        if !activeSignals.isEmpty { parts.append(tr("Сигналов: \(activeSignals.count)", "Signals: \(activeSignals.count)")) }
        return parts.joined(separator: "\n")
    }

    // MARK: - AI analysis

    private func makeProvider() -> AIProvider? {
        do { return try AIProviders.make(config.ai) } catch {
            aiError = error.localizedDescription
            return nil
        }
    }

    /// Re-analyses projects whose facts changed. Without `force`, a project is re-run at most
    /// every `minHoursBetweenRuns` hours to save subscription limits.
    func analyzeProjects(force: Bool = false, only projectId: String? = nil) {
        guard config.ai.isEnabled, let provider = makeProvider() else { return }
        var jobs: [(id: String, request: AIRequest, hash: String)] = []
        for snap in activeSnapshots where projectId == nil || snap.config.id == projectId {
            let id = snap.config.id
            guard !aiBusy.contains("project:" + id) else { continue }
            let (request, hash) = AnalysisService.projectRequest(snap, health: health[id] ?? 0,
                                                                 signals: activeSignals.filter { $0.projectId == id })
            if let cached = aiCache.projects[id], cached.source == provider.label {
                if cached.inputHash == hash && !force { continue }
                if !force && now.timeIntervalSince(cached.createdAt) < config.ai.minHoursBetweenRuns * 3600 { continue }
            }
            jobs.append((id, request, hash))
        }
        guard !jobs.isEmpty else { return }
        for job in jobs { aiBusy.insert("project:" + job.id) }

        Task {
            // Two requests at a time is gentle on CLI subscriptions and local models.
            await withTaskGroup(of: Void.self) { group in
                var pending = jobs[...]
                func next() {
                    guard let job = pending.popFirst() else { return }
                    group.addTask { await self.runProjectJob(provider, job.id, job.request, job.hash) }
                }
                next(); next()
                for await _ in group { next() }
            }
        }
    }

    private func runProjectJob(_ provider: AIProvider, _ id: String, _ request: AIRequest, _ hash: String) async {
        defer { aiBusy.remove("project:" + id) }
        do {
            let obj = try await provider.complete(request)
            aiCache.projects[id] = try AnalysisService.parseProject(obj, source: provider.label, hash: hash)
            aiError = nil
            Store.save(aiCache, to: "ai-cache.json", pretty: false)
        } catch {
            aiError = "\(projectName(id)): \(error.localizedDescription)"
        }
    }

    func analyzeSession(_ s: AgentSession, force: Bool = false) {
        guard config.ai.isEnabled, !aiBusy.contains("session:" + s.id), let provider = makeProvider() else { return }
        let (request, hash) = AnalysisService.sessionRequest(s)
        if !force, let cached = aiCache.sessions[s.id], cached.inputHash == hash, cached.source == provider.label { return }
        aiBusy.insert("session:" + s.id)
        Task {
            defer { aiBusy.remove("session:" + s.id) }
            do {
                let obj = try await provider.complete(request)
                aiCache.sessions[s.id] = try AnalysisService.parseSession(obj, source: provider.label, hash: hash)
                aiError = nil
                Store.save(aiCache, to: "ai-cache.json", pretty: false)
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    func aiCommitMessage(_ projectId: String) async throws -> String {
        guard let provider = try AIProviders.make(config.ai) else { throw AIError.notConfigured(tr("ИИ-анализ выключен", "AI analysis is off")) }
        let repo = repos[projectId] ?? RepoStatus()
        let diff: String? = config.ai.sendDiffs ? await Task.detached { GitService.diff(projectId) }.value : nil
        let request = AnalysisService.commitRequest(project: projectName(projectId), changes: repo.changes, diff: diff,
                                                    sessions: snapshots[projectId]?.sessions ?? [])
        let obj = try await provider.complete(request)
        guard let message = obj["message"] as? String, !message.trimmed.isEmpty else { throw AIError.badResponse(tr("пустое сообщение", "empty message")) }
        return message.trimmed
    }

    func aiBrief(_ signalId: String) async throws -> String {
        guard let provider = try AIProviders.make(config.ai) else { throw AIError.notConfigured(tr("ИИ-анализ выключен", "AI analysis is off")) }
        guard let signal = signals.first(where: { $0.id == signalId }), let snap = snapshots[signal.projectId] else {
            throw AIError.notConfigured(tr("Сигнал не найден", "Signal not found"))
        }
        let obj = try await provider.complete(AnalysisService.briefRequest(signal: signal, snapshot: snap))
        guard let brief = obj["brief"] as? String, !brief.trimmed.isEmpty else { throw AIError.badResponse(tr("пустой бриф", "empty brief")) }
        return brief.trimmed
    }

    /// AI breaks a goal down into tasks for review.
    func aiTasks(_ projectId: String, goal: String) async throws -> [TaskDraft] {
        guard let provider = try AIProviders.make(config.ai) else { throw AIError.notConfigured(tr("ИИ-анализ выключен", "AI analysis is off")) }
        guard let snap = snapshots[projectId] else { throw AIError.notConfigured(tr("Проект не найден", "Project not found")) }
        let path = project(projectId)?.path ?? projectId
        let folders = await Task.detached { TaskArea.folders(in: path) }.value
        let open = tasks(for: projectId).filter { !$0.done }.map(\.title)
        let request = AnalysisService.tasksRequest(goal: goal, snapshot: snap, folders: folders, openTasks: open)
        return try AnalysisService.parseTasks(try await provider.complete(request), folders: folders)
    }

    func testAI() async -> (ok: Bool, message: String) {
        do {
            guard let provider = try AIProviders.make(config.ai) else { return (true, tr("Эвристики работают без модели", "Heuristics work without a model")) }
            let started = Date()
            let obj = try await provider.complete(AIProviders.testRequest)
            let reply = obj["reply"] as? String ?? "ok"
            return (true, tr("\(provider.label) ответил «\(reply)» за \(String(format: "%.1f", Date().timeIntervalSince(started))) с", "\(provider.label) replied “\(reply)” in \(String(format: "%.1f", Date().timeIntervalSince(started))) s"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        config.language = language
        saveConfig()
        // System menus (About, Hide, Quit) follow AppleLanguages and switch on the next launch.
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
        applyLanguage()
    }

    /// Re-resolves the interface language and rebuilds everything that holds text.
    func applyLanguage() {
        let resolved = config.language.resolved
        guard resolved != L10n.current else { return }
        L10n.current = resolved
        recompute()
        evaluateSignals() // signal titles and details are generated text
        languageRevision += 1
        if config.ai.autoAnalyze { analyzeProjects() }
    }

    func setAIProvider(_ kind: AIProviderKind) {
        config.ai.provider = kind
        aiError = nil
        saveConfig()
    }

    // Results with heuristic fallback. AI answers are shown only while a model provider is selected.

    /// Cached answers are shown only in the language they were written in; otherwise the
    /// heuristic text shows until the model answers again.
    func projectAI(_ id: String) -> ProjectAI? {
        guard config.ai.isEnabled, let ai = aiCache.projects[id], (ai.lang ?? "ru") == L10n.current.rawValue else { return nil }
        return ai
    }

    func sessionAI(_ id: String) -> SessionAI? {
        guard config.ai.isEnabled, let ai = aiCache.sessions[id], (ai.lang ?? "ru") == L10n.current.rawValue else { return nil }
        return ai
    }

    func headline(_ p: ProjectSnapshot) -> String { projectAI(p.config.id)?.headline ?? InsightEngine.headline(p) }
    func cardSummary(_ p: ProjectSnapshot) -> String { projectAI(p.config.id)?.summary ?? InsightEngine.cardSummary(p) }
    func digest(_ p: ProjectSnapshot) -> String? {
        if let d = projectAI(p.config.id)?.digest, !d.isEmpty { return d }
        return InsightEngine.sessionsDigest(p)
    }
    func nextSteps(_ p: ProjectSnapshot) -> [String] {
        if let steps = projectAI(p.config.id)?.nextSteps, !steps.isEmpty { return steps }
        return InsightEngine.nextSteps(p)
    }

    var aiLabel: String? {
        guard config.ai.isEnabled else { return nil }
        return config.ai.provider == .claudeCode ? "Claude" : config.ai.provider.title
    }

    // MARK: - Updates

    private func scheduleUpdateChecks() {
        guard Updater.isEnabled else { return }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates() }
        }
        Task {
            #if DEBUG
            let immediate = ProcessInfo.processInfo.arguments.contains("--auto-update")
                || ProcessInfo.processInfo.arguments.contains("--update-via-sheet")
            #else
            let immediate = false
            #endif
            try? await Task.sleep(for: .seconds(immediate ? 1 : 10))
            await checkForUpdates()
        }
    }

    /// Automatic checks respect the settings and skipped versions; a manual check always reports back.
    func checkForUpdates(manual: Bool = false) async {
        guard Updater.isEnabled else {
            if manual { toast = tr("Обновления работают только в установленной версии Orbit", "Updates only work in an installed copy of Orbit") }
            return
        }
        guard manual || config.autoCheckUpdates else { return }
        if case .downloading = updatePhase { return }
        if updatePhase == .checking || updatePhase == .installing { return }

        updatePhase = .checking
        do {
            let release = try await Updater.fetchLatest()
            lastUpdateCheck = Date()
            guard Updater.isNewer(release) else {
                availableUpdate = nil
                updatePhase = .upToDate
                if manual { toast = tr("Установлена последняя версия — \(Updater.currentVersion)", "You have the latest version — \(Updater.currentVersion)") }
                return
            }
            if !manual && release.version == config.skippedVersion {
                updatePhase = .idle
                return
            }
            withMotion(Motion.page) { availableUpdate = release }
            updatePhase = .idle
            if manual {
                sheet = .update
            } else if config.notifiedUpdateVersion != release.version {
                config.notifiedUpdateVersion = release.version
                saveConfig()
                Notifier.post(title: "Orbit \(release.version)", body: tr("Доступна новая версия — обновление займёт несколько секунд.", "A new version is available — updating takes a few seconds."))
            }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            let forced = args.contains("--auto-update")
            if args.contains("--update-via-sheet") {
                // Reproduces the user path: the update sheet is open when "Установить" is pressed.
                sheet = .update
                try? await Task.sleep(for: .seconds(1.5))
                installUpdate()
                return
            }
            #else
            let forced = false
            #endif
            if forced || (config.autoInstallUpdates && Updater.installBlocker == nil) { installUpdate() }
        } catch {
            updatePhase = manual ? .failed(error.localizedDescription) : .idle
            if manual { toast = error.localizedDescription }
        }
    }

    func installUpdate() {
        guard let release = availableUpdate else { return }
        if case .downloading = updatePhase { return }
        updatePhase = .downloading(0)
        Task {
            do {
                try await Updater.install(release) { p in
                    if case .downloading = self.updatePhase { self.updatePhase = .downloading(p) }
                }
                updatePhase = .installing
                // The helper swaps the bundle as soon as we are gone and relaunches the new version.
                // AppKit refuses to terminate while a sheet is attached, so close it first; if
                // anything else still blocks quitting, exit hard (all state is already on disk).
                sheet = nil
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.terminate(nil)
                try? await Task.sleep(for: .seconds(3))
                exit(0)
            } catch {
                updatePhase = .failed(error.localizedDescription)
            }
        }
    }

    func skipUpdate() {
        guard let release = availableUpdate else { return }
        config.skippedVersion = release.version
        saveConfig()
        withMotion { availableUpdate = nil }
        sheet = nil
    }

    // MARK: - Projects

    var activeSnapshots: [ProjectSnapshot] {
        config.activeProjects.compactMap { snapshots[$0.id] }
    }

    func project(_ id: String) -> ProjectConfig? { config.projects.first { $0.id == id } }
    func projectName(_ id: String) -> String { project(id)?.name ?? (id as NSString).lastPathComponent }
    func colorIndex(_ id: String) -> Int { project(id)?.colorIndex ?? 0 }

    func updateProject(_ id: String, _ change: (inout ProjectConfig) -> Void) {
        guard let i = config.projects.firstIndex(where: { $0.id == id }) else { return }
        change(&config.projects[i])
        saveConfig()
        recompute()
    }

    func addProject(path: String) {
        guard !config.projects.contains(where: { $0.path == path }) else {
            toast = tr("Проект уже подключён", "Project already added")
            return
        }
        guard GitService.isRepo(path) else {
            toast = tr("В папке нет git-репозитория", "No git repository in that folder")
            return
        }
        let used = Set(config.projects.map(\.colorIndex))
        let color = (0..<Theme.projectPalette.count).first { !used.contains($0) } ?? config.projects.count
        config.projects.append(ProjectConfig(path: path, name: (path as NSString).lastPathComponent, colorIndex: color))
        saveConfig()
        Task { await refresh() }
    }

    func removeProject(_ id: String) {
        config.projects.removeAll { $0.id == id }
        saveConfig()
        recompute()
        if case .project(id) = screen { screen = .projects }
    }

    // MARK: - Signals

    var activeSignals: [Signal] { signals.filter { $0.state == .active } }

    func snooze(_ id: String, days: Int = 1) {
        guard let i = signals.firstIndex(where: { $0.id == id }) else { return }
        signals[i].state = .snoozed
        signals[i].snoozedUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
        saveSignals()
    }

    func unsnooze(_ id: String) {
        guard let i = signals.firstIndex(where: { $0.id == id }) else { return }
        signals[i].state = .active
        signals[i].snoozedUntil = nil
        saveSignals()
    }

    func setRule(_ kind: SignalRuleKind, enabled: Bool) {
        guard let i = config.rules.firstIndex(where: { $0.kind == kind }) else { return }
        config.rules[i].enabled = enabled
        saveConfig()
        evaluateSignals()
    }

    // MARK: - Plans

    var currentMonday: Date { Week.monday(of: now) }
    var currentWeekKey: String { Week.key(currentMonday) }
    var currentPlan: WeekPlan { plans[currentWeekKey] ?? WeekPlan(weekKey: currentWeekKey) }

    func plan(_ key: String) -> WeekPlan { plans[key] ?? WeekPlan(weekKey: key) }

    var nextWeekKey: String { Week.key(Week.day(7, of: currentMonday)) }

    /// Working hours left in the current week, starting today.
    var remainingCapacity: Int {
        (Week.weekdayIndex(now)..<7).reduce(0) { $0 + config.rhythm.hours[$1] }
    }

    /// The week the dashboard shows: switches to next week once this one has no working time left
    /// and nothing was planned for it (e.g. first launch on a weekend).
    var displayWeekKey: String {
        if remainingCapacity > 0 { return currentWeekKey }
        if currentPlan.blocks.isEmpty || !plan(nextWeekKey).blocks.isEmpty { return nextWeekKey }
        return currentWeekKey
    }

    func makePlan(weekKey: String, seed: Int = 0) -> WeekPlan {
        let startDay = weekKey == currentWeekKey ? Week.weekdayIndex(now) : 0
        return Planner.makePlan(weekKey: weekKey, projects: activeSnapshots, signals: activeSignals,
                                rhythm: config.rhythm, startDay: startDay, seed: seed)
    }

    func savePlan(_ plan: WeekPlan) {
        var plan = plan
        Planner.assignStartTimes(&plan.blocks, rhythm: config.rhythm)
        plans[plan.weekKey] = plan
        savePlans()
        evaluateSignals()
    }

    func addBlock(projectId: String, day: Int, hours: Double = 2, weekKey: String? = nil) {
        var p = plan(weekKey ?? currentWeekKey)
        if let i = p.blocks.firstIndex(where: { $0.projectId == projectId && $0.day == day }) {
            p.blocks[i].hours += hours
        } else {
            p.blocks.append(PlanBlock(projectId: projectId, day: day, hours: hours))
        }
        savePlan(p)
    }

    func updateBlock(_ id: UUID, weekKey: String? = nil, _ change: (inout PlanBlock) -> Void) {
        var p = plan(weekKey ?? currentWeekKey)
        guard let i = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&p.blocks[i])
        if p.blocks[i].hours <= 0 { p.blocks.remove(at: i) }
        savePlan(p)
    }

    func removeBlock(_ id: UUID, weekKey: String? = nil) {
        var p = plan(weekKey ?? currentWeekKey)
        p.blocks.removeAll { $0.id == id }
        savePlan(p)
    }

    /// Today's focus block: the first (largest) block planned for today.
    var todayFocus: PlanBlock? {
        currentPlan.blocks(on: Week.weekdayIndex(now)).max { $0.hours < $1.hours }
    }

    func actualHours(_ projectId: String, on date: Date) -> Double {
        Activity.hours(snapshots[projectId]?.sessions ?? [], timer: worklog.intervals.filter { $0.projectId == projectId }, on: date, now: now)
    }

    // MARK: - Actions

    func openTerminal(_ projectId: String, command: String? = nil) {
        Shell.openTerminal(at: projectId, command: command, app: config.terminalApp)
    }

    func showSession(_ s: AgentSession) {
        selectedSessionId = s.id
        screen = .sessions
    }

    func resume(_ session: AgentSession) {
        switch session.agent {
        case .claude:
            openAgent(session.projectId, cli: "claude", args: session.resumeId.map { "--resume \($0)" } ?? "--continue")
        case .codex:
            openAgent(session.projectId, cli: "codex", args: session.resumeId.map { "resume \($0)" } ?? "resume --last")
        default:
            openTerminal(session.projectId)
        }
    }

    /// Starts an agent with a prepared task in the project's terminal.
    func runAgent(_ projectId: String, prompt: String, agent: AgentKind = .claude) {
        openAgent(projectId, cli: agent == .codex ? "codex" : "claude", args: Shell.quote(prompt))
    }

    func startWorkSession(_ projectId: String) {
        if let last = snapshots[projectId]?.sessions.first(where: { $0.agent == .claude || $0.agent == .codex }),
           last.status != .done {
            resume(last)
        } else {
            openAgent(projectId, cli: "claude", args: "")
        }
    }

    /// Opens the project's terminal with an agent CLI resolved the same way the AI providers find it.
    private func openAgent(_ projectId: String, cli: String, args: String) {
        let terminal = config.terminalApp
        Task {
            let command = await Task.detached { CLILocator.terminalCommand(cli, args) }.value
            Shell.openTerminal(at: projectId, command: command, app: terminal)
        }
    }

    func runGit(_ label: String, _ work: @escaping @Sendable () -> ShellResult) {
        Task {
            let r = await Task.detached { work() }.value
            toast = r.ok ? label : tr("Ошибка: ", "Error: ") + (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            await refresh()
        }
    }

    func fetchAll() {
        let paths = config.activeProjects.map(\.path)
        Task {
            isSyncing = true
            let failures = await Task.detached { paths.filter { !GitService.fetch($0).ok }.count }.value
            isSyncing = false
            toast = failures == 0 ? tr("Fetch выполнен для \(Plural.repos(paths.count))", "Fetched \(Plural.repos(paths.count))") : tr("Fetch: ошибок — \(failures)", "Fetch: \(failures) failed")
            await refresh()
            await refreshGitHub(force: true)
        }
    }

    func finishOnboarding(repos: [FoundRepo], rhythm: Rhythm) {
        config.projects = repos.enumerated().map { i, r in
            ProjectConfig(path: r.path, name: r.name, colorIndex: i)
        }
        config.rhythm = rhythm
        config.onboarded = true
        saveConfig()
        screen = .week
        start()
    }

    func resetOnboarding() {
        config.onboarded = false
        saveConfig()
    }
}
