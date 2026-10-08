import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) private var app
    var projectId: String
    @State private var agentFilter: AgentKind?

    var body: some View {
        if let snap = app.snapshots[projectId] {
            Page {
                header(snap)
                StatTilesRow(snap: snap, score: app.health[projectId] ?? 0, history: app.healthHistory[projectId] ?? [])
                    .appearStagger(0)
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 28) {
                        sessionsPanel(snap)
                        WorkDaysPanel(snap: snap)
                    }
                    .appearStagger(1)
                    VStack(spacing: 28) {
                        TasksPanel(projectId: projectId)
                        GitPanel(snap: snap)
                        MemoryPanel(projectId: projectId)
                    }
                    .frame(width: 380)
                    .appearStagger(2)
                }
            }
        } else {
            Page { EmptyHint(symbol: "folder", title: tr("Проект не найден", "Project not found"), text: tr("Возможно, он был отключён.", "It may have been removed.")) }
        }
    }

    private func header(_ snap: ProjectSnapshot) -> some View {
        let score = app.health[projectId] ?? 0
        let days = snap.config.workDays.sorted().map { Week.shortNames[$0] }.joined(separator: " · ")
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(tr("Проекты", "Projects")) { app.screen = .projects }.buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(12.5)).foregroundStyle(Theme.text3)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.text3)
                    Text(snap.config.displayPath).monoFont(12.5, color: Theme.text3)
                }
                HStack(spacing: 14) {
                    ProjectSquare(colorIndex: snap.config.colorIndex, size: 14)
                    Text(snap.config.name).font(OrbitFont.mono(30, .semibold)).tracking(-0.6)
                    HStack(spacing: 6) {
                        Dot(color: Theme.healthColor(score))
                        Text(HealthEngine.label(score)).uiFont(13, .medium, color: Theme.healthColor(score))
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(Theme.healthColor(score).opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            HStack(spacing: 10) {
                OrbitButton(days.isEmpty ? tr("Дни: не выбраны", "Days: none") : tr("Дни: \(days)", "Days: \(days)"), icon: "calendar") {
                    app.sheet = .planner(weekKey: app.currentWeekKey)
                }
                OrbitButton(tr("Терминал", "Terminal"), icon: "terminal") { app.openTerminal(projectId) }
                OrbitButton(app.isSyncing || app.aiBusy.contains("project:" + projectId) ? tr("Анализ…", "Analyzing…") : tr("Запустить анализ", "Run analysis"), icon: "sparkles") {
                    app.analyzeNow(projectId: projectId)
                }
                DevelopmentControls(projectId: projectId)
            }
        }
    }

    private func sessionsPanel(_ snap: ProjectSnapshot) -> some View {
        let list = snap.sessions.filter { agentFilter == nil || $0.agent == agentFilter }
        let agents = AgentKind.allCases.filter { a in snap.sessions.contains { $0.agent == a } }
        return VStack(spacing: 0) {
            HStack {
                Text(tr("Сессии ИИ-агентов", "AI agent sessions")).uiFont(14, .semibold)
                Spacer()
                SegmentedTabs(items: [(AgentKind?.none, tr("Все · \(snap.sessions.count)", "All · \(snap.sessions.count)"))] + agents.map { (Optional($0), $0.title) },
                              selection: $agentFilter)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .hairline()

            if let digest = app.digest(snap) {
                HStack(alignment: .top, spacing: 14) {
                    IconBox(symbol: "sparkles", color: Theme.accent, size: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(tr("\(app.projectAI(snap.config.id) != nil ? "Вывод ИИ" : "Вывод") по последним \(min(5, snap.sessions.count)) сессиям", "\(app.projectAI(snap.config.id) != nil ? "AI take" : "Summary") on the last \(Plural.sessions(min(5, snap.sessions.count)))"))
                                .uiFont(13, .semibold, color: Theme.accent)
                            if let ai = app.projectAI(snap.config.id) {
                                Text("\(ai.source) · \(DateFormat.relativeDay(ai.createdAt))").uiFont(11.5, color: Theme.text3)
                            }
                            if app.aiBusy.contains("project:" + snap.config.id) { ProgressView().controlSize(.mini) }
                        }
                        Text(digest).uiFont(13.5).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                            .animation(Motion.pick(Motion.content), value: digest)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.04))
                .hairline()
            }

            if list.isEmpty {
                EmptyHint(symbol: "cpu", title: tr("Сессий нет", "No sessions"), text: tr("Запустите Claude Code или Codex в папке проекта — Orbit подхватит логи.", "Run Claude Code or Codex in the project folder — Orbit will pick up the logs."))
                    .padding(.vertical, 40)
            }
            ForEach(Array(list.prefix(25).enumerated()), id: \.element.id) { i, s in
                Button { app.showSession(s) } label: { SessionRow(session: s).hoverHighlight() }
                    .buttonStyle(PlainButtonStyle2())
                    .hairline()
                    .appearStagger(i + 2)
                    .transition(Motion.transition(.opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .cardStyle()
    }
}

struct SessionRow: View {
    var session: AgentSession

    var body: some View {
        let s = session
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dayLabel(s.start)).uiFont(13)
                Text(DateFormat.time.string(from: s.start)).monoFont(12, color: Theme.text3)
            }
            .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AgentTag(agent: s.agent)
                    Text(s.title).uiFont(14, .medium).lineLimit(1)
                    Spacer(minLength: 8)
                    StatusTag(status: s.status)
                }
                Text(InsightEngine.sessionSummary(s, limit: 180)).uiFont(13, color: Theme.text2).lineSpacing(3).lineLimit(2)
                HStack(spacing: 18) {
                    meta("timer", Duration.text(minutes: s.durationMinutes))
                    meta("doc", Plural.files(s.filesTouched.count))
                    meta("plusminus", "+\(s.linesAdded) −\(s.linesRemoved)", mono: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Week.calendar
        if cal.isDateInToday(d) { return tr("Сегодня", "Today") }
        if cal.isDateInYesterday(d) { return tr("Вчера", "Yesterday") }
        return DateFormat.weekdayShort(d)
    }

    private func meta(_ icon: String, _ text: String, mono: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(mono ? OrbitFont.mono(12) : OrbitFont.ui(12.5))
        }
        .foregroundStyle(Theme.text3)
    }
}

struct StatTilesRow: View {
    var snap: ProjectSnapshot
    var score: Int
    var history: [Int]

    var body: some View {
        let week = snap.sessions(in: 7)
        let minutes = week.reduce(0) { $0 + $1.durationMinutes }
        let commits = snap.commits(in: 7)
        let added = commits.reduce(0) { $0 + $1.added }, removed = commits.reduce(0) { $0 + $1.removed }
        let trend = (history.last ?? 0) - (history.dropLast(7).last ?? history.first ?? 0)
        HStack(spacing: 0) {
            tile(width: 320) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Здоровье", "Health")).uiFont(12.5, color: Theme.text2)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(score)").font(OrbitFont.ui(28, .semibold)).foregroundStyle(Theme.healthColor(score))
                            if trend != 0 { Text(tr("\(trend > 0 ? "↑" : "↓") \(abs(trend)) за неделю", "\(trend > 0 ? "↑" : "↓") \(abs(trend)) this week")).uiFont(12.5, color: Theme.text3) }
                        }
                        Text(tr("Тренд за 14 дней по сессиям, тестам и git", "14-day trend from sessions, tests and git")).uiFont(12, color: Theme.text3)
                    }
                    Spacer()
                    Sparkline(values: history).frame(width: 120, height: 44)
                }
            }
            divider
            tile { statContent(tr("Сессии агентов", "Agent sessions"), "\(week.count)", tr("за 7 дней · \(Duration.text(minutes: minutes))", "in 7 days · \(Duration.text(minutes: minutes))")) }
            divider
            tile { statContent(tr("Коммиты", "Commits"), "\(commits.count)", tr("+\(NumberText.grouped(added)) / −\(NumberText.grouped(removed)) строк", "+\(NumberText.grouped(added)) / −\(NumberText.grouped(removed)) lines")) }
            divider
            tile {
                if let total = snap.testsTotal {
                    statContent(tr("Тесты", "Tests"), "\(total)", snap.testsFailing > 0 ? tr("\(snap.testsFailing) падают", "\(snap.testsFailing) failing") : tr("все зелёные", "all green"),
                                color: snap.testsFailing > 0 ? Theme.red : Theme.green)
                } else {
                    statContent(tr("Тесты", "Tests"), "—", tr("агенты не запускали тесты", "agents didn’t run tests"), color: Theme.text3)
                }
            }
            divider
            tile {
                statContent(tr("Незакоммичено", "Uncommitted"), "\(snap.repo.changes.count)",
                            snap.repo.changes.isEmpty ? tr("рабочая копия чистая", "working tree clean") : "\(pluralWord(snap.repo.changes.count, ru: ("файл", "файла", "файлов"), en: ("file", "files"))) · \(snap.repo.changesAgeHours.map { tr("\(Duration.age(hours: $0)) назад", "\(Duration.age(hours: $0)) ago") } ?? "")",
                            color: snap.repo.changes.isEmpty ? Theme.text : Theme.yellow)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle()
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(width: 1) }

    @ViewBuilder
    private func tile<C: View>(width: CGFloat? = nil, @ViewBuilder _ content: () -> C) -> some View {
        let padded = content().padding(.horizontal, 24).padding(.vertical, 22)
        if let width {
            padded.frame(width: width, alignment: .leading)
        } else {
            padded.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statContent(_ title: String, _ value: String, _ caption: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).uiFont(12.5, color: Theme.text2)
            Text(value).font(OrbitFont.ui(28, .semibold)).foregroundStyle(color).numericTransition(value)
            Text(caption).uiFont(12, color: Theme.text3).lineLimit(1)
        }
    }
}

struct Sparkline: View {
    var values: [Int]
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let maxV = max(Double(values.max() ?? 100), 1)
            let minV = Double(values.min() ?? 0) * 0.8
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let h = max(4, geo.size.height * (Double(v) - minV) / max(maxV - minV, 1))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.healthColor(v).opacity(i >= values.count - 4 ? 1 : 0.3))
                        .frame(height: appeared ? h : 2)
                        .animation(Motion.pick(Motion.grow).delay(Motion.reduced ? 0 : Double(i) * 0.02), value: appeared)
                }
            }
            // Pin the baseline to the bottom so bars grow upwards instead of dropping from the top.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .animation(Motion.pick(Motion.grow), value: values)
        .onAppear { appeared = true }
    }
}

struct GitPanel: View {
    @Environment(AppState.self) private var app
    var snap: ProjectSnapshot

    var body: some View {
        let r = snap.repo
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Git").uiFont(14, .semibold)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                    Text(r.branch).monoFont(12.5)
                }
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .hairline()

            HStack(spacing: 20) {
                Label { Text(tr("\(r.ahead) впереди", "\(r.ahead) ahead")).uiFont(13, color: Theme.text2) } icon: { Image(systemName: "arrow.up").font(.system(size: 11)) }
                Label { Text(tr("\(r.behind) позади", "\(r.behind) behind")).uiFont(13, color: Theme.text2) } icon: { Image(systemName: "arrow.down").font(.system(size: 11)) }
                if r.mainBranch != nil && r.branch != r.mainBranch {
                    Text("main −\(r.behindMain)").monoFont(12.5, color: r.behindMain >= 20 ? Theme.red : Theme.text2)
                }
                if snap.testsFailing > 0 {
                    Label { Text(tr("\(snap.testsFailing) падают", "\(snap.testsFailing) failing")).uiFont(13, color: Theme.red) } icon: { Image(systemName: "xmark.circle").foregroundStyle(Theme.red) }
                }
                if let gh = app.github[snap.config.id] {
                    if let ci = gh.ci, ci.state != .none {
                        Text(ci.state == .failure ? "CI ✗" : ci.state == .pending ? "CI …" : "CI ✓")
                            .uiFont(13, color: ci.state == .failure ? Theme.red : ci.state == .pending ? Theme.yellow : Theme.green)
                    }
                    if !gh.pulls.isEmpty { Text("\(gh.pulls.count) PR").uiFont(13, color: Theme.text2) }
                }
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("Незакоммиченные · \(r.changes.count)", "Uncommitted · \(r.changes.count)")).uiFont(13, .semibold, color: r.changes.isEmpty ? Theme.text2 : Theme.yellow)
                    Spacer()
                    if let age = r.changesAgeHours { Text(Duration.age(hours: age)).uiFont(12, color: Theme.text3) }
                }
                ForEach(r.changes.prefix(8)) { c in
                    changeRow(c).transition(Motion.transition(.opacity.combined(with: .offset(x: -8))))
                }
                .animation(Motion.pick(Motion.snappy), value: r.changes.map(\.path))
                if r.changes.count > 8 { Text(tr("и ещё \(r.changes.count - 8)…", "and \(r.changes.count - 8) more…")).uiFont(12, color: Theme.text3) }
                if !r.changes.isEmpty {
                    HStack(spacing: 10) {
                        Button { app.sheet = .commit(projectId: snap.config.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                                Text(tr("Сгенерировать коммит", "Generate commit")).uiFont(13, .medium)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle2())
                        OrbitButton(tr("Дифф", "Diff"), icon: "chevron.left.forwardslash.chevron.right") { app.sheet = .diff(projectId: snap.config.id) }
                    }
                    .padding(.top, 4)
                } else {
                    Text(tr("Рабочая копия чистая", "Working tree clean")).uiFont(12.5, color: Theme.text3)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .hairline()

            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Последние коммиты", "Recent commits")).uiFont(13, .semibold, color: Theme.text2)
                let commits = r.commits.isEmpty ? (r.lastCommit.map { [$0] } ?? []) : Array(r.commits.prefix(4))
                ForEach(commits) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().strokeBorder(Theme.text3, lineWidth: 1.5).frame(width: 9, height: 9).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.subject).uiFont(13.5).lineLimit(1)
                            Text(tr("\(c.shortHash) · \(c.agent?.title ?? "вы") · \(DateFormat.relativeDay(c.date, withTime: false))", "\(c.shortHash) · \(c.agent?.title ?? "you") · \(DateFormat.relativeDay(c.date, withTime: false))")).monoFont(11.5, color: Theme.text3)
                        }
                    }
                }
                if commits.isEmpty { Text(tr("Коммитов нет", "No commits")).uiFont(12.5, color: Theme.text3) }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .cardStyle()
    }

    private func changeRow(_ c: FileChange) -> some View {
        HStack(spacing: 10) {
            Text(c.status).monoFont(12.5, .medium, color: c.status == "?" ? Theme.text2 : c.status == "A" ? Theme.green : c.status == "D" ? Theme.red : Theme.yellow)
                .frame(width: 12)
            Text(c.path).monoFont(12.5).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(lineText(c)).monoFont(11.5, color: Theme.text3)
        }
    }

    private func lineText(_ c: FileChange) -> String {
        if c.added == 0 && c.removed == 0 { return "" }
        if c.removed == 0 { return "+\(c.added)" }
        if c.added == 0 { return "−\(c.removed)" }
        return "+\(c.added) −\(c.removed)"
    }
}

struct WorkDaysPanel: View {
    @Environment(AppState.self) private var app
    var snap: ProjectSnapshot

    var body: some View {
        let days = Set(snap.config.workDays)
        let today = Week.weekdayIndex(app.now)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(tr("Дни работы", "Work days")).uiFont(14, .semibold)
                Spacer()
                Text(tr("клик — включить/выключить", "click to toggle")).uiFont(12, color: Theme.text3)
            }
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { d in
                    let on = days.contains(d)
                    let color = Theme.projectColor(snap.config.colorIndex)
                    Button {
                        withMotion {
                            app.updateProject(snap.config.id) { p in
                                if on { p.workDays.removeAll { $0 == d } } else { p.workDays.append(d) }
                            }
                        }
                    } label: {
                        Text(Week.shortNames[d])
                            .uiFont(13, on ? .semibold : .regular, color: on ? color : Theme.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(on ? color.opacity(0.16) : Theme.surface2, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(d == today ? color : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle2())
                }
            }
            Text(InsightEngine.workDaysAdvice(snap)).uiFont(13, color: Theme.text2).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .cardStyle()
    }
}
