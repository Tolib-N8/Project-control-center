import SwiftUI

/// Menu bar title: "parking-main 1:12:05" while the timer runs, "⏸ 1:12" on pause, the Orbit mark otherwise.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let pid = app.timerProjectId {
            let clock = Duration.clock(app.timerElapsed)
            if app.timerPaused {
                Image(systemName: "pause.circle")
                Text(clock).monospacedDigit()
            } else {
                Image(systemName: "timer")
                Text("\(shortName(app.projectName(pid))) \(clock)").monospacedDigit()
            }
        } else {
            Image(systemName: app.activeSignals.isEmpty ? "circle.circle" : "circle.circle.fill")
        }
    }

    private func shortName(_ name: String) -> String {
        name.count > 16 ? String(name.prefix(15)) + "…" : name
    }
}

/// The panel under the menu bar item: the running timer with its controls, or today's focus to start.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = app.languageRevision
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let pid = app.timerProjectId { running(pid) } else { idle }
            }
            .padding(16)
            Rectangle().fill(Theme.border).frame(height: 1)
            footer.padding(6)
        }
        .frame(width: 300)
        .background(Theme.surface)
        .font(OrbitFont.ui(13))
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .animation(Motion.pick(Motion.snappy), value: app.timerProjectId)
        .animation(Motion.pick(Motion.content), value: app.timerPaused)
    }

    // MARK: - Running

    private func running(_ pid: String) -> some View {
        let paused = app.timerPaused
        let color = Theme.projectColor(app.project(pid)?.colorIndex ?? 0)
        let planned = app.plannedToday(pid)
        let worked = app.workedToday(pid)
        let open = TaskOrdering.open(app.tasks(for: pid))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProjectSquare(colorIndex: app.project(pid)?.colorIndex ?? 0)
                Text(app.projectName(pid)).monoFont(13.5, .semibold).lineLimit(1)
                Spacer()
                Text(paused ? tr("Пауза", "Paused") : tr("Идёт", "Running"))
                    .uiFont(11.5, .medium, color: paused ? Theme.text3 : color)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background((paused ? Theme.text3 : color).opacity(0.12), in: Capsule())
            }

            Text(Duration.clock(app.timerElapsed))
                .font(OrbitFont.mono(34, .medium))
                .monospacedDigit()
                .foregroundStyle(paused ? Theme.text2 : Theme.text)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 6) {
                if planned > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface2)
                            Capsule().fill(color).frame(width: geo.size.width * min(1, worked / planned))
                        }
                    }
                    .frame(height: 4)
                    Text(tr("Сегодня \(Duration.text(minutes: Int(worked * 60))) из \(Duration.hours(planned)) ч по плану",
                            "Today \(Duration.text(minutes: Int(worked * 60))) of \(Duration.hours(planned)) h planned"))
                        .uiFont(12, color: Theme.text2)
                } else {
                    Text(tr("Сегодня \(Duration.text(minutes: Int(worked * 60))) · в плане на сегодня проекта нет",
                            "Today \(Duration.text(minutes: Int(worked * 60))) · not in today's plan"))
                        .uiFont(12, color: Theme.text2)
                }
            }

            HStack(spacing: 8) {
                OrbitButton(paused ? tr("Продолжить", "Resume") : tr("Пауза", "Pause"), icon: paused ? "play" : "pause", kind: paused ? .primary : .secondary, compact: true) {
                    paused ? app.resumeTimer() : app.pauseTimer()
                }
                OrbitButton(tr("Стоп", "Stop"), icon: "stop", compact: true) { app.stopTimer() }
                Spacer()
                let others = app.config.activeProjects.filter { $0.id != pid }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { p in Button(p.name) { app.startTimer(p.id) } }
                    } label: {
                        Icon("arrow.left.arrow.right", size: 12)
                            .foregroundStyle(Theme.text2)
                            .frame(width: 30, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    }
                    .menuStyle(.button)
                    .buttonStyle(PlainButtonStyle2())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("Перенести таймер на другой проект", "Move the timer to another project"))
                }
            }

            if !open.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Задачи", "Tasks")).uiFont(12, .medium, color: Theme.text3)
                    ForEach(open.prefix(3)) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Button { withMotion { app.toggleTask(task.id) } } label: { TaskCheckbox(checked: task.done) }
                                .buttonStyle(PlainButtonStyle2())
                            Text(task.title).uiFont(12.5).lineLimit(2)
                        }
                    }
                    if open.count > 3 {
                        Text(tr("ещё \(open.count - 3)", "\(open.count - 3) more")).uiFont(12, color: Theme.text3)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Idle

    @ViewBuilder private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Фокус дня", "Today's focus")).uiFont(12, .medium, color: Theme.text3)
            if let focus = app.todayFocus {
                HStack(spacing: 8) {
                    ProjectSquare(colorIndex: app.project(focus.projectId)?.colorIndex ?? 0)
                    Text(app.projectName(focus.projectId)).monoFont(15, .semibold).lineLimit(1)
                    Spacer()
                    Text(tr("\(Duration.hours(focus.hours)) ч", "\(Duration.hours(focus.hours)) h")).uiFont(12.5, color: Theme.text2)
                }
                OrbitButton(tr("Начать разработку", "Start development"), icon: "play", kind: .primary) {
                    app.startDevelopment(focus.projectId)
                }
            } else {
                Text(tr("На сегодня ничего не запланировано", "Nothing planned for today")).uiFont(13, color: Theme.text2)
            }
            let others = app.config.activeProjects.filter { $0.id != app.todayFocus?.projectId }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { p in Button(p.name) { app.startDevelopment(p.id) } }
                } label: {
                    Text(tr("Начать другой проект…", "Start another project…")).uiFont(12.5, color: Theme.text2)
                }
                .menuStyle(.button)
                .buttonStyle(PlainButtonStyle2())
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow(tr("Открыть Orbit", "Open Orbit"), icon: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            let signals = app.activeSignals.count
            footerRow(signals == 0 ? tr("Сигналов нет", "No signals") : tr("Сигналы: \(signals)", "Signals: \(signals)"), icon: "bell",
                      tint: signals == 0 ? Theme.text2 : Theme.red) {
                app.screen = .signals
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            footerRow(tr("Выйти из Orbit", "Quit Orbit"), icon: "power") { NSApp.terminate(nil) }
        }
    }

    private func footerRow(_ title: String, icon: String, tint: Color = Theme.text2, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 12, weight: .regular).foregroundStyle(tint).frame(width: 16)
                Text(title).uiFont(13)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .hoverHighlight(.row, radius: 6)
        }
        .buttonStyle(PlainButtonStyle2())
    }
}
