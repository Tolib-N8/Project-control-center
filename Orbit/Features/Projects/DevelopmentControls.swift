import SwiftUI

/// "Начать разработку" with a "Что открывать…" menu; turns into a live timer chip while the project is being worked on.
struct DevelopmentControls: View {
    @Environment(AppState.self) private var app
    var projectId: String
    var kind: OrbitButtonKind = .primary

    var body: some View {
        Group {
            if app.timerProjectId == projectId {
                TimerChip(projectId: projectId)
                    .transition(Motion.transition(Motion.pop))
            } else {
                HStack(spacing: 6) {
                    OrbitButton(tr("Начать разработку", "Start development"), icon: "play", kind: kind) {
                        app.startDevelopment(projectId)
                    }
                    MenuChip(icon: nil, title: "", kind: kind == .primary ? .primary : .secondary, chevron: true) {
                        Button(tr("Что открывать…", "What to open…")) { app.sheet = .launchSet(projectId: projectId) }
                        Button(tr("Только таймер", "Timer only")) { app.startTimer(projectId) }
                    }
                    .help(tr("Что открывать и запуск без приложений", "What to open, or start without apps"))
                }
                .transition(Motion.transition(Motion.pop))
            }
        }
        .animation(Motion.pick(Motion.snappy), value: app.timerProjectId)
    }
}

/// "● 1:12:05 · из 6 ч" with pause and stop.
struct TimerChip: View {
    @Environment(AppState.self) private var app
    var projectId: String

    var body: some View {
        let paused = app.timerPaused
        let planned = app.plannedToday(projectId)
        let color = Theme.projectColor(app.project(projectId)?.colorIndex ?? 0)
        HStack(spacing: 10) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(paused ? Theme.text3 : color)
                .symbolEffect(.pulse, options: .repeating, isActive: !paused && !Motion.reduced)
            Text(Duration.clock(app.timerElapsed))
                .monoFont(13.5, .semibold, color: paused ? Theme.text2 : Theme.text)
                .monospacedDigit()
                .contentTransition(.numericText())
            if planned > 0 {
                Text(tr("из \(Duration.hours(planned)) ч", "of \(Duration.hours(planned)) h")).uiFont(12, color: Theme.text3)
            }
            Rectangle().fill(Theme.border).frame(width: 1, height: 16)
            Button { paused ? app.resumeTimer() : app.pauseTimer() } label: {
                Icon(paused ? "play" : "pause", size: 11).foregroundStyle(Theme.text2).frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle2())
            .help(paused ? tr("Продолжить", "Resume") : tr("Пауза", "Pause"))
            Button { app.stopTimer() } label: {
                Icon("stop", size: 11).foregroundStyle(Theme.text2).frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle2())
            .help(tr("Стоп", "Stop"))
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .background(color.opacity(paused ? 0.05 : 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(paused ? 0.2 : 0.35)))
        .animation(Motion.pick(Motion.content), value: paused)
    }
}
