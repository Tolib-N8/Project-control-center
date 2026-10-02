import SwiftUI

struct SessionsView: View {
    @Environment(AppState.self) private var app
    @Namespace private var listSpace
    @State private var agent: AgentKind?
    @State private var period = 30

    var body: some View {
        @Bindable var app = app
        let list = filtered
        let hours = list.reduce(0) { $0 + $1.activeSeconds } / 3600
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(eyebrow: "\(Plural.sessions(list.count)) за \(period) дней · \(Duration.hours(hours)) ч работы агентов", title: "Сессии агентов") {
                filterMenu(icon: "folder", title: app.sessionFilterProject.map { app.projectName($0) } ?? "Все проекты") {
                    Button("Все проекты") { app.sessionFilterProject = nil }
                    ForEach(app.config.activeProjects) { p in Button(p.name) { app.sessionFilterProject = p.id } }
                }
                filterMenu(icon: "cpu", title: agent?.title ?? "Все агенты") {
                    Button("Все агенты") { agent = nil }
                    ForEach(AgentKind.allCases) { a in Button(a.title) { agent = a } }
                }
                filterMenu(icon: "calendar", title: "\(period) дней") {
                    ForEach([7, 30, 90], id: \.self) { d in Button("\(d) дней") { period = d } }
                }
            }

            HStack(spacing: 20) {
                ForEach(Array(agentsShown.enumerated()), id: \.element) { i, a in
                    AgentStatsCard(agent: a, sessions: list.filter { $0.agent == a }).appearStagger(i)
                }
            }

            HStack(alignment: .top, spacing: 28) {
                sessionList(list)
                    .frame(width: 440)
                    .appearStagger(2)
                if let selected = list.first(where: { $0.id == app.selectedSessionId }) ?? list.first {
                    // A new session fades in with a slight rise; the old one just fades out.
                    SessionDetail(session: selected)
                        .id(selected.id)
                        .transition(Motion.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                                                  removal: .opacity.animation(.easeOut(duration: 0.08)))))
                        .appearStagger(3)
                } else {
                    EmptyHint(symbol: "cpu", title: "Сессий нет", text: "За выбранный период агенты не работали в подключённых проектах.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cardStyle()
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.pick(Motion.content), value: app.selectedSessionId)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 28)
    }

    private var filtered: [AgentSession] {
        let from = app.now.addingTimeInterval(-Double(period) * 86400)
        let active = Set(app.config.activeProjects.map(\.id))
        return app.sessions.filter { s in
            s.start >= from && active.contains(s.projectId)
                && (agent == nil || s.agent == agent)
                && (app.sessionFilterProject == nil || s.projectId == app.sessionFilterProject)
        }
    }

    private var agentsShown: [AgentKind] {
        let present = Set(app.sessions.map(\.agent))
        let list = AgentKind.allCases.filter { present.contains($0) || $0 == .claude || $0 == .codex }
        return agent.map { [$0] } ?? list
    }

    private func filterMenu<C: View>(icon: String, title: String, @ViewBuilder content: () -> C) -> some View {
        MenuChip(icon: icon, title: title) { content() }
    }

    private func sessionList(_ list: [AgentSession]) -> some View {
        let groups = Dictionary(grouping: list) { Week.calendar.startOfDay(for: $0.start) }
            .sorted { $0.key > $1.key }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(groups, id: \.key) { day, items in
                    Eyebrow(text: dayTitle(day))
                        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                    ForEach(items) { s in row(s) }
                }
            }
            .padding(.bottom, 12)
            .animation(Motion.pick(Motion.snappy), value: list.map(\.id))
        }
        .frame(maxHeight: .infinity)
        .cardStyle()
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Week.calendar
        if cal.isDateInToday(d) { return "Сегодня" }
        if cal.isDateInYesterday(d) { return "Вчера" }
        return DateFormat.weekdayShort(d)
    }

    private func row(_ s: AgentSession) -> some View {
        let selected = s.id == (app.selectedSessionId ?? filtered.first?.id)
        return Button { withMotion { app.selectedSessionId = s.id } } label: {
            HStack(alignment: .top, spacing: 12) {
                Dot(color: s.status.color, size: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(s.title).uiFont(14, .medium).lineLimit(1)
                        Spacer()
                        Text(DateFormat.time.string(from: s.start)).monoFont(12, color: Theme.text3)
                    }
                    HStack(spacing: 6) {
                        ProjectLabel(projectId: s.projectId, size: 12.5, color: Theme.text2)
                        Text("· \(s.agent.title) · \(Duration.text(minutes: s.durationMinutes))").uiFont(12.5, color: Theme.text3)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background {
                // Highlight and accent bar slide to the selected row.
                if selected {
                    Theme.surface2.matchedGeometryEffect(id: "selected", in: listSpace)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
                }
            }
            .hoverHighlight()
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
    }
}

struct AgentStatsCard: View {
    var agent: AgentKind
    var sessions: [AgentSession]

    var body: some View {
        let done = sessions.filter { $0.status == .done }.count
        let stuck = sessions.filter { $0.status == .unfinished }.count
        let rolled = sessions.filter { $0.status == .rolledBack }.count
        let minutes = sessions.reduce(0) { $0 + $1.durationMinutes }
        let rate = sessions.isEmpty ? 0 : Int((Double(done) / Double(sessions.count) * 100).rounded())
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    AgentTag(agent: agent)
                    Spacer()
                    Text(Duration.text(minutes: minutes)).uiFont(12.5, color: Theme.text3)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(sessions.count)").font(OrbitFont.ui(30, .semibold)).numericTransition(sessions.count)
                    Text(Plural.ru(sessions.count, "сессия", "сессии", "сессий")).uiFont(14, color: Theme.text2)
                    Spacer()
                    if !sessions.isEmpty {
                        Text("\(rate)% успешных").uiFont(14, .medium, color: rate >= 70 ? Theme.green : rate >= 50 ? Theme.yellow : Theme.red).numericTransition(rate)
                    }
                }
                SegmentBar(segments: sessions.isEmpty ? [(1, Theme.border)] : [(Double(done), Theme.green), (Double(stuck), Theme.yellow), (Double(rolled), Theme.red)])
                HStack(spacing: 18) {
                    Text("\(done) готово")
                    Text("\(stuck) застрял")
                    Text("\(rolled) откат")
                }
                .uiFont(12.5, color: Theme.text3)
            }
        }
    }
}

struct SessionDetail: View {
    @Environment(AppState.self) private var app
    var session: AgentSession

    var body: some View {
        let s = session
        let ai = app.sessionAI(s.id)
        let busy = app.aiBusy.contains("session:" + s.id)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AgentTag(agent: s.agent)
                    Text(app.projectName(s.projectId)).monoFont(13).lineLimit(1)
                    Text("· \(DateFormat.relativeDay(s.start)) — \(DateFormat.time.string(from: s.end))\(s.model.map { " · \($0)" } ?? "")")
                        .uiFont(12.5, color: Theme.text3).lineLimit(1).layoutPriority(-1)
                    Spacer()
                    StatusTag(status: s.status)
                }
                Text(s.title).uiFont(20, .semibold).lineLimit(2)
            }
            .padding(.horizontal, 20).padding(.vertical, 20)
            .hairline()

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section("checkmark.circle", "Что сделано", Theme.green) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array((ai?.done.isEmpty == false ? ai!.done : InsightEngine.doneBullets(s)).enumerated()), id: \.offset) { _, b in
                                    Text("— " + b).uiFont(13.5).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let stuck = ai.map({ $0.stuck.isEmpty ? nil : $0.stuck }) ?? InsightEngine.stuck(s) {
                            section("exclamationmark.triangle", "Где застрял", Theme.yellow) {
                                Text(stuck).uiFont(13.5).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                    .padding(18)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.yellow.opacity(0.35)))
                            }
                        }
                        section("sparkles", ai != nil ? "Рекомендация ИИ" : "Рекомендация", Theme.accent) {
                            Text(ai.map { $0.recommendation.isEmpty ? InsightEngine.recommendation(s) : $0.recommendation } ?? InsightEngine.recommendation(s)).uiFont(13.5).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        }
                        if !s.firstPrompt.isEmpty {
                            section("text.bubble", "Задача", Theme.text2) {
                                Text(s.firstPrompt).uiFont(13, color: Theme.text2).lineSpacing(4).lineLimit(6)
                            }
                        }
                        FlowLayout(spacing: 10) {
                            if s.agent == .claude || s.agent == .codex {
                                OrbitButton("Продолжить с контекстом", icon: "play", kind: .primary) { app.resume(s) }
                            }
                            if s.agent == .claude {
                                OrbitButton("Транскрипт", icon: "scroll") { app.sheet = .transcript(sessionId: s.id) }
                            }
                            OrbitButton("Лог", icon: "doc.text.magnifyingglass") { Shell.reveal(s.logPath.components(separatedBy: "#").first ?? s.logPath) }
                            if app.config.ai.isEnabled {
                                OrbitButton(busy ? "ИИ разбирает…" : (ai == nil ? "Разобрать с ИИ" : "Обновить разбор"), icon: "sparkles") {
                                    app.analyzeSession(s, force: true)
                                }
                                .disabled(busy)
                            }
                        }
                        if let ai {
                            Text("Разбор: \(ai.source) · \(DateFormat.relativeDay(ai.createdAt))").uiFont(11.5, color: Theme.text3)
                        }
                    }
                    .padding(20)
                    .animation(Motion.pick(Motion.content), value: ai)
                }
                .frame(maxWidth: .infinity)

                Rectangle().fill(Theme.border).frame(width: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metric("Длительность", Duration.text(minutes: s.durationMinutes))
                        metric("Токены", s.tokens > 0 ? NumberText.compact(s.tokens) : "—")
                        metric("Файлов изменено", "\(s.filesTouched.count)")
                        metric("Строк", "+\(s.linesAdded) −\(s.linesRemoved)")
                        testsMetric(s)
                        metric("Коммит", s.commitsInWindow.isEmpty ? "не создан" : "\(s.commitsInWindow.count) · \(String(s.commitsInWindow[0].prefix(7)))",
                               color: s.commitsInWindow.isEmpty ? Theme.yellow : Theme.green)
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 6)
                        Text("Ход сессии").uiFont(13, .semibold, color: Theme.text2)
                        ForEach(InsightEngine.timeline(s)) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Text(DateFormat.time.string(from: item.time)).monoFont(11.5, color: Theme.text3).frame(width: 40, alignment: .leading)
                                Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 16)
                                    .foregroundStyle(tone(item.tone) == Theme.text ? Theme.text2 : tone(item.tone))
                                Text(item.text).uiFont(13, color: tone(item.tone)).lineLimit(2)
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(width: 250)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardStyle()
        .task(id: s.id) {
            // Opening a session analyses it once; the cache keeps repeat views free.
            if app.config.ai.autoAnalyze { app.analyzeSession(s) }
        }
    }

    private func tone(_ t: InsightEngine.TimelineItem.Tone) -> Color {
        switch t {
        case .normal: Theme.text
        case .good: Theme.green
        case .warn: Theme.yellow
        case .bad: Theme.red
        }
    }

    private func section<C: View>(_ icon: String, _ title: String, _ color: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
                Text(title).uiFont(13.5, .semibold, color: color)
            }
            content()
        }
    }

    private func metric(_ k: String, _ v: String, color: Color = Theme.text) -> some View {
        HStack {
            Text(k).uiFont(13, color: Theme.text2)
            Spacer()
            Text(v).monoFont(12.5, color: color)
        }
    }

    @ViewBuilder
    private func testsMetric(_ s: AgentSession) -> some View {
        if s.testsPassed == nil && s.testsFailed == nil {
            metric("Тесты", "не запускались", color: Theme.text3)
        } else {
            HStack {
                Text("Тесты").uiFont(13, color: Theme.text2)
                Spacer()
                Text(s.testsPassed.map { "\($0) ✓" } ?? ((s.testsFailed ?? 0) > 0 ? "" : "прошли ✓")).monoFont(12.5, color: (s.testsFailed ?? 0) > 0 ? Theme.red : Theme.green)
                if let f = s.testsFailed, f > 0 { Text("· \(f) ✗").monoFont(12.5, color: Theme.red) }
            }
        }
    }
}

struct TranscriptSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var sessionId: String
    @State private var entries: [TranscriptEntry] = []
    @State private var loading = true

    var body: some View {
        let s = app.sessions.first { $0.id == sessionId }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(s?.title ?? "Транскрипт").uiFont(16, .semibold).lineLimit(1)
                Spacer()
                OrbitButton("Закрыть") { dismiss() }
            }
            .padding(20).hairline()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(entries) { e in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(DateFormat.time.string(from: e.time)) · \(e.role == "user" ? "Вы" : e.role == "tool" ? "Инструмент" : "Агент")")
                                    .monoFont(11, color: e.role == "user" ? Theme.accent : Theme.text3)
                                Text(e.text).font(e.role == "tool" ? OrbitFont.mono(12) : OrbitFont.ui(13))
                                    .foregroundStyle(e.role == "tool" ? Theme.text2 : Theme.text)
                                    .textSelection(.enabled)
                                    .lineLimit(e.role == "tool" ? 2 : 40)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 820, height: 680)
        .background(Theme.surface)
        .task {
            guard let s else { loading = false; return }
            let path = s.logPath, from = s.start, to = s.end
            entries = await Task.detached { ClaudeCodeParser.transcript(path, from: from, to: to) }.value
            loading = false
        }
    }
}
