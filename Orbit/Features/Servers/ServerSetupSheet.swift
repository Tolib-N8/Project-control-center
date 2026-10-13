import SwiftUI

/// Add or edit a production server: where it is, what runs there, and the steps of a deploy.
struct ServerSetupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: String
    var serverId: UUID?

    @State private var draft = ServerConfig(name: "")
    @State private var port = ""
    @State private var loaded = false
    @State private var test: TestState = .idle
    @State private var confirmDelete = false

    enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(SSHProblem, String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(serverId == nil ? tr("Новый сервер", "New server") : tr("Сервер", "Server")).uiFont(18, .semibold)
                Text(tr("Боевой сервер проекта \(app.projectName(projectId)): Orbit следит за ним и выкатывает на него по SSH",
                        "A production server of \(app.projectName(projectId)): Orbit watches it and deploys to it over SSH"))
                    .uiFont(12.5, color: Theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            .hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    connection
                    siteAndBranch
                    runtime
                    steps
                    options
                }
                .padding(28)
            }
            .scrollIndicators(.automatic)

            HStack(spacing: 10) {
                if serverId != nil {
                    Button { confirmDelete = true } label: { Text(tr("Удалить сервер", "Remove server")).uiFont(13, .medium, color: Theme.red) }
                        .buttonStyle(PlainButtonStyle2())
                        .padding(.horizontal, 6)
                }
                Spacer()
                if let problem = draftToSave.problem {
                    Text(problem).uiFont(12, color: Theme.text3).lineLimit(1)
                }
                OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
                OrbitButton(tr("Сохранить", "Save"), icon: "checkmark", kind: .primary) {
                    app.saveServer(projectId, draftToSave)
                    dismiss()
                }
                .disabled(draftToSave.problem != nil)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .hairline(.top)
        }
        .frame(width: 720, height: 780)
        .background(Theme.surface)
        .onAppear(perform: load)
        .confirmationDialog(tr("Удалить сервер «\(draft.name)» из Orbit?", "Remove server “\(draft.name)” from Orbit?"), isPresented: $confirmDelete) {
            Button(tr("Удалить", "Remove"), role: .destructive) {
                if let serverId { app.removeServer(serverId) }
                dismiss()
            }
            Button(tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("На самом сервере ничего не изменится. Orbit забудет его настройки и историю выкладок.",
                    "Nothing changes on the server itself. Orbit forgets its settings and deploy history."))
        }
    }

    /// The draft as it would be saved: trimmed, with the port parsed.
    private var draftToSave: ServerConfig {
        var s = draft
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if s.name.isEmpty { s.name = tr("Основной", "Production") }
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.directory = s.directory.trimmingCharacters(in: .whitespaces)
        s.branch = s.branch.trimmingCharacters(in: .whitespaces)
        s.url = (s.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : s.url?.trimmingCharacters(in: .whitespaces)
        s.unit = s.runtime == .systemd ? s.unit?.trimmingCharacters(in: .whitespaces) : nil
        s.port = Int(port.trimmingCharacters(in: .whitespaces))
        return s
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let serverId, let ref = app.serverRef(serverId) {
            draft = ref.server
        } else {
            let template = DeployTemplate.detect(projectPath: projectId)
            let count = app.servers(for: projectId).count
            draft = ServerConfig(name: count == 0 ? tr("Основной", "Production") : tr("Сервер \(count + 1)", "Server \(count + 1)"),
                                 branch: app.repos[projectId]?.mainBranch ?? "main", runtime: template.runtime, steps: template.steps)
        }
        port = draft.port.map(String.init) ?? ""
    }

    // MARK: - Sections

    private var connection: some View {
        section(tr("Подключение", "Connection")) {
            HStack(alignment: .top, spacing: 12) {
                field(tr("Название", "Name"), text: $draft.name, prompt: tr("Основной", "Production")).frame(width: 190)
                field(tr("Адрес", "Address"), text: $draft.host, prompt: "root@203.0.113.10", mono: true)
                field(tr("Порт", "Port"), text: $port, prompt: "22", mono: true).frame(width: 76)
            }
            field(tr("Папка проекта на сервере", "Project folder on the server"), text: $draft.directory, prompt: "/opt/app", mono: true)
            HStack(alignment: .top, spacing: 12) {
                OrbitButton(test == .running ? tr("Проверяю…", "Checking…") : tr("Проверить подключение", "Test the connection"), icon: "bolt", compact: true) { runTest() }
                    .disabled(test == .running || draftToSave.problem != nil || !app.serverChecksAllowed)
                testResult
                Spacer(minLength: 0)
            }
            .animation(Motion.pick(Motion.content), value: test)
        }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle:
            Text(tr("Адрес — как в команде ssh: пользователь@сервер или имя из ~/.ssh/config. Пароль Orbit не спрашивает и не хранит.",
                    "The address is what you pass to ssh: user@server or a name from ~/.ssh/config. Orbit never asks for or stores a password."))
                .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        case .running:
            ProgressView().controlSize(.small).padding(.top, 4)
        case .ok(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.green).padding(.top, 2)
                Text(text).uiFont(12.5, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let problem, let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.red).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.title).uiFont(13, .semibold)
                        Text(problem.hint).uiFont(12.5, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                        if !message.isEmpty, problem != .auth { Text(message).monoFont(11.5, color: Theme.text3).lineLimit(2).textSelection(.enabled) }
                    }
                }
                if problem == .auth {
                    OrbitButton(tr("Положить ключ на сервер", "Install a key on the server"), icon: "key", compact: true) { app.installKey(draftToSave) }
                    Text(tr("Откроется Терминал и один раз спросит пароль сервера. Потом нажмите «Проверить подключение» ещё раз.",
                            "Terminal opens and asks for the server password once. Then press “Test the connection” again."))
                        .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var siteAndBranch: some View {
        section(tr("Сайт и ветка", "Site and branch")) {
            HStack(alignment: .top, spacing: 12) {
                field(tr("Адрес сайта", "Site address"), text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0 }), prompt: "https://example.ru", mono: true)
                field(tr("Боевая ветка", "Production branch"), text: $draft.branch, prompt: "main", mono: true).frame(width: 240)
            }
            Text(tr("Orbit раз в пару минут открывает этот адрес и смотрит, отвечает ли сайт. Выкатывается последний коммит боевой ветки с GitHub.",
                    "Every couple of minutes Orbit opens this address to see whether the site answers. A deploy ships the latest commit of the production branch on GitHub."))
                .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtime: some View {
        section(tr("Что запущено на сервере", "What runs on the server")) {
            HStack(spacing: 12) {
                SegmentedTabs(items: ServerRuntime.allCases.map { ($0, $0.title) }, selection: $draft.runtime)
                if draft.runtime == .systemd {
                    TextField("", text: Binding(get: { draft.unit ?? "" }, set: { draft.unit = $0 }), prompt: Text("myapp").foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain).font(OrbitFont.mono(12.5))
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                        .frame(width: 200)
                        .transition(Motion.transition(.opacity))
                }
                Spacer(minLength: 0)
            }
            Text(runtimeNote).uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .animation(Motion.pick(Motion.content), value: draft.runtime)
    }

    private var runtimeNote: String {
        switch draft.runtime {
        case .compose: tr("Orbit смотрит контейнеры через «docker compose ps» в папке проекта и читает их журнал.", "Orbit reads the containers with “docker compose ps” in the project folder, and their log.")
        case .systemd: tr("Orbit смотрит состояние службы через systemctl и читает её журнал через journalctl.", "Orbit reads the service state with systemctl and its log with journalctl.")
        case .none: tr("Orbit следит только за сайтом и ресурсами сервера; журнала не будет.", "Orbit watches only the site and the server’s resources; there is no log.")
        }
    }

    private var steps: some View {
        section(tr("Шаги выкладки", "Deploy steps")) {
            VStack(spacing: 0) {
                fixedRow(tr("Подключение", "Connect"), tr("SSH работает, папка на месте; запоминается версия для отката", "SSH works, the folder is there; the version is remembered for rollback"))
                ForEach($draft.steps) { $step in
                    StepRow(step: $step, branch: draft.branch,
                            canMoveUp: draft.steps.first?.id != step.id, canMoveDown: draft.steps.last?.id != step.id,
                            move: { move(step.id, by: $0) },
                            remove: { withMotion { draft.steps.removeAll { $0.id == step.id } } })
                        .transition(Motion.transition(.opacity.combined(with: .offset(y: -6))))
                }
                fixedRow(tr("Проверка", "Check"), tr("до 90 секунд ждёт, что сайт отвечает и всё запущено", "waits up to 90 seconds for the site to answer and everything to run"), last: true)
            }
            .cardStyle(radius: 10, fill: Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                OrbitButton(tr("Шаг на сервере", "Server step"), icon: "plus", compact: true) {
                    withMotion { draft.steps.append(DeployStep(name: "", place: .server)) }
                }
                OrbitButton(tr("Шаг на Mac", "Mac step"), icon: "plus", compact: true) {
                    withMotion { draft.steps.insert(DeployStep(name: "", place: .mac), at: draft.steps.firstIndex { $0.kind == .code } ?? 0) }
                }
                if !draft.steps.contains(where: { $0.kind == .code }) {
                    OrbitButton(tr("Обновление кода", "Code update"), icon: "plus", compact: true) { withMotion { draft.steps.insert(.code(), at: 0) } }
                }
                if !draft.steps.contains(where: { $0.kind == .backup }) {
                    OrbitButton(tr("Резервная копия", "Backup"), icon: "plus", compact: true) { withMotion { insertBackup() } }
                }
                Spacer()
                OrbitButton(tr("Предложить по проекту", "Suggest from the project"), kind: .ghost, compact: true) {
                    withMotion { draft.steps = DeployTemplate.detect(projectPath: projectId).steps }
                }
            }
            Text(tr("Шаги идут сверху вниз; ошибка останавливает выкладку. Шаги на Mac выполняются в чистой копии выкатываемого коммита, шаги на сервере — в папке проекта. Доступны $ORBIT_COMMIT, $ORBIT_PREVIOUS и $ORBIT_BRANCH.",
                    "Steps run top to bottom; an error stops the deploy. Mac steps run in a clean copy of the commit being deployed, server steps in the project folder. $ORBIT_COMMIT, $ORBIT_PREVIOUS and $ORBIT_BRANCH are available."))
                .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: some View {
        section(tr("Поведение", "Behaviour")) {
            option(tr("Следить за сервером", "Watch the server"),
                   tr("Сайт каждые 2 минуты, сервер каждые 5 — пока Mac включён и Orbit запущен. Если что-то упало, придёт сигнал", "The site every 2 minutes, the server every 5 — while the Mac is on and Orbit runs. A signal arrives when something goes down"),
                   isOn: $draft.monitor)
            option(tr("Выкатывать автоматически", "Deploy automatically"),
                   tr("Новый коммит в ветке \(draft.branch.isEmpty ? "main" : draft.branch) на GitHub уйдёт на сервер без вопросов. Один коммит — одна попытка: после ошибки Orbit сам не повторяет",
                      "A new commit on branch \(draft.branch.isEmpty ? "main" : draft.branch) on GitHub goes to the server without asking. One commit, one attempt: after an error Orbit doesn’t retry by itself"),
                   isOn: $draft.autoDeploy)
        }
    }

    // MARK: - Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).uiFont(13.5, .semibold)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).uiFont(12, color: Theme.text3)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.text3))
                .textFieldStyle(.plain)
                .font(mono ? OrbitFont.mono(12.5) : OrbitFont.ui(13))
                .autocorrectionDisabled()
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .onChange(of: text.wrappedValue) { test = .idle }
        }
    }

    private func fixedRow(_ title: String, _ note: String, last: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Theme.text3).frame(width: 18)
            Text(title).uiFont(13, .medium, color: Theme.text2).frame(width: 150, alignment: .leading)
            Text(note).uiFont(12, color: Theme.text3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    private func option(_ title: String, _ note: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).uiFont(13.5, .medium)
                Text(note).uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            OrbitToggle(isOn: isOn)
        }
    }

    /// Before the first step that changes the server, with the database dump the project's compose file suggests.
    private func insertBackup() {
        draft.addBackup(DeployTemplate.detect(projectPath: projectId).steps.first { $0.kind == .backup } ?? .backup())
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(i + delta) else { return }
        withMotion { draft.steps.swapAt(i, i + delta) }
    }

    private func runTest() {
        let server = draftToSave
        test = .running
        Task {
            let r = await Task.detached { ServerProbe.host(server) }.value
            if let problem = r.problem {
                test = .failed(problem, r.message ?? "")
            } else if let facts = r.facts {
                var parts = [tr("Подключение есть.", "Connected.")]
                if let c = facts.shortCommit {
                    parts.append(tr("На сервере \(c)\(facts.branch.map { " в ветке \($0)" } ?? "").", "The server runs \(c)\(facts.branch.map { " on branch \($0)" } ?? "")."))
                } else {
                    parts.append(tr("В папке нет git-репозитория — обновление кода работать не будет.", "No git repository in the folder — the code update won’t work."))
                }
                if let error = facts.runtimeError {
                    parts.append(error.prefix(1).uppercased() + error.dropFirst() + ".")
                } else if !facts.services.isEmpty {
                    parts.append(tr("Запущено: \(facts.services.filter(\.ok).count) из \(facts.services.count).", "Running: \(facts.services.filter(\.ok).count) of \(facts.services.count)."))
                }
                test = .ok(parts.joined(separator: " "))
            } else {
                test = .failed(.other, "")
            }
        }
    }
}

private struct StepRow: View {
    @Binding var step: DeployStep
    var branch: String
    var canMoveUp: Bool
    var canMoveDown: Bool
    var move: (Int) -> Void
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    arrow("chevron.up", enabled: canMoveUp) { move(-1) }
                    arrow("chevron.down", enabled: canMoveDown) { move(1) }
                }
                .frame(width: 18)
                if step.kind == .code {
                    Text(tr("Код", "Code")).uiFont(13, .medium, color: step.enabled ? Theme.text : Theme.text3).frame(width: 150, alignment: .leading).padding(.top, 5)
                    Text(tr("git fetch и перемотка ветки \(branch.isEmpty ? "main" : branch) до выкатываемого коммита", "git fetch and a fast-forward of branch \(branch.isEmpty ? "main" : branch) to the commit being deployed"))
                        .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    Spacer(minLength: 0)
                } else if step.kind == .backup {
                    Text(tr("Резервная копия", "Backup")).uiFont(13, .medium, color: step.enabled ? Theme.text : Theme.text3).frame(width: 150, alignment: .leading).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("", text: $step.command, prompt: Text(tr("команда для дампа базы — если она есть", "the database dump command — if there is one")).foregroundStyle(Theme.text3), axis: .vertical)
                            .textFieldStyle(.plain).font(OrbitFont.mono(12))
                            .lineLimit(1...5)
                            .autocorrectionDisabled()
                            .padding(.vertical, 6).padding(.horizontal, 9)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(warning == nil ? Theme.border : Theme.red.opacity(0.7)))
                        Text(tr("Настройки (.env, compose) и номер версии Orbit сохраняет сам — в ~/orbit-backups на сервере, последние \(BackupTemplate.keep) копий. Дамп кладите в $ORBIT_BACKUP_DIR; пустой дамп остановит выкладку.",
                                "Orbit saves the settings (.env, compose) and the version by itself — to ~/orbit-backups on the server, the last \(BackupTemplate.keep) copies. Put the dump into $ORBIT_BACKUP_DIR; an empty dump stops the deploy."))
                            .uiFont(11.5, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    TextField("", text: $step.name, prompt: Text(tr("Название", "Name")).foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain).font(OrbitFont.ui(13, .medium))
                        .foregroundStyle(step.enabled ? Theme.text : Theme.text3)
                        .frame(width: 150).padding(.top, 5)
                    TextField("", text: $step.command, prompt: Text(step.place == .mac ? "npm ci && npm test" : "docker compose up -d --build").foregroundStyle(Theme.text3), axis: .vertical)
                        .textFieldStyle(.plain).font(OrbitFont.mono(12))
                        .lineLimit(1...5)
                        .autocorrectionDisabled()
                        .padding(.vertical, 6).padding(.horizontal, 9)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(warning == nil ? Theme.border : Theme.red.opacity(0.7)))
                    Button { withMotion { step.place = step.place == .mac ? .server : .mac } } label: {
                        Tag(text: step.place.title, color: step.place == .mac ? Theme.violet : Theme.cyan)
                    }
                    .buttonStyle(PlainButtonStyle2())
                    .help(tr("Где выполнять: на Mac или на сервере", "Where to run: on the Mac or on the server"))
                    .frame(width: 62).padding(.top, 4)
                }
                OrbitToggle(isOn: $step.enabled).padding(.top, 4)
                Button(action: remove) {
                    Icon("xmark", size: 11, weight: .regular).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle2())
                .help(tr("Убрать шаг", "Remove the step"))
                .padding(.top, 1)
            }
            if let warning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.red)
                    Text(warning).uiFont(12, color: Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 30 + 150 + 12)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hairline()
    }

    private var warning: String? { step.kind != .code && step.place == .server ? DeployLint.warning(step.command) : nil }

    private func arrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold)).foregroundStyle(enabled ? Theme.text3 : Theme.border).frame(width: 18, height: 14)
        }
        .buttonStyle(PlainButtonStyle2())
        .disabled(!enabled)
    }
}
