import AppKit

/// "Начать разработку": opens the project's apps and links, then runs the timer.
extension AppState {
    var timerProjectId: String? { worklog.current?.projectId }
    var timerPaused: Bool { worklog.current?.paused ?? false }
    var timerElapsed: TimeInterval { worklog.elapsed(at: timerNow) }

    /// Hours planned for the project today, from the week plan.
    func plannedToday(_ projectId: String) -> Double {
        currentPlan.blocks(on: Week.weekdayIndex(now)).filter { $0.projectId == projectId }.reduce(0) { $0 + $1.hours }
    }

    /// Hours worked on the project today, live while the timer runs.
    func workedToday(_ projectId: String) -> Double {
        Activity.hours(snapshots[projectId]?.sessions ?? [], timer: worklog.intervals.filter { $0.projectId == projectId },
                       on: timerNow, now: timerNow)
    }

    func saveWorklog() { Store.save(worklog, to: "worklog.json", pretty: false) }

    // MARK: - Start

    func startDevelopment(_ projectId: String) {
        guard let project = project(projectId) else { return }
        let items = LaunchSet.items(for: project).filter(\.enabled)
        let runningBefore = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let wantsDesktop = config.devNewDesktop && !items.isEmpty
        startTimer(projectId)
        Task {
            var desktop: SpaceManager.Desktop?
            if wantsDesktop {
                if SpaceManager.isTrusted {
                    desktop = await Task.detached { SpaceManager.createAndSwitch() }.value
                    if desktop == nil { toast = tr("Не получилось создать рабочий стол — открываю здесь", "Couldn’t create a desktop — opening here") }
                } else {
                    SpaceManager.requestTrust()
                    toast = tr("Разрешите Orbit «Универсальный доступ», чтобы открывать на новом рабочем столе", "Allow Orbit in Accessibility to open on a new desktop")
                }
            }
            var failed: [String] = []
            for item in items where !open(item, project: project) { failed.append(item.name) }
            if !failed.isEmpty {
                toast = tr("Не открылось: \(failed.joined(separator: ", "))", "Couldn’t open: \(failed.joined(separator: ", "))")
            }
            // Only apps Orbit actually launched are closed on stop; the terminal stays, an agent may still be working.
            let launched = items.compactMap { item -> String? in
                guard case .app(let path) = item.kind, let id = Bundle(path: path)?.bundleIdentifier, !runningBefore.contains(id) else { return nil }
                return id
            }
            guard worklog.current?.projectId == projectId else { return }
            worklog.current?.openedApps = launched
            worklog.current?.desktop = desktop
            saveWorklog()
        }
    }

    /// Opens one item; false when it can't be opened (the app was removed, the link is broken).
    @discardableResult
    func open(_ item: LaunchItem, project: ProjectConfig) -> Bool {
        switch item.kind {
        case .terminalAgent:
            startWorkSession(project.id)
            return true
        case .app(let path):
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let app = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            if item.opensFolder {
                NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: app, configuration: config)
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: config)
            }
            return true
        case .url(let s):
            guard let url = URL(string: s) else { return false }
            return NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Timer

    func startTimer(_ projectId: String) {
        let previous = worklog.current.flatMap { $0.projectId == projectId ? nil : $0 }
        withMotion { worklog.start(projectId, at: Date()) }
        timerChanged()
        if let previous { cleanUp(after: previous) }
    }

    func pauseTimer() {
        withMotion { worklog.pause(at: Date()) }
        timerChanged()
    }

    func resumeTimer() {
        withMotion { worklog.resume(at: Date()) }
        timerChanged()
    }

    func stopTimer() {
        guard let pid = timerProjectId, let session = worklog.current else { return }
        let total = withMotion { worklog.stop(at: Date()) } ?? 0
        timerChanged()
        toast = "\(projectName(pid)): \(Duration.text(minutes: max(1, Int(total / 60))))"
        cleanUp(after: session)
    }

    /// Quits what "Начать разработку" launched, then removes its desktop. Apps ask about unsaved work themselves.
    private func cleanUp(after session: WorkLog.Current) {
        let apps = config.devCloseOnStop ? session.openedApps ?? [] : []
        for id in apps {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
        }
        guard let desktop = session.desktop else { return }
        Task.detached {
            // Give the apps a moment to close so their windows don't hop to the next desktop.
            try? await Task.sleep(for: .seconds(apps.isEmpty ? 0.2 : 1.5))
            SpaceManager.remove(desktop)
        }
    }

    private func timerChanged() {
        timerNow = Date()
        saveWorklog()
        syncClock()
    }

    /// The second-by-second clock only runs while the timer does.
    func syncClock() {
        timerNow = Date()
        if worklog.isRunning {
            guard clockTimer == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.timerNow = Date() }
            }
            RunLoop.main.add(t, forMode: .common) // keeps ticking while a menu is open
            clockTimer = t
        } else {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    /// Called every minute: remembers that Orbit was alive, so a crash or quit doesn't count the night.
    func heartbeat() {
        guard worklog.isRunning else { return }
        worklog.lastBeat = Date()
        saveWorklog()
    }

    /// The timer pauses when the Mac goes to sleep.
    func observeSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.worklog.isRunning else { return }
                self.pauseTimer()
            }
        }
    }
}
