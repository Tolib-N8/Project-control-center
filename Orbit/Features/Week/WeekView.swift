import SwiftUI

struct WeekView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Page {
            header
            if app.plan(app.displayWeekKey).blocks.isEmpty {
                FirstLaunchContent()
            } else {
                HStack(alignment: .top, spacing: 20) {
                    TodayFocusCard().appearStagger(0)
                    AttentionCard().frame(width: 300).appearStagger(1)
                }
                .fixedSize(horizontal: false, vertical: true)
                WeekStrip().appearStagger(2)
                ProjectsTable().appearStagger(3)
            }
        }
    }

    private var header: some View {
        let key = app.displayWeekKey
        let monday = Week.date(fromKey: key) ?? app.currentMonday
        let sunday = Week.day(6, of: monday)
        let title = DateFormat.weekdayFull.string(from: app.now).capitalizedFirst + ", " + DateFormat.dayMonthFull.string(from: app.now)
        let next = key != app.currentWeekKey ? tr(" · следующая неделя", " · next week") : ""
        return PageHeader(eyebrow: tr("Неделя \(Week.number(monday)) · \(DateFormat.short(monday)) — \(DateFormat.short(sunday))\(next)", "Week \(Week.number(monday)) · \(DateFormat.short(monday)) — \(DateFormat.short(sunday))\(next)"), title: title) {
            if !app.plan(key).blocks.isEmpty {
                OrbitButton(app.isSyncing || !app.aiBusy.isEmpty ? tr("Анализ…", "Analyzing…") : tr("Проанализировать", "Analyze"), icon: "arrow.clockwise") {
                    app.analyzeNow()
                }
            }
            OrbitButton(tr("Запланировать", "Plan"), icon: "calendar.badge.plus", kind: .primary) {
                app.sheet = .planner(weekKey: key)
            }
        }
    }
}

// MARK: - Today focus

struct TodayFocusCard: View {
    @Environment(AppState.self) private var app
    @State private var goal = ""
    @FocusState private var goalFocused: Bool

    var body: some View {
        let block = app.todayFocus
        let pid = block?.projectId ?? recommendedProject
        Card(padding: 24) {
            if let pid, let snap = app.snapshots[pid] {
                content(snap, block: block)
            } else {
                EmptyHint(symbol: "cup.and.saucer", title: tr("На сегодня ничего не запланировано", "Nothing planned for today"),
                          text: tr("Перетащите проект из сайдбара на сегодняшний день или откройте планировщик.", "Drag a project from the sidebar onto today or open the planner."))
            }
        }
    }

    /// When nothing is planned today, suggest the project that needs attention most.
    private var recommendedProject: String? {
        app.activeSnapshots.min { (app.health[$0.config.id] ?? 100) < (app.health[$1.config.id] ?? 100) }?.config.id
    }

    @ViewBuilder
    private func content(_ snap: ProjectSnapshot, block: PlanBlock?) -> some View {
        let pid = snap.config.id
        let score = app.health[pid] ?? 0
        let trend = (app.healthHistory[pid]?.last ?? 0) - (app.healthHistory[pid]?.dropLast(7).last ?? app.healthHistory[pid]?.first ?? 0)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProjectSquare(colorIndex: snap.config.colorIndex)
                        Eyebrow(text: block.map { tr("Сегодня в фокусе · \(timeRange($0))", "Today’s focus · \(timeRange($0))") } ?? tr("Рекомендуем сегодня", "Suggested for today"))
                    }
                    Button { app.screen = .project(pid) } label: {
                        Text(snap.config.name).font(OrbitFont.mono(30, .semibold)).tracking(-0.6).foregroundStyle(Theme.text)
                    }
                    .buttonStyle(PlainButtonStyle2())
                    goalField(block)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(score)").font(OrbitFont.ui(40, .semibold)).tracking(-1).foregroundStyle(Theme.healthColor(score))
                            .numericTransition(score)
                        Text("/100").uiFont(14, color: Theme.text3)
                    }
                    Text(tr("Здоровье проекта", "Project health") + (trend == 0 ? "" : trend > 0 ? " ↑ \(trend)" : " ↓ \(-trend)")).uiFont(12, color: Theme.text2)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                lastSessionPanel(snap)
                gitPanel(snap)
                nextStepsPanel(snap)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                DevelopmentControls(projectId: pid, kind: .light)
                OrbitButton(tr("Открыть в терминале", "Open in Terminal"), icon: "terminal") { app.openTerminal(pid) }
                Spacer()
                let n = snap.sessions.count
                Text(n == 0 ? tr("Сессий агентов пока нет", "No agent sessions yet") : tr("Контекст собран из \(n) \(Plural.ru(n, "сессии", "сессий", "сессий"))", "Context from \(Plural.sessions(n))")).uiFont(12, color: Theme.text3)
            }
        }
    }

    @ViewBuilder
    private func goalField(_ block: PlanBlock?) -> some View {
        if let block {
            let suggestion = app.projectAI(block.projectId)?.goal ?? ""
            TextField("", text: $goal, prompt: Text(suggestion.isEmpty ? tr("Цель дня: добавьте, что нужно сделать…", "Goal for the day: add what needs doing…") : tr("Цель дня: \(suggestion)", "Goal for the day: \(suggestion)")).foregroundStyle(Theme.text3))
                .textFieldStyle(.plain)
                .font(OrbitFont.ui(14))
                .foregroundStyle(Theme.text2)
                .focused($goalFocused)
                .onAppear { goal = block.goal.map { tr("Цель дня: ", "Goal for the day: ") + $0 } ?? "" }
                .onChange(of: block.id) { goal = block.goal.map { tr("Цель дня: ", "Goal for the day: ") + $0 } ?? "" }
                .onSubmit { saveGoal(block) }
                .onChange(of: goalFocused) { if !goalFocused { saveGoal(block) } }
        } else {
            Text(tr("Сегодня нет блока в плане — проект с самым низким здоровьем.", "No block planned today — this is the project with the lowest health.")).uiFont(14, color: Theme.text2)
        }
    }

    private func saveGoal(_ block: PlanBlock) {
        var text = goal.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(tr("Цель дня:", "Goal for the day:")) { text = String(text.dropFirst(tr("Цель дня:", "Goal for the day:").count)).trimmingCharacters(in: .whitespaces) }
        app.updateBlock(block.id) { $0.goal = text.isEmpty ? nil : text }
        goal = text.isEmpty ? "" : tr("Цель дня: ", "Goal for the day: ") + text
    }

    private func timeRange(_ b: PlanBlock) -> String {
        let start = b.startHour ?? Double(app.config.rhythm.dayStartHour)
        return "\(hourText(start)) — \(hourText(start + b.hours))"
    }

    private func panelHeading(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Text(title).uiFont(12, .medium, color: Theme.text2)
        }
    }

    private func lastSessionPanel(_ snap: ProjectSnapshot) -> some View {
        InnerPanel {
            VStack(alignment: .leading, spacing: 12) {
                panelHeading("cpu", tr("Последняя сессия агента", "Last agent session"))
                if let s = snap.sessions.first {
                    HStack(spacing: 8) {
                        AgentTag(agent: s.agent)
                        Text("\(DateFormat.relativeDay(s.end, withTime: false)) · \(Duration.text(minutes: s.durationMinutes))").uiFont(12, color: Theme.text3)
                    }
                    Text(InsightEngine.sessionSummary(s, limit: 200))
                        .font(OrbitFont.ui(13)).lineSpacing(4).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tr("Сессий агентов пока нет", "No agent sessions yet")).uiFont(13, color: Theme.text3)
                }
            }
        }
    }

    private func gitPanel(_ snap: ProjectSnapshot) -> some View {
        let r = snap.repo
        return InnerPanel {
            VStack(alignment: .leading, spacing: 12) {
                panelHeading("arrow.triangle.branch", tr("Состояние Git", "Git status"))
                KeyValueRow(key: tr("Ветка", "Branch"), value: r.branch)
                KeyValueRow(key: tr("Не закоммичено", "Uncommitted"), value: r.changes.isEmpty ? tr("чисто", "clean") : Plural.files(r.changes.count),
                            color: r.changes.isEmpty ? Theme.text : Theme.yellow)
                if r.upstream != nil {
                    KeyValueRow(key: r.behind > 0 ? tr("Позади origin", "Behind origin") : tr("Впереди origin", "Ahead of origin"),
                                value: Plural.commits(r.behind > 0 ? r.behind : r.ahead))
                } else {
                    KeyValueRow(key: "Origin", value: tr("не настроен", "not set up"), color: Theme.text3)
                }
                if let total = snap.testsTotal {
                    KeyValueRow(key: tr("Тесты", "Tests"), value: snap.testsFailing > 0 ? tr("\(Plural.tests(snap.testsFailing)) падают", "\(Plural.tests(snap.testsFailing)) failing") : "\(total) ✓",
                                color: snap.testsFailing > 0 ? Theme.red : Theme.green)
                } else if r.behindMain > 0 {
                    KeyValueRow(key: tr("Позади main", "Behind main"), value: Plural.commits(r.behindMain), color: r.behindMain >= 20 ? Theme.red : Theme.text)
                }
            }
        }
    }

    private func nextStepsPanel(_ snap: ProjectSnapshot) -> some View {
        InnerPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    panelHeading("checklist", app.projectAI(snap.config.id) != nil ? tr("Следующие шаги от ИИ", "Next steps from AI") : tr("Следующие шаги", "Next steps"))
                    Spacer()
                    if app.aiBusy.contains("project:" + snap.config.id) { ProgressView().controlSize(.mini) }
                }
                ForEach(Array(app.nextSteps(snap).enumerated()), id: \.element) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: i == 0 ? "smallcircle.filled.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(i == 0 ? Theme.accent : Theme.text3)
                        Text(step).uiFont(13).fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(Motion.transition(Motion.rise))
                }
            }
            .animation(Motion.pick(Motion.content), value: app.nextSteps(snap))
        }
    }
}

func hourText(_ h: Double) -> String {
    String(format: "%02d:%02d", Int(h) % 24, Int((h - floor(h)) * 60))
}

// MARK: - Attention

struct AttentionCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let signals = Array(app.activeSignals.prefix(3))
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tr("Требует внимания", "Needs attention")).uiFont(13.5, .semibold)
                    Spacer()
                    Text("\(app.activeSignals.count)").uiFont(12, color: Theme.text3)
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 16)
                .hairline()
                .padding(.horizontal, 0)

                if signals.isEmpty {
                    EmptyHint(symbol: "checkmark.shield", title: tr("Всё спокойно", "All quiet"), text: tr("Ветки свежие, изменения закоммичены, агенты не буксуют.", "Branches are fresh, changes are committed, agents aren’t stuck."))
                        .padding(.top, 24)
                } else {
                    ForEach(Array(signals.enumerated()), id: \.element.id) { i, s in
                        Button { app.screen = .signals } label: { row(s).hoverHighlight() }
                            .buttonStyle(PlainButtonStyle2())
                            .transition(Motion.transition(Motion.rise))
                        if i < signals.count - 1 { Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 20) }
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(Motion.pick(Motion.snappy), value: signals.map(\.id))
        }
    }

    private func row(_ s: Signal) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBox(symbol: s.kind.symbol, color: s.severity == .critical ? Theme.red : Theme.yellow, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.projectName(s.projectId)).monoFont(11.5, color: Theme.text3)
                Text(s.title).uiFont(13, .medium).fixedSize(horizontal: false, vertical: true)
                Text(s.metrics.prefix(2).map { "\($0.label) \($0.value)" }.joined(separator: " · "))
                    .uiFont(12, color: Theme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Week strip

struct WeekStrip: View {
    @Environment(AppState.self) private var app
    @Namespace private var blocksSpace
    var weekKey: String?
    var minHeight: CGFloat = 196

    var body: some View {
        let key = weekKey ?? app.displayWeekKey
        let plan = app.plan(key)
        let monday = Week.date(fromKey: key) ?? app.currentMonday
        let today = key == app.currentWeekKey ? Week.weekdayIndex(app.now) : -1
        let worked = (0..<(today + 1)).reduce(0.0) { sum, d in
            sum + plan.blocks(on: d).reduce(0) { $0 + app.actualHours($1.projectId, on: Week.day(d, of: monday)) }
        }
        let projectsCount = Set(plan.blocks.map(\.projectId)).count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tr("План недели", "Week plan")).uiFont(16, .semibold)
                Text(plan.blocks.isEmpty
                     ? tr("0 из \(app.config.rhythm.weeklyHours) ч · проекты не назначены", "0 of \(app.config.rhythm.weeklyHours) h · no projects assigned")
                     : tr("\(Duration.hours(worked)) из \(Duration.hours(plan.totalHours)) ч отработано · \(Plural.projects(projectsCount))", "\(Duration.hours(worked)) of \(Duration.hours(plan.totalHours)) h worked · \(Plural.projects(projectsCount))"))
                    .uiFont(12.5, color: Theme.text3)
                Spacer()
                HStack(spacing: 16) {
                    legend(filled: true, tr("Сделано", "Done"))
                    legend(filled: false, tr("Запланировано", "Planned"))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<7, id: \.self) { d in
                    DayColumn(day: d, date: Week.day(d, of: monday), blocks: plan.blocks(on: d),
                              isToday: key == app.currentWeekKey && d == today,
                              isPast: key == app.currentWeekKey && d < today,
                              capacity: app.config.rhythm.hours[d], weekKey: key, space: blocksSpace)
                        .frame(minHeight: minHeight, alignment: .top)
                        .appearStagger(d)
                }
            }
            .animation(Motion.pick(Motion.snappy), value: plan)
        }
    }

    private func legend(filled: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(filled ? Theme.text2 : .clear)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.text2, lineWidth: 1))
                .frame(width: 11, height: 11)
            Text(text).uiFont(12.5, color: Theme.text2)
        }
    }
}

struct DayColumn: View {
    @Environment(AppState.self) private var app
    var day: Int
    var date: Date
    var blocks: [PlanBlock]
    var isToday: Bool
    var isPast: Bool
    var capacity: Int
    var weekKey: String
    var space: Namespace.ID
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Week.shortNames[day]).uiFont(12.5, .medium, color: isToday ? Theme.accent : Theme.text2)
                Spacer()
                Text("\(Week.calendar.component(.day, from: date))")
                    .uiFont(16, .medium, color: isPast && blocks.isEmpty ? Theme.text3 : Theme.text)
            }
            ForEach(blocks) { b in
                BlockChip(block: b, date: date, isPast: isPast, isToday: isToday, weekKey: weekKey)
                    .matchedGeometryEffect(id: b.id, in: space)
                    .transition(Motion.transition(Motion.pop))
            }

            if blocks.isEmpty && capacity == 0 {
                Spacer(minLength: 40)
                VStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer").foregroundStyle(Theme.text3)
                    Text(tr("Выходной", "Day off")).uiFont(12.5, color: Theme.text3)
                }
                .frame(maxWidth: .infinity)
            } else if !isPast {
                addMenu
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isToday ? Theme.accent.opacity(0.7) : dropTargeted ? Theme.text2 : Theme.border, lineWidth: isToday ? 1.5 : 1))
        .background(Theme.accent.opacity(dropTargeted ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10))
        .scaleEffect(dropTargeted && !Motion.reduced ? 1.015 : 1)
        .dropDestination(for: PlanDragItem.self) { items, _ in
            for item in items { app.addBlock(projectId: item.projectId, day: day, weekKey: weekKey) }
            return !items.isEmpty
        } isTargeted: { t in withMotion { dropTargeted = t } }
    }

    private var addMenu: some View {
        Menu {
            ForEach(app.config.activeProjects) { p in
                Button(p.name) { app.addBlock(projectId: p.id, day: day, weekKey: weekKey) }
            }
        } label: {
            HStack(spacing: 6) {
                Icon("plus", size: 11)
                Text(tr("Проект", "Project"))
            }
        }
        .menuStyle(.button)
        .buttonStyle(PlainButtonStyle2())
        .menuIndicator(.hidden)
        .fixedSize()
        .font(OrbitFont.ui(12.5))
        .tint(Theme.text3)
        .foregroundStyle(Theme.text3)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1)))
    }
}

struct BlockChip: View {
    @Environment(AppState.self) private var app
    var block: PlanBlock
    var date: Date
    var isPast: Bool
    var isToday: Bool
    var weekKey: String

    var body: some View {
        let color = Theme.projectColor(app.colorIndex(block.projectId))
        let actual = app.actualHours(block.projectId, on: date)
        let mainHours = isPast || (isToday && actual > 0) ? actual : block.hours
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(app.projectName(block.projectId)).monoFont(12.5, .medium).lineLimit(1)
                Spacer(minLength: 4)
                Text(tr("\(Duration.hours(mainHours))ч", "\(Duration.hours(mainHours))h")).monoFont(12, .medium, color: color)
            }
            Text(subtitle(actual: actual)).uiFont(11.5, color: isPast ? Theme.text3 : subtitleColor).lineLimit(1)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(isPast ? 0.10 : 0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(color).frame(width: 2)
        }
        .onTapGesture { app.screen = .project(block.projectId) }
        .contextMenu {
            Button(tr("+1 час", "+1 hour")) { app.updateBlock(block.id, weekKey: weekKey) { $0.hours += 1 } }
            Button(tr("−1 час", "−1 hour")) { app.updateBlock(block.id, weekKey: weekKey) { $0.hours -= 1 } }
            Menu(tr("Перенести на", "Move to")) {
                ForEach(0..<7, id: \.self) { d in
                    Button(Week.shortNames[d]) { app.updateBlock(block.id, weekKey: weekKey) { $0.day = d } }
                }
            }
            Divider()
            Button(tr("Убрать из плана", "Remove from plan"), role: .destructive) { app.removeBlock(block.id, weekKey: weekKey) }
        }
    }

    private var subtitleColor: Color {
        let snap = app.snapshots[block.projectId]
        let urgent = app.activeSignals.contains { $0.projectId == block.projectId && $0.severity == .critical }
        return urgent ? Theme.red : (snap == nil ? Theme.text3 : Theme.text2)
    }

    private func subtitle(actual: Double) -> String {
        if isPast { return tr("план \(Duration.hours(block.hours))ч", "plan \(Duration.hours(block.hours))h") }
        if isToday {
            let start = block.startHour ?? Double(app.config.rhythm.dayStartHour)
            return "\(hourText(start)) — \(hourText(start + block.hours))"
        }
        if let goal = block.goal { return goal }
        if let snap = app.snapshots[block.projectId] {
            return InsightEngine.plannerNote(snap, signals: app.activeSignals.filter { $0.projectId == block.projectId })
        }
        return tr("план \(Duration.hours(block.hours))ч", "plan \(Duration.hours(block.hours))h")
    }
}

// MARK: - Projects table

struct ProjectsTable: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let rows = app.activeSnapshots.sorted { (app.health[$0.config.id] ?? 0) > (app.health[$1.config.id] ?? 0) }
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                col(tr("Проект", "Project"), width: 170)
                col(app.aiLabel != nil ? tr("Вывод ИИ по сессиям", "AI take on sessions") : tr("Вывод по сессиям", "Session summary"), flex: true)
                col("Git", width: 160)
                col(tr("Сессии / 7 дн.", "Sessions / 7 d"), width: 110)
                col(tr("Здоровье", "Health"), width: 100)
                col(tr("В плане", "Planned"), width: 100)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .hairline()

            ForEach(Array(rows.enumerated()), id: \.element.config.id) { i, snap in
                Button { app.screen = .project(snap.config.id) } label: { row(snap).hoverHighlight() }
                    .buttonStyle(PlainButtonStyle2())
                    .appearStagger(i + 4)
                if i < rows.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .cardStyle()
    }

    private func col(_ title: String, width: CGFloat? = nil, flex: Bool = false) -> some View {
        Eyebrow(text: title)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: flex ? .infinity : nil, alignment: .leading)
    }

    private func row(_ snap: ProjectSnapshot) -> some View {
        let pid = snap.config.id
        let score = app.health[pid] ?? 0
        let r = snap.repo
        let gitExtra: (String, Color) = r.behindMain >= 10 ? ("−\(r.behindMain)", Theme.red)
            : r.changes.isEmpty && r.ahead == 0 ? (tr("чисто", "clean"), Theme.text2)
            : r.ahead > 0 ? ("+\(r.ahead)", Theme.text2) : (tr("\(r.changes.count) изм.", "\(r.changes.count) changed"), Theme.yellow)
        let week = snap.sessions(in: 7).count
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                ProjectSquare(colorIndex: snap.config.colorIndex)
                Text(snap.config.name).monoFont(13, .medium).lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            Text(app.headline(snap)).uiFont(13).lineLimit(1)
                .contentTransition(.opacity)
                .animation(Motion.pick(Motion.content), value: app.headline(snap))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(r.branch).lineLimit(1)
                Text("·")
                Text(gitExtra.0).foregroundStyle(gitExtra.1)
            }
            .font(OrbitFont.mono(12.5))
            .foregroundStyle(r.behindMain >= 10 ? Theme.red : Theme.text2)
            .frame(width: 160, alignment: .leading)
            Text(Plural.sessions(week)).uiFont(13, color: Theme.text2).frame(width: 110, alignment: .leading)
            HStack(spacing: 12) {
                HealthBar(score: score).frame(width: 56)
                Text("\(score)").uiFont(13, .semibold, color: Theme.healthColor(score)).numericTransition(score)
            }
            .frame(width: 100, alignment: .leading)
            plannedText(pid).frame(width: 100, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }

    private func plannedText(_ pid: String) -> some View {
        let today = Week.weekdayIndex(app.now)
        let plan = app.currentPlan
        if plan.blocks(on: today).contains(where: { $0.projectId == pid }) {
            return Text(tr("Сегодня", "Today")).uiFont(13, .medium, color: Theme.accent)
        }
        if let d = plan.blocks.filter({ $0.projectId == pid && $0.day > today }).map(\.day).min() {
            return Text(DateFormat.weekdayShort(Week.day(d, of: app.currentMonday))).uiFont(13, color: Theme.text2)
        }
        let nextMonday = Week.day(7, of: app.currentMonday)
        if let d = app.plan(Week.key(nextMonday)).blocks.filter({ $0.projectId == pid }).map(\.day).min() {
            return Text(DateFormat.weekdayShort(Week.day(d, of: nextMonday))).uiFont(13, color: Theme.text2)
        }
        return Text("—").uiFont(13, color: Theme.text3)
    }
}
