import AppKit
import Foundation
import Observation

enum Screen: Hashable {
    case week, projects, sessions, git, signals
    case project(String)
}

struct ProjectProgress: Hashable {
    enum Phase: Hashable { case queued, running, done }
    var phase: Phase = .queued
    var detail = "в очереди"
}

/// Sheets presented over the main window.
enum ActiveSheet: Identifiable {
    case planner(weekKey: String)
    case commit(projectId: String)
    case diff(projectId: String)
    case brief(signalId: String)
    case transcript(sessionId: String)
    case addBlock(day: Int)

    var id: String {
        switch self {
        case .planner(let w): "planner-\(w)"
        case .commit(let p): "commit-\(p)"
        case .diff(let p): "diff-\(p)"
        case .brief(let s): "brief-\(s)"
        case .transcript(let s): "transcript-\(s)"
        case .addBlock(let d): "add-\(d)"
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

    // Derived, recomputed after every refresh.
    private(set) var snapshots: [String: ProjectSnapshot] = [:]
    private(set) var health: [String: Int] = [:]
    private(set) var healthHistory: [String: [Int]] = [:]

    var screen: Screen = .week
    var sheet: ActiveSheet?
    var toast: String?
    var sessionFilterProject: String?
    var selectedSessionId: String?

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
        // Rules added in later versions get their defaults.
        for kind in SignalRuleKind.allCases where !config.rules.contains(where: { $0.kind == kind }) {
            config.rules.append(SignalRuleConfig(kind: kind))
        }
        plans = Store.load([String: WeekPlan].self, from: "plans.json") ?? [:]
        signals = Store.load([Signal].self, from: "signals.json") ?? []
        if config.onboarded { start() }
    }

    func start() {
        Notifier.requestAuthorization()
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.runSchedules()
            }
        }
    }

    func saveConfig() { Store.save(config, to: "config.json") }
    func savePlans() { Store.save(plans, to: "plans.json") }
    func saveSignals() { Store.save(signals, to: "signals.json") }

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
                        self.progress[id] = ProjectProgress(phase: .running, detail: "git прочитан")
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
            progress[p.id] = ProjectProgress(phase: .done, detail: "\(score) · \(score >= 75 ? "хорошо" : score >= 50 ? "внимание" : "критично")")
        }
        evaluateSignals()
        lastSync = Date()
        now = Date()
        runSchedules()
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
        signals = SignalEngine.evaluate(config: config, projects: active, plans: [currentPlan, plan(nextWeekKey)], existing: signals)
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
            Notifier.post(title: "Orbit · утренняя сводка", body: morningBrief())
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
                    Notifier.post(title: "Orbit · план на неделю \(Week.number(nextMonday))", body: "План составлен — проверьте и сохраните.")
                }
            }
        }
    }

    func morningBrief() -> String {
        let today = Week.weekdayIndex(now)
        let blocks = currentPlan.blocks(on: today)
        guard !blocks.isEmpty else {
            return "На сегодня ничего не запланировано. Активных сигналов: \(activeSignals.count)."
        }
        var parts = blocks.map { b -> String in
            let name = projectName(b.projectId)
            let step = snapshots[b.projectId].map { InsightEngine.nextSteps($0).first ?? "" } ?? ""
            return "\(name) \(Duration.hours(b.hours)) ч — \(step)"
        }
        if !activeSignals.isEmpty { parts.append("Сигналов: \(activeSignals.count)") }
        return parts.joined(separator: "\n")
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
            toast = "Проект уже подключён"
            return
        }
        guard GitService.isRepo(path) else {
            toast = "В папке нет git-репозитория"
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
        Activity.hours(snapshots[projectId]?.sessions ?? [], on: date)
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
            openTerminal(session.projectId, command: session.resumeId.map { "claude --resume \($0)" } ?? "claude --continue")
        case .codex:
            openTerminal(session.projectId, command: session.resumeId.map { "codex resume \($0)" } ?? "codex resume --last")
        default:
            openTerminal(session.projectId)
        }
    }

    /// Starts an agent with a prepared task in the project's terminal.
    func runAgent(_ projectId: String, prompt: String, agent: AgentKind = .claude) {
        let quoted = Shell.quote(prompt)
        openTerminal(projectId, command: agent == .codex ? "codex \(quoted)" : "claude \(quoted)")
    }

    func startWorkSession(_ projectId: String) {
        if let last = snapshots[projectId]?.sessions.first(where: { $0.agent == .claude || $0.agent == .codex }),
           last.status != .done {
            resume(last)
        } else {
            openTerminal(projectId, command: "claude")
        }
    }

    func runGit(_ label: String, _ work: @escaping @Sendable () -> ShellResult) {
        Task {
            let r = await Task.detached { work() }.value
            toast = r.ok ? label : "Ошибка: " + (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            await refresh()
        }
    }

    func fetchAll() {
        let paths = config.activeProjects.map(\.path)
        Task {
            isSyncing = true
            let failures = await Task.detached { paths.filter { !GitService.fetch($0).ok }.count }.value
            isSyncing = false
            toast = failures == 0 ? "Fetch выполнен для \(Plural.repos(paths.count))" : "Fetch: ошибок — \(failures)"
            await refresh()
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
