import SwiftUI

struct SignalsView: View {
    @Environment(AppState.self) private var app
    @State private var tab: SignalState = .active

    var body: some View {
        let list = app.signals.filter { $0.state == tab }
        let resolvedMonth = app.signals.filter { $0.state == .resolved && ($0.resolvedAt ?? .distantPast) > app.now.addingTimeInterval(-30 * 86400) }
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(eyebrow: tr("Проверка каждые 15 минут · \(resolvedMonth.count) решено за месяц", "Checked every 15 minutes · \(resolvedMonth.count) resolved this month"), title: tr("Сигналы", "Signals")) {
                SegmentedTabs(items: [
                    (SignalState.active, tr("Активные · \(count(.active))", "Active · \(count(.active))")),
                    (.snoozed, tr("Отложенные · \(count(.snoozed))", "Snoozed · \(count(.snoozed))")),
                    (.resolved, tr("Решённые · \(count(.resolved))", "Resolved · \(count(.resolved))")),
                ], selection: $tab)
            }
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if list.isEmpty {
                            emptyState.frame(minHeight: 620)
                                .transition(Motion.transition(Motion.pop))
                        } else if tab == .resolved {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in resolvedRow(s).appearStagger(i) }
                        } else {
                            // A snoozed or resolved card slides out to the left and the rest close the gap.
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                                SignalCard(signal: s)
                                    .appearStagger(i)
                                    .transition(Motion.transition(.asymmetric(insertion: Motion.rise,
                                                                              removal: .opacity.combined(with: .move(edge: .leading)))))
                            }
                        }
                        if tab == .active && !list.isEmpty && !resolvedMonth.isEmpty {
                            Eyebrow(text: tr("Недавно решено", "Recently resolved")).padding(.top, 10)
                            ForEach(resolvedMonth.prefix(4)) { s in resolvedRow(s) }
                        }
                    }
                    .id(tab)
                    .transition(Motion.transition(.opacity))
                    .animation(Motion.pick(Motion.page), value: list.map(\.id))
                }
                .animation(Motion.pick(Motion.content), value: tab)
                .frame(maxWidth: .infinity)
                RulesPanel().frame(width: 360)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
    }

    private func count(_ state: SignalState) -> Int { app.signals.filter { $0.state == state }.count }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 26)).foregroundStyle(Theme.green)
                .frame(width: 56, height: 56)
                .background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Text(tab == .active ? tr("Всё спокойно", "All quiet") : tab == .snoozed ? tr("Отложенных нет", "Nothing snoozed") : tr("Пока ничего не решено", "Nothing resolved yet")).uiFont(22, .semibold)
            if tab == .active {
                Text(tr("Ветки свежие, изменения закоммичены, агенты не буксуют.\nПоследняя проверка — \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "ещё не было").", "Branches are fresh, changes are committed, agents aren’t stuck.\nLast check: \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "not yet")."))
                    .uiFont(14, color: Theme.text2).multilineTextAlignment(.center).lineSpacing(5)
                HStack(spacing: 22) {
                    check(Plural.repos(app.config.activeProjects.count))
                    check(Plural.sessions(app.sessions.filter { $0.start > app.now.addingTimeInterval(-30 * 86400) }.count))
                    check(tr("тесты зелёные", "tests green"))
                }
                .padding(.top, 6)
                OrbitButton(app.isSyncing ? tr("Проверяем…", "Checking…") : tr("Проверить сейчас", "Check now"), icon: "arrow.clockwise") { Task { await app.refresh() } }
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle()
    }

    private func check(_ t: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
            Text(t).uiFont(13, color: Theme.text2)
        }
    }

    private func resolvedRow(_ s: Signal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
            ProjectLabel(projectId: s.projectId, size: 13, color: Theme.text2)
            Text("\(s.title)\(s.resolution.map { " — \($0)" } ?? "")").uiFont(13.5, color: Theme.text2).lineLimit(1)
            Spacer()
            Text(s.resolvedAt.map { DateFormat.short($0) } ?? "").uiFont(12.5, color: Theme.text3)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }
}

struct SignalCard: View {
    @Environment(AppState.self) private var app
    var signal: Signal

    var body: some View {
        let s = signal
        let color = s.severity == .critical ? Theme.red : Theme.yellow
        Card(padding: 20) {
            HStack(alignment: .top, spacing: 20) {
                IconBox(symbol: s.kind.symbol, color: color, size: 34)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Tag(text: s.severity.title, color: color, size: 12)
                        ProjectLabel(projectId: s.projectId, size: 13, color: Theme.text2)
                        Text(tr("· обнаружено \(DateFormat.relativeDay(s.detectedAt))", "· detected \(DateFormat.relativeDay(s.detectedAt))")).uiFont(12.5, color: Theme.text3)
                        Spacer()
                        if s.state == .snoozed {
                            Button { withMotion(Motion.page) { app.unsnooze(s.id) } } label: {
                                Label(tr("Вернуть", "Unsnooze"), systemImage: "bell").uiFont(12.5, color: Theme.text2)
                            }
                            .buttonStyle(PlainButtonStyle2())
                        } else {
                            Menu {
                                Button(tr("На день", "For a day")) { withMotion(Motion.page) { app.snooze(s.id, days: 1) } }
                                Button(tr("На 3 дня", "For 3 days")) { withMotion(Motion.page) { app.snooze(s.id, days: 3) } }
                                Button(tr("На неделю", "For a week")) { withMotion(Motion.page) { app.snooze(s.id, days: 7) } }
                            } label: {
                                Label(tr("Отложить", "Snooze"), systemImage: "bell.slash").uiFont(12.5, color: Theme.text2)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                    Text(s.title).uiFont(16, .semibold)
                    Text(s.detail).uiFont(13.5, color: Theme.text2).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 32) {
                        ForEach(s.metrics, id: \.label) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.label).uiFont(12, color: Theme.text3)
                                Text(m.value).uiFont(14, .medium)
                            }
                        }
                    }
                    HStack(spacing: 10) { actions(s) }.padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ s: Signal) -> some View {
        let pid = s.projectId
        let repo = app.repos[pid]
        switch s.kind {
        case .behindMain:
            OrbitButton(tr("Rebase с агентом", "Rebase with an agent"), icon: "sparkles", kind: .primary) {
                app.runAgent(pid, prompt: tr("Сделай rebase ветки \(repo?.branch ?? "") на \(repo?.mainBranch ?? "main"). Разреши конфликты, сохрани смысл обеих сторон, прогони тесты и покажи итог перед push.", "Rebase branch \(repo?.branch ?? "") onto \(repo?.mainBranch ?? "main"). Resolve conflicts keeping the intent of both sides, run the tests and show me the result before pushing."))
            }
            OrbitButton(tr("Перенести день", "Move the day"), icon: "calendar") { app.sheet = .planner(weekKey: app.currentWeekKey) }
        case .agentReverts:
            OrbitButton(tr("Составить бриф для агента", "Write an agent brief"), icon: "doc.text", kind: .primary) { app.sheet = .brief(signalId: s.id) }
            OrbitButton(tr("Сессии", "Sessions"), icon: "eye") {
                app.sessionFilterProject = pid
                app.screen = .sessions
            }
        case .uncommitted:
            OrbitButton(tr("Закоммитить", "Commit"), icon: "point.topleft.down.to.point.bottomright.curvepath", kind: .primary) { app.sheet = .commit(projectId: pid) }
            OrbitButton(tr("Посмотреть дифф", "View diff"), icon: "chevron.left.forwardslash.chevron.right") { app.sheet = .diff(projectId: pid) }
        case .testsFailing:
            OrbitButton(tr("Починить с агентом", "Fix with an agent"), icon: "sparkles", kind: .primary) {
                let test = app.snapshots[pid]?.lastTestedSession?.lastFailingTest.map { " (\($0))" } ?? ""
                app.runAgent(pid, prompt: tr("В проекте падают тесты\(test). Запусти тесты, найди причину и почини. Не меняй тесты без необходимости.", "Tests are failing in this project\(test). Run the tests, find the cause and fix it. Don’t change the tests unless you have to."))
            }
            OrbitButton(tr("Терминал", "Terminal"), icon: "terminal") { app.openTerminal(pid) }
        case .idle:
            OrbitButton(tr("Запланировать", "Plan"), icon: "calendar.badge.plus", kind: .primary) { app.sheet = .planner(weekKey: app.currentWeekKey) }
            OrbitButton(tr("В архив", "Archive"), icon: "archivebox") { app.updateProject(pid) { $0.archived = true } }
        case .skippedDay:
            OrbitButton(tr("Перенести блок", "Move the block"), icon: "calendar", kind: .primary) { app.sheet = .planner(weekKey: app.currentWeekKey) }
        case .tokens:
            OrbitButton(tr("Сессии", "Sessions"), icon: "eye", kind: .primary) {
                app.sessionFilterProject = pid
                app.screen = .sessions
            }
        }
    }
}

struct RulesPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Правила мониторинга", "Monitoring rules")).uiFont(15, .semibold)
                Text(tr("Когда Orbit должен поднимать сигнал", "When Orbit should raise a signal")).uiFont(12.5, color: Theme.text3)
            }
            .padding(.bottom, 16)
            .hairline()

            ForEach(app.config.rules, id: \.kind) { rule in
                HStack(spacing: 14) {
                    Image(systemName: rule.kind.symbol).font(.system(size: 13)).foregroundStyle(rule.enabled ? Theme.text2 : Theme.text3).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.kind.title).uiFont(13.5, .medium, color: rule.enabled ? Theme.text : Theme.text2)
                        Text(rule.kind.subtitle(rule.threshold)).uiFont(12, color: Theme.text3)
                    }
                    Spacer()
                    OrbitToggle(isOn: Binding(get: { rule.enabled }, set: { on in withMotion { app.setRule(rule.kind, enabled: on) } }))
                }
                .padding(.vertical, 14)
                .hairline()
                .animation(Motion.pick(Motion.snappy), value: rule.enabled)
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Куда отправлять", "Deliver to")).uiFont(13, .semibold, color: Theme.text2)
                HStack(spacing: 8) {
                    channel("desktopcomputer", "macOS", on: app.config.notifyMacOS) {
                        app.config.notifyMacOS.toggle()
                        app.saveConfig()
                    }
                    channel("paperplane", "Telegram", on: false, disabled: true) {}
                    channel("envelope", tr("Почта", "Email"), on: false, disabled: true) {}
                }
                Text(app.config.rhythm.morningBrief ? tr("Утренняя сводка в 9:00 перед началом дня · Telegram и почта — скоро", "Morning brief at 9:00 before the day starts · Telegram and email soon") : tr("Утренняя сводка выключена", "Morning brief is off"))
                    .uiFont(12, color: Theme.text3)
            }
            .padding(18)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardStyle()
    }

    private func channel(_ icon: String, _ title: String, on: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icon(icon, size: 11, weight: .regular)
                Text(title).uiFont(12.5).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(on ? Theme.accent : Theme.text3)
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(on ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Theme.accent.opacity(0.4) : Theme.border))
        }
        .buttonStyle(PlainButtonStyle2())
        .disabled(disabled)
        .help(disabled ? tr("Будет во второй фазе", "Coming later") : "")
    }
}

/// Template brief for an agent that keeps reverting its work.
struct BriefSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var signalId: String
    @State private var text = ""
    @State private var generating = false

    var body: some View {
        let signal = app.signals.first { $0.id == signalId }
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Бриф для агента · \(signal.map { app.projectName($0.projectId) } ?? "")", "Agent brief · \(signal.map { app.projectName($0.projectId) } ?? "")")).uiFont(18, .semibold)
            Text(tr("Заполните цель и критерий готовности — агенту станет понятно, когда остановиться.", "Fill in the goal and the definition of done — so the agent knows when to stop.")).uiFont(13, color: Theme.text2)
            TextEditor(text: $text)
                .font(OrbitFont.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 340)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            HStack {
                OrbitButton(tr("Скопировать", "Copy"), icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    app.toast = tr("Бриф скопирован", "Brief copied")
                }
                if app.config.ai.isEnabled {
                    OrbitButton(generating ? tr("Пишу…", "Writing…") : tr("Составить с ИИ", "Write with AI"), icon: "sparkles") {
                        generating = true
                        Task {
                            do { text = try await app.aiBrief(signalId) } catch { app.toast = error.localizedDescription }
                            generating = false
                        }
                    }
                    .disabled(generating)
                }
                Spacer()
                OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
                OrbitButton(tr("Запустить в Claude Code", "Run in Claude Code"), icon: "play", kind: .primary) {
                    if let pid = signal?.projectId { app.runAgent(pid, prompt: text) }
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(Theme.surface)
        .onAppear { text = makeBrief(signal) }
    }

    private func makeBrief(_ signal: Signal?) -> String {
        guard let signal, let snap = app.snapshots[signal.projectId] else { return "" }
        let recent = snap.sessions.prefix(3)
        var files = Set<String>()
        for s in recent { for f in s.filesTouched { files.insert(SessionAnalyzer.relative(f, session: s)) } }
        let task = recent.first?.firstPrompt ?? ""
        var lines = [
            tr("## Задача", "## Task"),
            task.isEmpty ? tr("<опишите, что нужно сделать>", "<describe what needs to be done>") : String(task.prefix(400)),
            "",
            tr("## Контекст", "## Context"),
            tr("Прошлые \(Plural.sessions(recent.count)) не довели задачу до коммита: правки откатывались.", "The last \(Plural.sessions(recent.count)) didn’t get the task to a commit: edits kept being reverted."),
        ]
        if let stuck = recent.first.flatMap(InsightEngine.stuck) { lines.append(stuck) }
        if !files.isEmpty {
            lines += ["", tr("## Файлы", "## Files"), files.sorted().prefix(10).map { "- \($0)" }.joined(separator: "\n")]
        }
        lines += [
            "",
            tr("## Критерий готовности", "## Definition of done"),
            tr("- <что должно работать>", "- <what should work>"),
            tr("- тесты зелёные, изменения закоммичены", "- tests are green, changes are committed"),
            "",
            tr("## Ограничения", "## Constraints"),
            tr("- не откатывай чужие изменения без вопроса", "- don’t revert other people’s changes without asking"),
            tr("- если два подхода не сработали — остановись и опиши, что мешает", "- if two approaches fail, stop and describe what’s blocking you"),
        ]
        return lines.joined(separator: "\n")
    }
}
