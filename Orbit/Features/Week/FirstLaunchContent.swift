import SwiftUI

/// Week screen before any plan exists (design 11).
struct FirstLaunchContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Card(padding: 40) {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 16) {
                    IconBox(symbol: "sparkles", color: Theme.accent, size: 40)
                        .symbolEffect(.pulse, options: .repeating, isActive: app.lastSync == nil && !Motion.reduced)
                    Text(app.lastSync == nil ? tr("Orbit изучает ваши проекты", "Orbit is studying your projects") : tr("Проекты изучены — пора планировать", "Projects analyzed — time to plan"))
                        .contentTransition(.opacity)
                        .animation(Motion.pick(Motion.content), value: app.lastSync == nil)
                        .font(OrbitFont.ui(24, .semibold)).tracking(-0.4)
                    Text(intro)
                        .uiFont(14, color: Theme.text2).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        OrbitButton(tr("Составить план", "Make a plan"), icon: "calendar.badge.plus", kind: .primary) {
                            app.savePlan(app.makePlan(weekKey: app.displayWeekKey))
                        }
                        .disabled(app.lastSync == nil)
                        .opacity(app.lastSync == nil ? 0.5 : 1)
                        OrbitButton(tr("Распланировать вручную", "Plan manually"), icon: "hand.draw") {
                            app.sheet = .planner(weekKey: app.displayWeekKey)
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                analysisProgress.frame(width: 440)
            }
        }

        WeekStrip(minHeight: 230).appearStagger(1)

        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.text3)
            Text(tr("План появится после анализа — или перетащите проекты из сайдбара на нужные дни", "The plan appears after analysis — or drag projects from the sidebar onto days")).uiFont(12.5, color: Theme.text3)
        }
        .frame(maxWidth: .infinity)

        HStack(alignment: .top, spacing: 20) {
            infoCard("sun.max", tr("Утренняя сводка", "Morning brief"), tr("Каждое утро — проект дня, на чём остановился агент и что делать первым.", "Every morning: the project of the day, where the agent stopped and what to do first.")).appearStagger(2)
            infoCard("bell", tr("Сигналы", "Signals"), tr("Orbit заметит отставшие ветки, незакоммиченные файлы и зациклившихся агентов.", "Orbit spots stale branches, uncommitted files and agents going in circles.")).appearStagger(3)
            infoCard("brain", tr("Контекст для агентов", "Context for agents"), tr("«Продолжить с контекстом» возобновит прошлую сессию — агенту не придётся разбираться заново.", "“Continue with context” resumes the previous session — the agent won’t have to start from scratch.")).appearStagger(4)
        }
    }

    private var intro: String {
        let sessions = app.sessions.count
        if app.lastSync == nil {
            return tr("Читаем логи сессий агентов и историю git, чтобы оценить состояние каждого проекта. Это займёт пару минут — потом Orbit предложит план на неделю.", "Reading agent session logs and git history to assess each project. This takes a couple of minutes — then Orbit will suggest a plan for the week.")
        }
        let target = app.displayWeekKey == app.currentWeekKey ? tr("оставшиеся \(app.remainingCapacity) ч этой недели", "the remaining \(app.remainingCapacity) h of this week") : tr("\(app.config.rhythm.weeklyHours) ч следующей недели", "\(app.config.rhythm.weeklyHours) h of next week")
        return tr("Прочитано \(Plural.sessions(sessions)) и история git по \(Plural.repos(app.config.activeProjects.count)). Orbit может распределить \(target) по здоровью проектов.", "Read \(Plural.sessions(sessions)) and the git history of \(Plural.repos(app.config.activeProjects.count)). Orbit can spread \(target) across projects by health.")
    }

    private var analysisProgress: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Прогресс анализа", "Analysis progress")).uiFont(13, .semibold, color: Theme.text2)
                Spacer()
                Text("\(Int(overall * 100))%").monoFont(12.5, color: Theme.accent).numericTransition(Int(overall * 100))
            }
            .padding(.bottom, 12)
            .hairline()
            ForEach(app.config.activeProjects) { p in
                let prog = app.progress[p.id] ?? ProjectProgress()
                HStack(spacing: 12) {
                    Image(systemName: prog.phase == .done ? "checkmark.circle" : prog.phase == .running ? "circle.dashed" : "circle.dotted")
                        .foregroundStyle(prog.phase == .done ? Theme.green : prog.phase == .running ? Theme.accent : Theme.text3)
                        .contentTransition(.symbolEffect(.replace))
                    ProjectSquare(colorIndex: p.colorIndex)
                    Text(p.name).monoFont(13, color: prog.phase == .queued ? Theme.text3 : Theme.text).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    ProgressLine(fraction: prog.phase == .done ? Double(app.health[p.id] ?? 0) / 100 : prog.phase == .running ? app.analysisFraction * 0.8 : 0,
                                 color: prog.phase == .done ? Theme.healthColor(app.health[p.id] ?? 0) : Theme.accent)
                    Text(prog.detail).uiFont(12.5, color: prog.phase == .done ? Theme.text : Theme.text3)
                        .contentTransition(.opacity)
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.vertical, 12)
                .hairline()
                .animation(Motion.pick(Motion.content), value: prog)
            }
        }
    }

    private var overall: Double {
        let ps = app.config.activeProjects
        guard !ps.isEmpty else { return 1 }
        let done = ps.filter { app.progress[$0.id]?.phase == .done }.count
        return app.lastSync != nil ? 1 : (Double(done) + app.analysisFraction * Double(ps.count - done) * 0.9) / Double(ps.count)
    }

    private func infoCard(_ icon: String, _ title: String, _ text: String) -> some View {
        Card(padding: 24) {
            HStack(alignment: .top, spacing: 16) {
                IconBox(symbol: icon, color: Theme.text2, size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).uiFont(14, .semibold)
                    Text(text).uiFont(13, color: Theme.text2).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
