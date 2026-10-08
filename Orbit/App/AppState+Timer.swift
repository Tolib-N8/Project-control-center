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
        let sessionStart = worklog.current?.sessionStart
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
            // Activating an app that already has windows elsewhere can pull macOS to that desktop; come back.
            if let desktop, let id = desktop.spaceID {
                try? await Task.sleep(for: .seconds(1.5))
                if Spaces.active() != id { _ = await Task.detached { SpaceManager.switchTo(desktop) }.value }
            }
            // Without a desktop of its own, "Стоп" quits only the apps launched here.
            let launched = items.compactMap { item -> String? in
                guard case .app(let path) = item.kind, let id = Bundle(path: path)?.bundleIdentifier, !runningBefore.contains(id) else { return nil }
                return id
            }
            // Stopped (or switched) while the desktop was being set up: tidy up right away.
            guard worklog.current?.projectId == projectId, worklog.current?.sessionStart == sessionStart else {
                if let desktop { await clearDesktop(desktop, closeWindows: config.devCloseOnStop) }
                return
            }
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
            // Terminals always get a new window in the project folder, so it lands on the project's desktop.
            if item.opensFolder || LaunchSet.isTerminal(path) {
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
        guard let desktop = session.desktop else {
            // No desktop of its own: quit what "Начать разработку" launched, as before.
            guard config.devCloseOnStop else { return }
            for id in session.openedApps ?? [] {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
            }
            return
        }
        let closeWindows = config.devCloseOnStop
        Task { await clearDesktop(desktop, closeWindows: closeWindows) }
    }

    /// Closes every window on the project's desktop, quits apps left without windows anywhere, then removes the
    /// desktop. If an app asks to confirm, waits for you (up to 10 minutes) and removes the desktop afterwards.
    private func clearDesktop(_ desktop: SpaceManager.Desktop, closeWindows: Bool) async {
        #if DEBUG
        func trace(_ s: String) { print("[desktop] \(Date().timeIntervalSince1970) \(s)") }
        #else
        func trace(_ s: String) {}
        #endif
        trace("clear \(desktop) close=\(closeWindows)")
        // A 1.1.0 record knows the desktop only by title, which may now point at another desktop: never close windows then.
        guard closeWindows, desktop.spaceID != nil else {
            await Task.detached { SpaceManager.remove(desktop) }.value
            return
        }
        // Only ever touch windows after confirming, by id, that this is the project's desktop.
        guard await Task.detached(operation: { SpaceManager.switchTo(desktop) }).value else {
            if SpaceManager.exists(desktop) {
                toast = tr("Не удалось перейти на стол проекта — окна не тронуты", "Couldn’t reach the project desktop — windows left as they are")
            }
            return
        }
        trace("on desktop, active=\(Spaces.active() ?? 0)")
        try? await Task.sleep(for: .seconds(0.4))
        let windows = await Task.detached { DesktopCleaner.windowsOnCurrentDesktop() }.value
        trace("windows: \(windows.map(\.appName))")
        DesktopCleaner.close(windows)
        let pids = Set(windows.map(\.pid))
        let deadline = Date().addingTimeInterval(10 * 60)
        var asked = false
        while true {
            try? await Task.sleep(for: .seconds(asked ? 1 : 1.5))
            let open = windows.filter(DesktopCleaner.isOpen)
            trace("still open: \(open.map(\.appName))")
            DesktopCleaner.quitWindowless(pids.subtracting(open.map(\.pid)))
            if open.isEmpty { break }
            if !asked {
                asked = true
                let names = Array(Set(open.map(\.appName))).sorted()
                desktopCleanup = DesktopCleanup(desktop: desktop, apps: names)
                NSRunningApplication(processIdentifier: open[0].pid)?.activate()
                toast = tr("Подтвердите закрытие в \(names.joined(separator: ", ")) — стол уберётся сам",
                           "Confirm closing in \(names.joined(separator: ", ")) — the desktop goes away by itself")
            }
            // "Оставить стол" / "Убрать стол сейчас" end the wait.
            guard desktopCleanup?.desktop == desktop else { return }
            if Date() > deadline {
                desktopCleanup = nil
                return
            }
        }
        desktopCleanup = nil
        try? await Task.sleep(for: .seconds(0.5))
        let removed = await Task.detached { SpaceManager.remove(desktop) }.value
        trace("removed=\(removed) active=\(Spaces.active() ?? 0) ids=\(Spaces.ids())")
    }

    /// Stops waiting for confirmations and removes the desktop; windows left on it move next door.
    func removeDesktopNow() {
        guard let cleanup = desktopCleanup else { return }
        desktopCleanup = nil
        Task.detached { SpaceManager.remove(cleanup.desktop) }
    }

    func keepDesktop() {
        desktopCleanup = nil
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
