import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    /// 0 is the welcome screen, 1…3 the setup steps.
    @State private var step = 0
    @State private var forward = true
    @State private var roots: [String] = []
    @State private var found: [FoundRepo] = []
    @State private var selected: Set<String> = []
    @State private var scanning = false
    @State private var rhythm = Rhythm()

    var body: some View {
        VStack(spacing: 0) {
            if step == 0 {
                WelcomeView { go(1) }
                    .transition(Motion.transition(.opacity.animation(.easeOut(duration: 0.12))))
            } else {
            topBar
                .transition(.opacity)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case 1: reposStep
                    case 2: agentsStep
                    default: rhythmStep
                    }
                }
                // "Далее" slides the next step in from the right, "Назад" from the left.
                .id(step)
                .transition(Motion.transition(.asymmetric(
                    insertion: AnyTransition.opacity.combined(with: .offset(x: forward ? 40 : -40)).animation(Motion.page.delay(0.06)),
                    removal: .opacity.animation(.easeOut(duration: 0.08)))))
                .frame(width: 760, alignment: .leading)
                .padding(.top, 120)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 11))
                Text(app.config.ai.isEnabled && app.config.ai.provider != .ollama
                     ? tr("Данные хранятся локально в ~/.orbit · в модель уходят только сводки сессий и git, код не отправляется", "Data stays local in ~/.orbit · only session and git summaries go to the model, never code")
                     : tr("Данные хранятся локально в ~/.orbit · анализ идёт на этом Mac, код никуда не отправляется", "Data stays local in ~/.orbit · analysis runs on this Mac, code never leaves it"))
            }
            .uiFont(12.5, color: Theme.text3)
            .padding(.bottom, 28)
            .transition(.opacity)
            }
        }
        .background(Theme.bg)
        .animation(Motion.pick(Motion.page), value: step)
        .onAppear {
            roots = app.config.scanRoots
            rhythm = app.config.rhythm
            if found.isEmpty { scan() }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--onboarding-step"), i + 1 < args.count, let n = Int(args[i + 1]) { step = n }
            #endif
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                BrandLogo(size: 26)
                Text("Orbit").uiFont(16, .semibold)
            }
            .frame(width: 220, alignment: .leading)
            Spacer()
            HStack(spacing: 14) {
                stepLabel(1, tr("Репозитории", "Repositories"))
                line
                stepLabel(2, tr("Агенты", "Agents"))
                line
                stepLabel(3, tr("Ритм недели", "Weekly rhythm"))
            }
            Spacer()
            Button(tr("Пропустить настройку", "Skip setup")) { finish(skip: true) }
                .buttonStyle(PlainButtonStyle2())
                .font(OrbitFont.ui(13)).foregroundStyle(Theme.text2)
                .frame(width: 220, alignment: .trailing)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
    }

    private var line: some View { Rectangle().fill(Theme.border).frame(width: 40, height: 1) }

    private func go(_ n: Int) {
        forward = n > step
        withMotion(Motion.page) { step = n }
    }

    private func stepLabel(_ n: Int, _ title: String) -> some View {
        let done = n < step, current = n == step
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(current ? Theme.accent : done ? Theme.accent.opacity(0.15) : Theme.surface2)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                        .transition(Motion.transition(.scale(scale: 0.5).combined(with: .opacity)))
                        .symbolEffect(.bounce, value: done)
                } else {
                    Text("\(n)").uiFont(12, .semibold, color: current ? Theme.bg : Theme.text3)
                        .transition(.opacity)
                }
            }
            .frame(width: 22, height: 22)
            .animation(Motion.pick(Motion.snappy), value: step)
            Text(title).uiFont(13, current ? .medium : .regular, color: current ? Theme.text : Theme.text2)
        }
    }

    private func stepHeader(_ n: Int, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("ШАГ \(n) ИЗ 3", "STEP \(n) OF 3")).font(OrbitFont.ui(12, .semibold)).tracking(0.8).foregroundStyle(Theme.accent)
            Text(title).font(OrbitFont.ui(34, .semibold)).tracking(-0.8)
            Text(subtitle).uiFont(15, color: Theme.text2).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 32)
    }

    // MARK: - Step 1

    private var reposStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(1, tr("Где лежат ваши проекты?", "Where do your projects live?"), tr("Orbit найдёт git-репозитории и логи сессий ИИ-агентов. Всё читается локально — код никуда не отправляется.", "Orbit finds git repositories and AI agent session logs. Everything is read locally — your code never leaves the Mac."))
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Theme.text2)
                    Text(roots.map { $0.expandingTilde.abbreviatingHome }.joined(separator: ", ")).monoFont(13).lineLimit(1)
                    Spacer()
                    Button(tr("+ ещё папка", "+ another folder")) {
                        if let path = FolderPicker.pick(message: tr("Папка, где лежат проекты", "Folder that contains your projects")) {
                            roots.append(path.abbreviatingHome)
                            scan()
                        }
                    }
                    .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(12.5)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                OrbitButton(scanning ? tr("Сканирую…", "Scanning…") : tr("Сканировать", "Scan"), icon: "viewfinder") { scan() }
            }
            .padding(.bottom, 24)

            VStack(spacing: 0) {
                HStack {
                    Dot(color: scanning ? Theme.yellow : Theme.green)
                    Text(scanning ? tr("Ищу репозитории…", "Looking for repositories…") : tr("Найдено \(Plural.repos(found.count))", "Found \(Plural.repos(found.count))")).uiFont(13, .medium)
                    Spacer()
                    Button(selected.count == found.count ? tr("Снять все", "Deselect all") : tr("Выбрать все", "Select all")) {
                        withMotion { selected = selected.count == found.count ? [] : Set(found.map(\.path)) }
                    }
                    .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(13)).foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .hairline()
                ForEach(Array(found.enumerated()), id: \.element.id) { i, repo in
                    repoRow(repo, colorIndex: i).appearStagger(i)
                    if i < found.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
                if found.isEmpty && !scanning {
                    Text(tr("В этих папках нет git-репозиториев. Добавьте другую папку.", "No git repositories in these folders. Add another folder.")).uiFont(13, color: Theme.text3).padding(24)
                }
            }
            .cardStyle(radius: 12)

            HStack {
                let sessions = found.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.agents.values.reduce(0, +) }
                Text(tr("Выбрано \(Plural.projects(selected.count)) · \(Plural.sessions(sessions)) агентов для анализа", "\(Plural.projects(selected.count)) selected · \(Plural.sessions(sessions)) of agent work to analyze")).uiFont(13, color: Theme.text2)
                Spacer()
                OrbitButton(tr("Далее: агенты", "Next: agents"), icon: "arrow.right", kind: .primary) { go(2) }
                    .disabled(selected.isEmpty)
                    .opacity(selected.isEmpty ? 0.5 : 1)
            }
            .padding(.top, 28)
        }
    }

    private func repoRow(_ repo: FoundRepo, colorIndex: Int) -> some View {
        let on = selected.contains(repo.path)
        return Button {
            withMotion { if on { selected.remove(repo.path) } else { selected.insert(repo.path) } }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: 1.5)
                    if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.bg) }
                }
                .frame(width: 18, height: 18)
                ProjectSquare(colorIndex: on ? colorIndex : 99, size: 8)
                    .opacity(on ? 1 : 0.4)
                Text(repo.name).monoFont(13.5, color: on ? Theme.text : Theme.text2).lineLimit(1)
                    .frame(width: 200, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Text(repo.branch).monoFont(12.5, color: Theme.text2).lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
                HStack(spacing: 6) {
                    if repo.agents.isEmpty {
                        Text(tr("логов агентов нет", "no agent logs")).uiFont(12.5, color: Theme.text3)
                    }
                    ForEach(AgentKind.allCases.filter { repo.agents[$0] != nil }) { a in AgentTag(agent: a) }
                }
                Spacer()
                Text(repo.lastActivity.map { DateFormat.relativeDay($0, withTime: false) } ?? "—").uiFont(12.5, color: Theme.text3)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
    }

    private func scan() {
        scanning = true
        let rootsCopy = roots
        Task {
            let result = await Task.detached { RepoScanner.enrich(RepoScanner.scan(roots: rootsCopy)) }.value
            found = result.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            let recent = Date().addingTimeInterval(-60 * 86400)
            selected = Set(found.filter { !$0.agents.isEmpty || ($0.lastActivity ?? .distantPast) > recent }.map(\.path))
            scanning = false
        }
    }

    // MARK: - Step 2

    private var agentsStep: some View {
        let chosen = found.filter { selected.contains($0.path) }
        let counts = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { a in (a, chosen.reduce(0) { $0 + ($1.agents[a] ?? 0) }) })
        let total = AgentKind.allCases.filter { app.config.source($0).enabled }.reduce(0) { $0 + (counts[$1] ?? 0) }
        let sources = AgentKind.allCases.filter { app.config.source($0).enabled && (counts[$0] ?? 0) > 0 }.count
        return VStack(alignment: .leading, spacing: 0) {
            stepHeader(2, tr("Откуда читать сессии агентов", "Where to read agent sessions from"), tr("По логам Orbit поймёт, что агент сделал, где застрял и сколько времени ушло на каждый проект.", "From the logs Orbit learns what the agent did, where it got stuck and how much time each project took."))
            VStack(spacing: 0) {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { i, agent in
                    agentRow(agent, count: counts[agent] ?? 0)
                    if i < AgentKind.allCases.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            .cardStyle()

            Text(tr("Чем анализировать сессии", "How to analyze sessions")).uiFont(14, .semibold).padding(.top, 32).padding(.bottom, 14)
            ProviderPicker()
            if app.config.ai.provider.usesModel {
                ProviderDetails().padding(.top, 12)
            }

            HStack {
                OrbitButton(tr("Назад", "Back"), icon: "arrow.left") { go(1) }
                Spacer()
                Text(tr("\(Plural.sessions(total)) из \(sources) \(Plural.ru(sources, "источника", "источников", "источников"))", "\(Plural.sessions(total)) from \(plural(sources, ru: ("источника", "источников", "источников"), en: ("source", "sources")))")).uiFont(13, color: Theme.text3)
                OrbitButton(tr("Далее: ритм недели", "Next: weekly rhythm"), icon: "arrow.right", kind: .primary) { go(3) }
            }
            .padding(.top, 28)
        }
    }

    private func agentRow(_ agent: AgentKind, count: Int) -> some View {
        let source = app.config.source(agent)
        let detected: Bool = {
            switch agent {
            case .claude: FileManager.default.fileExists(atPath: (source.customPath ?? ClaudeCodeParser.defaultRoot()).expandingTilde)
            case .codex: FileManager.default.fileExists(atPath: (source.customPath ?? CodexParser.defaultRoot()).expandingTilde)
            case .cursor: CursorDetector.isInstalled(path: source.customPath?.expandingTilde)
            case .aider: count > 0
            }
        }()
        return HStack(spacing: 14) {
            IconBox(symbol: detected ? "cpu" : "cpu.fill", color: detected ? agent.color : Theme.text3, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.title).uiFont(15, .medium, color: detected ? Theme.text : Theme.text2)
                Text(detected ? (source.customPath ?? agent.defaultLogPath).abbreviatingHome : tr("не найден", "not found")).monoFont(12, color: Theme.text3)
            }
            Spacer()
            if detected {
                if agent == .cursor {
                    Text(tr("чаты Cursor — в следующей версии", "Cursor chats — in a future version")).uiFont(12.5, color: Theme.text3)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                        Text(Plural.sessions(count)).uiFont(13.5)
                    }
                }
                OrbitToggle(isOn: Binding(get: { app.config.source(agent).enabled }, set: { on in
                    var s = app.config.source(agent)
                    s.enabled = on
                    app.config.agentSources[agent.rawValue] = s
                }))
            } else if agent != .aider {
                OrbitButton(tr("Указать путь", "Set path"), icon: "folder.badge.questionmark", compact: true) {
                    if let path = FolderPicker.pick(message: tr("Папка с логами \(agent.title)", "\(agent.title) logs folder")) {
                        app.config.agentSources[agent.rawValue] = AgentSourceConfig(enabled: true, customPath: path.abbreviatingHome)
                    }
                }
            } else {
                Text(tr("история .aider.chat.history.md не найдена", "no .aider.chat.history.md found")).uiFont(12.5, color: Theme.text3)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    // MARK: - Step 3

    private var rhythmStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(3, tr("Когда вы обычно работаете?", "When do you usually work?"), tr("По этому ритму Orbit будет предлагать, какой проект взять в какой день. План всегда можно поправить вручную.", "Orbit uses this rhythm to suggest which project to take on which day. You can always adjust the plan by hand."))
            HStack {
                Text(tr("Рабочие дни и часы", "Work days and hours")).uiFont(14, .semibold)
                Spacer()
                Text(tr("\(rhythm.weeklyHours) ч в неделю · клик — вкл/выкл, правый клик — часы", "\(rhythm.weeklyHours) h per week · click to toggle, right-click for hours")).uiFont(12.5, color: Theme.text3)
            }
            .padding(.bottom, 14)
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { d in dayTile(d) }
            }
            .padding(.bottom, 24)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Проектов в день, не больше", "Projects per day, at most")).uiFont(14, .semibold)
                    Text(tr("Меньше переключений — глубже фокус", "Fewer switches, deeper focus")).uiFont(13, color: Theme.text2)
                }
                Spacer()
                SegmentedTabs(items: [(1, "1"), (2, "2"), (3, "3")], selection: $rhythm.maxProjectsPerDay)
            }
            .padding(20)
            .cardStyle()
            .padding(.bottom, 24)

            VStack(spacing: 0) {
                toggleRow("calendar.badge.clock", tr("Orbit составляет план каждое воскресенье в 20:00", "Orbit drafts a plan every Sunday at 20:00"), $rhythm.autoPlanSunday)
                Rectangle().fill(Theme.border).frame(height: 1)
                toggleRow("sun.max", tr("Утренняя сводка в 9:00: проект дня и что делать", "Morning brief at 9:00: the project of the day and what to do"), $rhythm.morningBrief)
                Rectangle().fill(Theme.border).frame(height: 1)
                toggleRow("bell", tr("Сигналы о проблемах в Git и сессиях", "Signals about problems in git and sessions"), $rhythm.signalsEnabled)
            }
            .cardStyle()

            HStack {
                OrbitButton(tr("Назад", "Back"), icon: "arrow.left") { go(2) }
                Spacer()
                OrbitButton(tr("Готово — открыть Orbit", "Done — open Orbit"), icon: "checkmark", kind: .primary) { finish(skip: false) }
            }
            .padding(.top, 28)
        }
    }

    private func dayTile(_ d: Int) -> some View {
        let hours = rhythm.hours[d]
        let on = hours > 0
        return Button { withMotion { rhythm.hours[d] = on ? 0 : 7 } } label: {
            VStack(spacing: 6) {
                Text(Week.shortNames[d]).uiFont(14, .semibold, color: on ? Theme.text : Theme.text3)
                Text(on ? tr("\(hours) ч", "\(hours) h") : tr("выходной", "day off")).font(on ? OrbitFont.mono(15, .semibold) : OrbitFont.ui(12)).foregroundStyle(on ? Theme.accent : Theme.text3)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(on ? Theme.accent.opacity(0.06) : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Theme.accent.opacity(0.45) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
        .contextMenu {
            ForEach(0...12, id: \.self) { h in
                Button(h == 0 ? tr("Выходной", "Day off") : tr("\(h) ч", "\(h) h")) { rhythm.hours[d] = h }
            }
        }
    }

    private func toggleRow(_ icon: String, _ text: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(Theme.text2).frame(width: 18)
            Text(text).uiFont(14)
            Spacer()
            OrbitToggle(isOn: binding)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func finish(skip: Bool) {
        app.config.scanRoots = roots
        let repos = skip && selected.isEmpty ? found : found.filter { selected.contains($0.path) }
        app.finishOnboarding(repos: repos, rhythm: skip ? Rhythm() : rhythm)
    }
}
