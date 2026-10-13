import SwiftUI

/// "Выкатить": what goes out and which steps run, then the steps live with their output, then the history.
struct DeploySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var serverId: UUID

    @State private var preview: DeployPreview?
    @State private var loading = false
    /// The run on screen; nil shows the "ready to deploy" page.
    @State private var shownRun: UUID?
    @State private var selectedStep = 0
    /// Follows the running step until the user picks one by hand.
    @State private var following = true
    @State private var log = ""
    @State private var confirmRollback = false

    #if DEBUG
    /// Set by the snapshot tool: the preview to show, and the run to open.
    nonisolated(unsafe) static var debugPreview: DeployPreview?
    nonisolated(unsafe) static var debugRun: UUID?
    #endif

    var body: some View {
        let ref = app.serverRef(serverId)
        let run = shownRun.flatMap { id in app.deployRuns.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 0) {
            header(ref, run)
            if let ref {
                if let run {
                    runPage(run)
                } else {
                    readyPage(ref.server)
                }
                footer(ref.server, run)
            } else {
                EmptyHint(symbol: "server.rack", title: tr("Сервер не найден", "Server not found"), text: "").frame(maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 660)
        .background(Theme.surface)
        .onAppear(perform: start)
        .onChange(of: run?.steps.map(\.state)) { follow(run) }
        .task(id: "\(shownRun?.uuidString ?? "")-\(selectedStep)") { await tail() }
        .confirmationDialog(tr("Откатить на прошлую версию?", "Roll back to the previous version?"), isPresented: $confirmRollback) {
            Button(tr("Откатить", "Roll back")) {
                app.startRollback(serverId)
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    show(app.activeRun(serverId)?.id)
                }
            }
            Button(tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Код вернётся на \(String((app.rollbackTarget(serverId) ?? "").prefix(7))), шаги на сервере выполнятся заново. Изменения в базе данных не откатываются.",
                    "The code goes back to \(String((app.rollbackTarget(serverId) ?? "").prefix(7))) and the server steps run again. Database changes are not rolled back."))
        }
    }

    // MARK: - Header and footer

    private func header(_ ref: AppState.ServerRef?, _ run: DeployRun?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(run?.trigger == .rollback ? tr("Откат", "Rollback") : tr("Выкладка", "Deploy")).uiFont(18, .semibold)
                if let ref {
                    HStack(spacing: 8) {
                        ProjectLabel(projectId: ref.projectId, size: 12.5, color: Theme.text2)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.text3)
                        Text("\(ref.server.name) · \(ref.server.host)").monoFont(12.5, color: Theme.text2).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let run {
                HStack(spacing: 7) {
                    Image(systemName: DeployText.symbol(run.state)).font(.system(size: 12)).foregroundStyle(DeployText.color(run.state))
                        .symbolEffect(.rotate, options: .repeating, isActive: run.state == .running && !Motion.reduced)
                    if run.state == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(tr("Идёт · \(Elapsed.text(context.date.timeIntervalSince(run.startedAt)))", "Running · \(Elapsed.text(context.date.timeIntervalSince(run.startedAt)))"))
                                .uiFont(12.5, .medium, color: DeployText.color(run.state)).monospacedDigit()
                        }
                    } else {
                        Text(summary(run)).uiFont(12.5, .medium, color: DeployText.color(run.state))
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 11)
                .background(DeployText.color(run.state).opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
        .hairline()
    }

    private func summary(_ run: DeployRun) -> String {
        let state = DeployText.state(run)
        let text = state.prefix(1).uppercased() + state.dropFirst()
        return run.seconds.map { "\(text) · \(Elapsed.text($0))" } ?? String(text)
    }

    private func footer(_ server: ServerConfig, _ run: DeployRun?) -> some View {
        let history = app.runs(serverId)
        return HStack(spacing: 10) {
            if !history.isEmpty {
                MenuChip(icon: "clock", title: tr("История · \(history.count)", "History · \(history.count)")) {
                    ForEach(history.prefix(25)) { r in
                        Button("\(DateFormat.relativeDay(r.startedAt)) · \(DeployText.state(r))\(r.shortTo.map { " · \($0)" } ?? "") · \(r.trigger.title)") { show(r.id) }
                    }
                }
            }
            Spacer()
            if let run {
                if run.state == .running {
                    OrbitButton(tr("Остановить", "Stop"), icon: "stop") { app.cancelDeploy(serverId) }
                } else {
                    if run.id == app.lastRun(serverId)?.id, run.state != .success, app.rollbackTarget(serverId) != nil, !app.isDeploying(serverId) {
                        OrbitButton(tr("Откатить на прошлую версию", "Roll back to the previous version"), icon: "arrow.counterclockwise") { confirmRollback = true }
                    }
                    OrbitButton(tr("Новая выкладка", "New deploy"), icon: "arrow.up") { show(nil) }
                }
                OrbitButton(tr("Закрыть", "Close"), kind: run.state == .running ? .secondary : .primary) { dismiss() }
            } else {
                OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
                OrbitButton(preview?.upToDate == true ? tr("Выкатить заново", "Deploy again") : tr("Запустить", "Start"), icon: "play", kind: .primary) { launch() }
                    .disabled(loading || preview == nil || preview?.problem != nil || app.isDeploying(serverId))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .hairline(.top)
    }

    // MARK: - Ready

    private func readyPage(_ server: ServerConfig) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tr("Смотрю, что в ветке \(server.branch) на GitHub и что стоит на сервере…", "Looking at branch \(server.branch) on GitHub and at what the server runs…"))
                            .uiFont(13, color: Theme.text2)
                    }
                    .padding(.vertical, 6)
                } else if let preview {
                    if let problem = preview.problem { note(problem, color: Theme.red, icon: "xmark.octagon") }
                    if let warning = preview.warning { note(warning, color: Theme.yellow, icon: "exclamationmark.triangle") }
                    if preview.problem == nil { outgoing(preview, server) }
                }
                plan(server)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.pick(Motion.content), value: loading)
    }

    private func note(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color).padding(.top, 1)
            Text(text).uiFont(13, color: Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func outgoing(_ p: DeployPreview, _ server: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Что уйдёт на сервер", "What goes to the server")).uiFont(13.5, .semibold)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(String((p.target ?? "").prefix(7))).monoFont(13, .semibold, color: Theme.accent)
                    Text(p.subject ?? "").uiFont(13.5).lineLimit(1)
                    Spacer(minLength: 8)
                    Tag(text: server.branch, color: Theme.text2, mono: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .hairline()
                if p.upToDate {
                    row(tr("На сервере уже стоит эта версия. Можно выкатить заново — шаги выполнятся ещё раз.", "The server already runs this version. You can deploy again — the steps run once more."))
                } else if let commits = p.commits, !commits.isEmpty {
                    ForEach(commits.prefix(8)) { c in
                        HStack(spacing: 12) {
                            Text(c.shortHash).monoFont(12, color: Theme.text3)
                            Text(c.subject).uiFont(13, color: Theme.text2).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(c.author) · \(DateFormat.relativeDay(c.date, withTime: false))").uiFont(12, color: Theme.text3).lineLimit(1)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .hairline()
                    }
                    row(commits.count > 8 ? tr("и ещё \(commits.count - 8) · сейчас на сервере \(String((p.current ?? "").prefix(7)))", "and \(commits.count - 8) more · the server runs \(String((p.current ?? "").prefix(7))) now")
                                          : tr("\(Plural.commits(commits.count)) · сейчас на сервере \(String((p.current ?? "").prefix(7)))", "\(Plural.commits(commits.count)) · the server runs \(String((p.current ?? "").prefix(7))) now"))
                } else if let current = p.current {
                    row(tr("Сейчас на сервере \(String(current.prefix(7))). Список коммитов показать не могу: этого коммита нет в локальном репозитории.",
                           "The server runs \(String(current.prefix(7))) now. The commit list is unavailable: that commit isn’t in the local repository."))
                } else {
                    row(tr("Что сейчас стоит на сервере, узнать не получилось.", "Couldn’t find out what the server runs now."))
                }
            }
            .cardStyle(radius: 10, fill: Theme.bg)
        }
    }

    private func row(_ text: String) -> some View {
        Text(text).uiFont(12.5, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func plan(_ server: ServerConfig) -> some View {
        let steps = DeployPipeline.plan(server, target: preview?.target, previous: preview?.current)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Шаги", "Steps")).uiFont(13.5, .semibold)
                Spacer()
                Button { app.sheet = .serverSetup(projectId: app.serverRef(serverId)?.projectId ?? "", serverId: serverId) } label: {
                    Text(tr("Изменить шаги", "Edit steps")).uiFont(12.5, color: Theme.text2)
                }
                .buttonStyle(PlainButtonStyle2())
            }
            if !server.hasBackup {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 13)).foregroundStyle(Theme.yellow)
                    Text(tr("Перед этой выкладкой резервная копия не делается.", "No backup is made before this deploy.")).uiFont(13)
                    Spacer(minLength: 8)
                    OrbitButton(tr("Добавить шаг", "Add the step"), icon: "plus", compact: true) { withMotion { app.addBackupStep(serverId) } }
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(Theme.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .transition(Motion.transition(.opacity))
            }
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)").monoFont(12, color: Theme.text3).frame(width: 18, alignment: .trailing)
                        Text(step.run.name).uiFont(13, .medium).lineLimit(1).frame(width: 170, alignment: .leading)
                        Text(describe(step)).monoFont(11.5, color: Theme.text3).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Tag(text: step.run.place.title, color: step.run.place == .mac ? Theme.violet : Theme.cyan)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .overlay(alignment: .bottom) { if i < steps.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            .cardStyle(radius: 10, fill: Theme.bg)
        }
    }

    private func describe(_ step: PlannedStep) -> String {
        switch step.action {
        case .connect: return tr("ssh, папка проекта, текущая версия", "ssh, the project folder, the current version")
        case .verify: return tr("сайт отвечает, всё запущено", "the site answers, everything runs")
        case .local(let command): return command.replacingOccurrences(of: "\n", with: " ; ")
        case .remote:
            let steps = app.serverRef(serverId)?.server.steps.filter(\.enabled) ?? []
            let source = steps.first { $0.kind != .code && ($0.name.isEmpty ? $0.command : $0.name) == step.run.name }
            let command = source?.command.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ; ") ?? ""
            if source?.kind == .backup {
                return command.isEmpty ? tr("настройки и версия → ~/orbit-backups на сервере", "settings and the version → ~/orbit-backups on the server") : command
            }
            return source == nil ? tr("git fetch, перемотка до выкатываемого коммита", "git fetch, fast-forward to the commit being deployed") : command
        }
    }

    // MARK: - Run

    private func runPage(_ run: DeployRun) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(run.steps.enumerated()), id: \.element.id) { i, step in
                        Button {
                            selectedStep = i
                            following = step.state == .running
                        } label: { stepRow(step, selected: i == selectedStep) }
                            .buttonStyle(PlainButtonStyle2())
                    }
                    if let commit = run.shortTo {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.trigger == .rollback ? tr("Возврат на", "Back to") : tr("Коммит", "Commit")).uiFont(11.5, color: Theme.text3)
                            Text("\(commit) \(run.toSubject ?? "")").monoFont(11.5, color: Theme.text2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            Text("\(DateFormat.relativeDay(run.startedAt)) · \(run.trigger.title)").uiFont(11.5, color: Theme.text3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }

            LogPane(text: log, placeholder: placeholder(run))
        }
        .frame(maxHeight: .infinity)
    }

    private func placeholder(_ run: DeployRun) -> String {
        guard run.steps.indices.contains(selectedStep) else { return "" }
        switch run.steps[selectedStep].state {
        case .pending: return tr("Шаг ещё не начался.", "The step hasn’t started yet.")
        case .skipped: return tr("Шаг пропущен: выкладка остановилась раньше.", "The step was skipped: the deploy stopped earlier.")
        case .running: return tr("Жду вывод…", "Waiting for output…")
        default: return tr("Шаг ничего не вывел.", "The step printed nothing.")
        }
    }

    private func stepRow(_ step: StepRun, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                stateIcon(step.state).frame(width: 16)
                Text(step.name).uiFont(13, .medium, color: step.state == .pending || step.state == .skipped ? Theme.text3 : Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                if let s = step.seconds, step.state != .skipped {
                    Text(Elapsed.text(s)).monoFont(11.5, color: Theme.text3)
                } else if step.state == .running, let started = step.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Elapsed.text(context.date.timeIntervalSince(started))).monoFont(11.5, color: Theme.accent)
                    }
                }
                Text(step.place.title).uiFont(10.5, .medium, color: Theme.text3)
            }
            if step.state == .failed, let note = step.note, !note.isEmpty {
                Text(note).uiFont(12, color: Theme.red).lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.surface2 : .clear)
        .hairline()
    }

    @ViewBuilder
    private func stateIcon(_ state: StepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.green)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.red)
        case .skipped: Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(Theme.text3)
        case .cancelled: Image(systemName: "stop.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.yellow)
        }
    }

    // MARK: - Behaviour

    private func start() {
        #if DEBUG
        if let run = Self.debugRun { show(run); return }
        if let fixture = Self.debugPreview { preview = fixture; return }
        #endif
        if let active = app.activeRun(serverId) {
            show(active.id)
        } else {
            loadPreview()
        }
    }

    private func loadPreview() {
        loading = true
        Task {
            preview = await app.deployPreview(serverId)
            loading = false
        }
    }

    private func show(_ runId: UUID?) {
        shownRun = runId
        following = true
        log = ""
        guard let runId, let run = app.deployRuns.first(where: { $0.id == runId }) else {
            if runId == nil, preview == nil || !loading { loadPreview() }
            return
        }
        // A finished run opens on the step that failed; a live one on the step that is running.
        selectedStep = run.steps.firstIndex { $0.state == .running || $0.state == .failed || $0.state == .cancelled } ?? max(0, run.steps.count - 1)
    }

    private func follow(_ run: DeployRun?) {
        guard following, let run, let i = run.steps.firstIndex(where: { $0.state == .running || $0.state == .failed }) else { return }
        selectedStep = i
    }

    private func launch() {
        guard let preview, let target = preview.target else { return }
        if let id = app.startDeploy(serverId, target: target, subject: preview.subject, trigger: .manual) { show(id) }
    }

    /// Re-reads the selected step's log while that step runs.
    private func tail() async {
        guard let runId = shownRun else { return }
        let step = selectedStep
        let url = app.stepLogURL(runId, step: step)
        while !Task.isCancelled {
            let text = await Task.detached { LogText.tail(url, bytes: 60_000) }.value
            if text != log { log = text }
            let state = app.deployRuns.first { $0.id == runId }?.steps[safe: step]?.state
            guard state == .running || state == .pending else { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Monospaced output that sticks to the bottom as it grows.
struct LogPane: View {
    var text: String
    var placeholder: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty {
                        Text(placeholder).uiFont(12.5, color: Theme.text3)
                    } else {
                        Text(text).monoFont(11.5, color: Theme.text2).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
