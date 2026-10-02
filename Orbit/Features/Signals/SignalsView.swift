import SwiftUI

struct SignalsView: View {
    @Environment(AppState.self) private var app
    @State private var tab: SignalState = .active

    var body: some View {
        let resolvedMonth = app.signals.filter { $0.state == .resolved && ($0.resolvedAt ?? .distantPast) > app.now.addingTimeInterval(-30 * 86400) }
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(eyebrow: "Проверка каждые 15 минут · \(resolvedMonth.count) решено за месяц", title: "Сигналы") {
                SegmentedTabs(items: [
                    (SignalState.active, "Активные · \(count(.active))"),
                    (.snoozed, "Отложенные · \(count(.snoozed))"),
                    (.resolved, "Решённые · \(count(.resolved))"),
                ], selection: $tab)
            }
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        let list = app.signals.filter { $0.state == tab }
                        if list.isEmpty {
                            emptyState.frame(minHeight: 620)
                        } else if tab == .resolved {
                            ForEach(list) { s in resolvedRow(s) }
                        } else {
                            ForEach(list) { s in SignalCard(signal: s) }
                        }
                        if tab == .active && !list.isEmpty && !resolvedMonth.isEmpty {
                            Eyebrow(text: "Недавно решено").padding(.top, 10)
                            ForEach(resolvedMonth.prefix(4)) { s in resolvedRow(s) }
                        }
                    }
                }
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
            Text(tab == .active ? "Всё спокойно" : tab == .snoozed ? "Отложенных нет" : "Пока ничего не решено").uiFont(22, .semibold)
            if tab == .active {
                Text("Ветки свежие, изменения закоммичены, агенты не буксуют.\nПоследняя проверка — \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "ещё не было").")
                    .uiFont(14, color: Theme.text2).multilineTextAlignment(.center).lineSpacing(5)
                HStack(spacing: 22) {
                    check(Plural.repos(app.config.activeProjects.count))
                    check(Plural.sessions(app.sessions.filter { $0.start > app.now.addingTimeInterval(-30 * 86400) }.count))
                    check("тесты зелёные")
                }
                .padding(.top, 6)
                OrbitButton(app.isSyncing ? "Проверяем…" : "Проверить сейчас", icon: "arrow.clockwise") { Task { await app.refresh() } }
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
                        Text("· обнаружено \(DateFormat.relativeDay(s.detectedAt))").uiFont(12.5, color: Theme.text3)
                        Spacer()
                        if s.state == .snoozed {
                            Button { app.unsnooze(s.id) } label: {
                                Label("Вернуть", systemImage: "bell").uiFont(12.5, color: Theme.text2)
                            }
                            .buttonStyle(PlainButtonStyle2())
                        } else {
                            Menu {
                                Button("На день") { app.snooze(s.id, days: 1) }
                                Button("На 3 дня") { app.snooze(s.id, days: 3) }
                                Button("На неделю") { app.snooze(s.id, days: 7) }
                            } label: {
                                Label("Отложить", systemImage: "bell.slash").uiFont(12.5, color: Theme.text2)
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
            OrbitButton("Rebase с агентом", icon: "sparkles", kind: .primary) {
                app.runAgent(pid, prompt: "Сделай rebase ветки \(repo?.branch ?? "") на \(repo?.mainBranch ?? "main"). Разреши конфликты, сохрани смысл обеих сторон, прогони тесты и покажи итог перед push.")
            }
            OrbitButton("Перенести день", icon: "calendar") { app.sheet = .planner(weekKey: app.currentWeekKey) }
        case .agentReverts:
            OrbitButton("Составить бриф для агента", icon: "doc.text", kind: .primary) { app.sheet = .brief(signalId: s.id) }
            OrbitButton("Сессии", icon: "eye") {
                app.sessionFilterProject = pid
                app.screen = .sessions
            }
        case .uncommitted:
            OrbitButton("Закоммитить", icon: "point.topleft.down.to.point.bottomright.curvepath", kind: .primary) { app.sheet = .commit(projectId: pid) }
            OrbitButton("Посмотреть дифф", icon: "chevron.left.forwardslash.chevron.right") { app.sheet = .diff(projectId: pid) }
        case .testsFailing:
            OrbitButton("Починить с агентом", icon: "sparkles", kind: .primary) {
                let test = app.snapshots[pid]?.lastTestedSession?.lastFailingTest.map { " (\($0))" } ?? ""
                app.runAgent(pid, prompt: "В проекте падают тесты\(test). Запусти тесты, найди причину и почини. Не меняй тесты без необходимости.")
            }
            OrbitButton("Терминал", icon: "terminal") { app.openTerminal(pid) }
        case .idle:
            OrbitButton("Запланировать", icon: "calendar.badge.plus", kind: .primary) { app.sheet = .planner(weekKey: app.currentWeekKey) }
            OrbitButton("В архив", icon: "archivebox") { app.updateProject(pid) { $0.archived = true } }
        case .skippedDay:
            OrbitButton("Перенести блок", icon: "calendar", kind: .primary) { app.sheet = .planner(weekKey: app.currentWeekKey) }
        case .tokens:
            OrbitButton("Сессии", icon: "eye", kind: .primary) {
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
                Text("Правила мониторинга").uiFont(15, .semibold)
                Text("Когда Orbit должен поднимать сигнал").uiFont(12.5, color: Theme.text3)
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
                    OrbitToggle(isOn: Binding(get: { rule.enabled }, set: { app.setRule(rule.kind, enabled: $0) }))
                }
                .padding(.vertical, 14)
                .hairline()
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Куда отправлять").uiFont(13, .semibold, color: Theme.text2)
                HStack(spacing: 8) {
                    channel("desktopcomputer", "macOS", on: app.config.notifyMacOS) {
                        app.config.notifyMacOS.toggle()
                        app.saveConfig()
                    }
                    channel("paperplane", "Telegram", on: false, disabled: true) {}
                    channel("envelope", "Почта", on: false, disabled: true) {}
                }
                Text(app.config.rhythm.morningBrief ? "Утренняя сводка в 9:00 перед началом дня · Telegram и почта — скоро" : "Утренняя сводка выключена")
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
                Image(systemName: icon).font(.system(size: 11))
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
        .help(disabled ? "Будет во второй фазе" : "")
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
            Text("Бриф для агента · \(signal.map { app.projectName($0.projectId) } ?? "")").uiFont(18, .semibold)
            Text("Заполните цель и критерий готовности — агенту станет понятно, когда остановиться.").uiFont(13, color: Theme.text2)
            TextEditor(text: $text)
                .font(OrbitFont.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 340)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            HStack {
                OrbitButton("Скопировать", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    app.toast = "Бриф скопирован"
                }
                if app.config.ai.isEnabled {
                    OrbitButton(generating ? "Пишу…" : "Составить с ИИ", icon: "sparkles") {
                        generating = true
                        Task {
                            do { text = try await app.aiBrief(signalId) } catch { app.toast = error.localizedDescription }
                            generating = false
                        }
                    }
                    .disabled(generating)
                }
                Spacer()
                OrbitButton("Отмена") { dismiss() }
                OrbitButton("Запустить в Claude Code", icon: "play", kind: .primary) {
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
            "## Задача",
            task.isEmpty ? "<опишите, что нужно сделать>" : String(task.prefix(400)),
            "",
            "## Контекст",
            "Прошлые \(Plural.sessions(recent.count)) не довели задачу до коммита: правки откатывались.",
        ]
        if let stuck = recent.first.flatMap(InsightEngine.stuck) { lines.append(stuck) }
        if !files.isEmpty {
            lines += ["", "## Файлы", files.sorted().prefix(10).map { "- \($0)" }.joined(separator: "\n")]
        }
        lines += [
            "",
            "## Критерий готовности",
            "- <что должно работать>",
            "- тесты зелёные, изменения закоммичены",
            "",
            "## Ограничения",
            "- не откатывай чужие изменения без вопроса",
            "- если два подхода не сработали — остановись и опиши, что мешает",
        ]
        return lines.joined(separator: "\n")
    }
}
