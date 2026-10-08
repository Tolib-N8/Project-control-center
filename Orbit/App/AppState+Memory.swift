import AppKit

/// Project memory: what a fresh Claude Code or Codex session should know, written into the repository.
extension AppState {
    func memoryEnabled(_ projectId: String) -> Bool { (project(projectId)?.memory ?? true) && memoryWritesAllowed }

    /// Snapshot runs and unit tests use the real project paths: they never write memory there
    /// (a snapshot run may write into a scratch folder with `--memory-out`).
    var memoryWritesAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let args = ProcessInfo.processInfo.arguments
        return !args.contains("--snapshot") || args.contains("--memory-out")
        #else
        return true
        #endif
    }

    func saveMemoryState() { Store.save(memoryRecords, to: "memory-state.json", pretty: false) }

    /// Where the files go: the repository, or `--memory-out <dir>/<project>` while debugging.
    func memoryTarget(_ projectId: String) -> (root: String, gitRepo: String?) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--memory-out"), i + 1 < args.count {
            return ((args[i + 1] as NSString).appendingPathComponent(projectName(projectId)), nil)
        }
        #endif
        return (project(projectId)?.path ?? projectId, project(projectId)?.path ?? projectId)
    }

    func memoryFilePath(_ projectId: String) -> String {
        (memoryTarget(projectId).root as NSString).appendingPathComponent(MemoryWriter.memoryPath)
    }

    /// The newest finished agent session is newer than the memory.
    func memoryIsStale(_ projectId: String) -> Bool {
        guard let newest = snapshots[projectId]?.sessions.first(where: { $0.status != .active }) else { return memoryRecords[projectId] == nil }
        guard let record = memoryRecords[projectId] else { return true }
        return newest.end > record.updatedAt
    }

    /// After every refresh: projects with a session finished since the last memory get a new one (at most every 10 min).
    func refreshMemoriesAfterSync() {
        let due = config.activeProjects.map(\.id).filter { id in
            guard memoryEnabled(id), memoryIsStale(id), !memoryBusy.contains(id), snapshots[id]?.sessions.isEmpty == false else { return false }
            if let record = memoryRecords[id], Date().timeIntervalSince(record.updatedAt) < 10 * 60 { return false }
            return true
        }
        guard !due.isEmpty else { return }
        // One project at a time, so a first run over every project doesn't hit the model all at once.
        Task { for id in due { await refreshMemory(id) } }
    }

    /// Before an agent starts: if the memory is behind, write the quick version now; the AI one follows.
    func ensureFreshMemory(_ projectId: String) {
        guard memoryEnabled(projectId), memoryIsStale(projectId), snapshots[projectId] != nil else { return }
        writeHeuristicMemory(projectId)
        Task { await refreshMemory(projectId, force: true) }
    }

    /// Asks the chosen model (heuristics without one or on failure) and writes the files.
    func refreshMemory(_ projectId: String, force: Bool = false) async {
        guard memoryEnabled(projectId), let snap = snapshots[projectId], !memoryBusy.contains(projectId) else { return }
        let facts = AnalysisService.memoryFacts(snap, health: health[projectId] ?? 0, openTasks: TaskOrdering.open(tasks(for: projectId)),
                                                planned: plannedDays(projectId), previous: memoryRecords[projectId]?.memory)
        let (request, hash) = AnalysisService.memoryRequest(facts)
        if !force, let record = memoryRecords[projectId], record.inputHash == hash { return }
        guard let provider = try? AIProviders.make(config.ai) else {
            writeHeuristicMemory(projectId, hash: hash)
            return
        }
        memoryBusy.insert(projectId)
        defer { memoryBusy.remove(projectId) }
        do {
            let memory = try AnalysisService.parseMemory(try await provider.complete(request))
            try await write(memory, projectId: projectId, source: provider.label, hash: hash)
        } catch {
            aiError = error.localizedDescription
            writeHeuristicMemory(projectId, hash: hash)
        }
    }

    func writeHeuristicMemory(_ projectId: String, hash: String = "") {
        guard let snap = snapshots[projectId] else { return }
        let memory = MemoryHeuristics.build(snap, openTasks: TaskOrdering.open(tasks(for: projectId)), health: health[projectId] ?? 0)
        Task { try? await write(memory, projectId: projectId, source: tr("эвристики", "heuristics"), hash: hash) }
    }

    private func write(_ raw: ProjectMemory, projectId: String, source: String, hash: String) async throws {
        let memory = raw.redacted()
        let sessions = min(snapshots[projectId]?.sessions.count ?? 0, 12)
        let markdown = MemoryMarkdown.render(memory, project: projectName(projectId), updated: Date(), source: source, sessions: sessions)
        let target = memoryTarget(projectId)
        try await Task.detached { try MemoryWriter.write(markdown, to: target.root, gitRepo: target.gitRepo) }.value
        memoryRecords[projectId] = MemoryRecord(memory: memory, updatedAt: Date(), source: source, sessions: sessions,
                                                inputHash: hash, lang: L10n.current.rawValue)
        saveMemoryState()
    }

    func setMemoryEnabled(_ projectId: String, _ on: Bool) {
        updateProject(projectId) { $0.memory = on }
        if on {
            Task { await refreshMemory(projectId, force: true) }
        } else {
            let root = memoryTarget(projectId).root
            try? MemoryWriter.remove(from: root)
            memoryRecords[projectId] = nil
            saveMemoryState()
        }
    }

    /// "Ср, 8 окт: 6 ч" for the project over the next week.
    func plannedDays(_ projectId: String) -> [String] {
        let today = Week.calendar.startOfDay(for: now)
        return [currentPlan, plan(nextWeekKey)].flatMap { plan -> [String] in
            guard let monday = Week.date(fromKey: plan.weekKey) else { return [] }
            return plan.blocks.filter { $0.projectId == projectId }.compactMap { block in
                let date = Week.day(block.day, of: monday)
                guard date >= today, date < today.addingTimeInterval(8 * 86400) else { return nil }
                return "\(DateFormat.weekdayShort(date)): \(Duration.hours(block.hours)) \(Duration.h)"
            }
        }
    }
}
