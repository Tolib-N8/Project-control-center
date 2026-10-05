import SwiftUI

struct GitView: View {
    @Environment(AppState.self) private var app
    @State private var confirm: BranchAction?

    struct BranchAction: Identifiable {
        var id: String { "\(projectId):\(branch):\(delete)" }
        var projectId: String
        var branch: String
        var delete: Bool
    }

    var body: some View {
        let snaps = app.activeSnapshots
        Page {
            PageHeader(eyebrow: tr("\(Plural.repos(snaps.count)) · обновлено \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "—")", "\(Plural.repos(snaps.count)) · updated \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "—")"), title: "Git") {
                OrbitButton(tr("Fetch всех", "Fetch all"), icon: "arrow.down.to.line") { app.fetchAll() }
                let dirty = snaps.filter { !$0.repo.changes.isEmpty }
                MenuChip(icon: "point.topleft.down.to.point.bottomright.curvepath", title: tr("Закоммитить", "Commit"), kind: .primary) {
                    ForEach(dirty, id: \.config.id) { s in
                        Button("\(s.config.name) — \(Plural.files(s.repo.changes.count))") { app.sheet = .commit(projectId: s.config.id) }
                    }
                }
                .disabled(dirty.isEmpty)
                .opacity(dirty.isEmpty ? 0.5 : 1)
            }

            HStack(alignment: .top, spacing: 28) {
                CommitChart(snaps: snaps).appearStagger(0)
                totals(snaps).frame(width: 320).appearStagger(1)
            }
            .fixedSize(horizontal: false, vertical: true)

            repoTable(snaps).appearStagger(2)

            HStack(alignment: .top, spacing: 28) {
                PullRequestsCard()
                abandoned(snaps)
            }
            .appearStagger(3)
        }
        .alert(item: $confirm) { action in
            Alert(
                title: Text(action.delete ? tr("Удалить ветку \(action.branch)?", "Delete branch \(action.branch)?") : tr("Rebase \(action.branch) на main?", "Rebase \(action.branch) onto main?")),
                message: Text(action.delete
                              ? tr("Будет выполнено git branch -d — Git откажется удалять несмерженную ветку.", "This runs git branch -d — Git refuses to delete an unmerged branch.")
                              : tr("Orbit переключится на ветку, выполнит rebase и вернётся обратно. При конфликтах rebase будет отменён.", "Orbit switches to the branch, rebases it and switches back. On conflicts the rebase is aborted.")),
                primaryButton: action.delete ? .destructive(Text(tr("Удалить", "Delete"))) { run(action) } : .default(Text("Rebase")) { run(action) },
                secondaryButton: .cancel(Text(tr("Отмена", "Cancel")))
            )
        }
    }

    private func run(_ action: BranchAction) {
        let repo = action.projectId, branch = action.branch
        if action.delete {
            app.runGit(tr("Ветка \(branch) удалена", "Branch \(branch) deleted")) { GitService.deleteBranch(repo, branch) }
        } else if let main = app.repos[repo]?.mainBranch {
            app.runGit(tr("Rebase \(branch) выполнен", "Rebased \(branch)")) { GitService.rebase(repo, branch: branch, onto: main) }
        }
    }

    private func totals(_ snaps: [ProjectSnapshot]) -> some View {
        let commits = snaps.flatMap { $0.commits(in: 14) }
        let agents = commits.filter { $0.agent != nil }.count
        let dirty = snaps.filter { !$0.repo.changes.isEmpty }
        let files = dirty.reduce(0) { $0 + $1.repo.changes.count }
        let failing = snaps.filter { $0.testsFailing > 0 }.count
        let behind = snaps.filter { $0.repo.behindMain >= 20 }.count
        let connected = app.githubAccess.login != nil || !app.github.isEmpty
        let ciFailing = app.github.values.filter { $0.ci?.state == .failure }.count
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("Итого за 14 дней", "Last 14 days")).uiFont(14, .semibold)
                totalRow(tr("Коммитов", "Commits"), "\(commits.count)")
                totalRow(tr("От агентов", "By agents"), commits.isEmpty ? "0" : "\(agents) · \(agents * 100 / max(commits.count, 1))%", color: Theme.violet)
                totalRow(tr("Незакоммичено", "Uncommitted"), files == 0 ? tr("чисто", "clean") : tr("\(Plural.files(files)) в \(dirty.count) репо", "\(Plural.files(files)) in \(Plural.repos(dirty.count))"), color: files == 0 ? Theme.text : Theme.yellow)
                if connected {
                    totalRow(tr("Падающий CI", "Failing CI"), ciFailing == 0 ? tr("нет", "none") : Plural.repos(ciFailing), color: ciFailing == 0 ? Theme.text : Theme.red)
                    totalRow(tr("Открытых PR", "Open PRs"), "\(app.openPulls.count)")
                } else {
                    totalRow(tr("Падающие тесты", "Failing tests"), failing == 0 ? tr("нет", "none") : Plural.repos(failing), color: failing == 0 ? Theme.text : Theme.red)
                }
                totalRow(tr("Отстают от main", "Behind main"), behind == 0 ? tr("нет", "none") : Plural.repos(behind), color: behind == 0 ? Theme.text : Theme.red)
            }
        }
    }

    private func totalRow(_ k: String, _ v: String, color: Color = Theme.text) -> some View {
        HStack {
            Text(k).uiFont(13.5, color: Theme.text2)
            Spacer()
            Text(v).uiFont(13.5, .medium, color: color).numericTransition(v)
        }
    }

    private func repoTable(_ snaps: [ProjectSnapshot]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Eyebrow(text: tr("Репозиторий", "Repository")).frame(width: 180, alignment: .leading)
                Eyebrow(text: tr("Ветка", "Branch")).frame(width: 170, alignment: .leading)
                Eyebrow(text: "↑ / ↓").frame(width: 110, alignment: .leading)
                Eyebrow(text: tr("Последний коммит", "Last commit")).frame(maxWidth: .infinity, alignment: .leading)
                Eyebrow(text: tr("Изменения", "Changes")).frame(width: 120, alignment: .leading)
                Eyebrow(text: tr("Проверки", "Checks")).frame(width: 90, alignment: .leading)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .hairline()
            ForEach(Array(snaps.enumerated()), id: \.element.config.id) { i, s in
                Button { app.screen = .project(s.config.id) } label: { repoRow(s).hoverHighlight() }
                    .buttonStyle(PlainButtonStyle2())
                    .appearStagger(i + 3)
                if i < snaps.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .cardStyle()
    }

    private func repoRow(_ s: ProjectSnapshot) -> some View {
        let r = s.repo
        let behindValue = r.branch == r.mainBranch ? r.behind : r.behindMain
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                ProjectSquare(colorIndex: s.config.colorIndex)
                Text(s.config.name).monoFont(13.5, .medium).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text(r.branch).monoFont(13).lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            HStack(spacing: 10) {
                Text("↑\(r.ahead)").monoFont(13, color: r.ahead > 0 ? Theme.text : Theme.text3)
                Text("↓\(behindValue)").monoFont(13, color: behindValue >= 20 ? Theme.red : behindValue > 0 ? Theme.text : Theme.text3)
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.lastCommit?.subject ?? "—").uiFont(13.5).lineLimit(1)
                if let c = r.lastCommit {
                    Text(tr("\(c.agent?.title ?? "вы") · \(DateFormat.relativeDay(c.date, withTime: false))", "\(c.agent?.title ?? "you") · \(DateFormat.relativeDay(c.date, withTime: false))")).uiFont(12, color: Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.changes.isEmpty ? "—" : Plural.files(r.changes.count))
                .uiFont(13.5, color: r.changes.isEmpty ? Theme.text3 : Theme.yellow)
                .frame(width: 120, alignment: .leading)
            checks(s).frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// GitHub CI for the checked-out branch when there is one, otherwise the last test run from agent sessions.
    @ViewBuilder
    private func checks(_ s: ProjectSnapshot) -> some View {
        HStack(spacing: 6) {
            if let ci = app.github[s.config.id]?.ci, ci.state != .none {
                let color = ci.state == .failure ? Theme.red : ci.state == .pending ? Theme.yellow : Theme.green
                Dot(color: color)
                Text(ci.state == .failure ? "CI \(ci.failed) ✗" : ci.state == .pending ? tr("CI идёт", "CI running") : "CI ✓")
                    .uiFont(13.5, color: ci.state == .success ? Theme.text2 : color)
            } else if s.testsTotal != nil {
                Dot(color: s.testsFailing > 0 ? Theme.red : Theme.green)
                Text(s.testsFailing > 0 ? "\(s.testsFailing) ✗" : tr("Ок", "OK")).uiFont(13.5, color: s.testsFailing > 0 ? Theme.red : Theme.text2)
            } else {
                Dot(color: Theme.text3)
                Text(tr("нет", "none")).uiFont(13.5, color: Theme.text3)
            }
        }
        .help(app.github[s.config.id]?.ci != nil ? tr("GitHub Actions на ветке \(s.repo.branch)", "GitHub Actions on \(s.repo.branch)")
                                                  : tr("Последний прогон тестов в сессиях агентов", "Last test run in agent sessions"))
    }

    private func abandoned(_ snaps: [ProjectSnapshot]) -> some View {
        let items = snaps.flatMap { s in s.abandonedBranches.map { (s, $0) } }.sorted { $0.1.lastCommit < $1.1.lastCommit }
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(tr("Заброшенные ветки", "Stale branches")).uiFont(14, .semibold)
                    Spacer()
                    Text(tr("> 7 дней без коммитов", "> 7 days without commits")).uiFont(12.5, color: Theme.text3)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                if items.isEmpty {
                    Text(tr("Все ветки свежие", "All branches are fresh")).uiFont(13, color: Theme.text3).padding(.vertical, 12)
                }
                ForEach(items.prefix(6), id: \.1.name) { s, b in
                    let days = Int(app.now.timeIntervalSince(b.lastCommit) / 86400)
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.text3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.name).monoFont(13.5).lineLimit(1)
                            Text("\(s.config.name) · " + (b.merged ? tr("смержена", "merged") : b.behindMain > 0 ? tr("отстала на \(b.behindMain)", "\(b.behindMain) behind") : tr("не смержена", "not merged")))
                                .uiFont(12.5, color: Theme.text3)
                        }
                        Spacer()
                        Text(tr("\(days) дн.", "\(days) d")).uiFont(13, color: Theme.yellow)
                        if b.merged {
                            OrbitButton(tr("Удалить", "Delete"), compact: true) { confirm = BranchAction(projectId: s.config.id, branch: b.name, delete: true) }
                        } else {
                            OrbitButton("Rebase", compact: true) { confirm = BranchAction(projectId: s.config.id, branch: b.name, delete: false) }
                        }
                    }
                    .padding(.vertical, 6)
                    .transition(Motion.transition(.opacity.combined(with: .move(edge: .leading))))
                }
            }
            .animation(Motion.pick(Motion.page), value: items.map(\.1.name))
        }
    }
}

struct CommitChart: View {
    @Environment(AppState.self) private var app
    var snaps: [ProjectSnapshot]
    @State private var grown = false

    var body: some View {
        let cal = Week.calendar
        let today = cal.startOfDay(for: app.now)
        let days = (0..<14).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
        let commits = snaps.flatMap { $0.repo.commits }
        let data = days.map { d -> (Date, Int, Int) in
            let dayCommits = commits.filter { cal.isDate($0.date, inSameDayAs: d) }
            return (d, dayCommits.filter { $0.agent != nil }.count, dayCommits.filter { $0.agent == nil }.count)
        }
        let maxValue = max(1, data.map { $0.1 + $0.2 }.max() ?? 1)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(tr("Коммиты за 14 дней", "Commits, last 14 days")).uiFont(14, .semibold)
                    Spacer()
                    legend(Theme.violet, tr("Агенты", "Agents"))
                    legend(Theme.text3, tr("Вы", "You"))
                }
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(data, id: \.0) { d, agents, you in
                        let isToday = cal.isDate(d, inSameDayAs: today)
                        VStack(spacing: 8) {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if you > 0 {
                                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                        .fill(Theme.text3.opacity(0.6))
                                        .frame(height: grown ? 130 * CGFloat(you) / CGFloat(maxValue) : 0)
                                }
                                if agents > 0 {
                                    Rectangle()
                                        .fill(isToday ? Theme.accent : Theme.violet)
                                        .frame(height: grown ? 130 * CGFloat(agents) / CGFloat(maxValue) : 0)
                                }
                                if agents + you == 0 { Rectangle().fill(Theme.border).frame(height: 2) }
                            }
                            .frame(height: 130)
                            // Columns rise one after another, left to right.
                            .animation(Motion.pick(Motion.grow).delay(Motion.reduced ? 0 : Double(data.firstIndex { $0.0 == d } ?? 0) * 0.025), value: grown)
                            .help(tr("\(DateFormat.short(d)): агенты \(agents), вы \(you)", "\(DateFormat.short(d)): agents \(agents), you \(you)"))
                            Text("\(cal.component(.day, from: d))").monoFont(11.5, color: isToday ? Theme.accent : Theme.text3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .animation(Motion.pick(Motion.grow), value: data.map { $0.1 + $0.2 })
                .onAppear { grown = true }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).uiFont(12.5, color: Theme.text2)
        }
        .padding(.leading, 12)
    }
}

// MARK: - Commit & diff sheets

enum CommitMessage {
    static func suggest(changes: [FileChange], sessions: [AgentSession]) -> String {
        let paths = changes.map(\.path)
        let isTest: (String) -> Bool = { $0.contains("test") || $0.contains("spec") }
        let isDoc: (String) -> Bool = { $0.hasSuffix(".md") || $0.hasPrefix("docs/") }
        let isConfig: (String) -> Bool = { ["json", "yml", "yaml", "toml", "lock"].contains(($0 as NSString).pathExtension) }
        let type: String
        if !paths.isEmpty && paths.allSatisfy(isTest) { type = "test" }
        else if !paths.isEmpty && paths.allSatisfy(isDoc) { type = "docs" }
        else if !paths.isEmpty && paths.allSatisfy(isConfig) { type = "chore" }
        else if changes.contains(where: { $0.status == "A" || $0.status == "?" }) { type = "feat" }
        else { type = "fix" }

        var dirs: [String: Int] = [:]
        for p in paths {
            let parts = p.split(separator: "/")
            let scope = parts.count > 2 && ["src", "lib", "app", "Sources", "packages"].contains(String(parts[0])) ? String(parts[1]) : (parts.count > 1 ? String(parts[0]) : "")
            if !scope.isEmpty { dirs[scope, default: 0] += 1 }
        }
        let scope = dirs.max { $0.value < $1.value }.map { "(\($0.key))" } ?? ""

        let recent = sessions.first { Date().timeIntervalSince($0.end) < 2 * 86400 }
        var subject = recent.map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() }
            ?? tr("обновить \(Plural.files(changes.count))", "update \(Plural.files(changes.count))")
        if subject.count > 60 { subject = String(subject.prefix(57)) + "…" }

        let body = changes.prefix(12).map { "- \($0.status) \($0.path)" }.joined(separator: "\n")
        return "\(type)\(scope): \(subject)\n\n\(body)"
    }
}

struct CommitSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: String
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var push = false
    @State private var generating = false

    var body: some View {
        let repo = app.repos[projectId] ?? RepoStatus()
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Коммит · \(app.projectName(projectId))", "Commit · \(app.projectName(projectId))")).uiFont(18, .semibold)
                    Text(tr("ветка \(repo.branch) · сообщение составлено по файлам и последней сессии", "branch \(repo.branch) · message drafted from the files and the last session")).uiFont(12.5, color: Theme.text2)
                }
                Spacer()
                if app.config.ai.isEnabled {
                    OrbitButton(generating ? tr("Пишу…", "Writing…") : tr("Сгенерировать с ИИ", "Generate with AI"), icon: "sparkles") { generate() }
                        .disabled(generating)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(repo.changes) { c in
                    Toggle(isOn: Binding(get: { selected.contains(c.path) }, set: { on in
                        if on { selected.insert(c.path) } else { selected.remove(c.path) }
                    })) {
                        HStack(spacing: 8) {
                            Text(c.status).monoFont(12, .medium, color: c.status == "?" ? Theme.text2 : c.status == "A" ? Theme.green : c.status == "D" ? Theme.red : Theme.yellow)
                            Text(c.path).monoFont(12.5).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxHeight: 220)
            TextEditor(text: $message)
                .font(OrbitFont.mono(12.5))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 170)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            HStack {
                Toggle(tr("Запушить после коммита", "Push after committing"), isOn: $push).toggleStyle(.checkbox).disabled(repo.upstream == nil)
                Spacer()
                OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
                OrbitButton(tr("Закоммитить \(selected.count)", "Commit \(selected.count)"), icon: "checkmark", kind: .primary) {
                    let files = Array(selected), msg = message, shouldPush = push
                    app.runGit(shouldPush ? tr("Закоммичено и запушено", "Committed and pushed") : tr("Закоммичено", "Committed")) {
                        GitService.commit(projectId, files: files, message: msg, push: shouldPush)
                    }
                    dismiss()
                }
                .disabled(selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(Theme.surface)
        .onAppear {
            if app.config.ai.isEnabled { generate() }
            selected = Set(repo.changes.filter { !$0.path.hasSuffix("/") }.map(\.path))
            message = CommitMessage.suggest(changes: repo.changes, sessions: app.snapshots[projectId]?.sessions ?? [])
        }
    }
}

extension CommitSheet {
    func generate() {
        generating = true
        Task {
            do { message = try await app.aiCommitMessage(projectId) } catch { app.toast = error.localizedDescription }
            generating = false
        }
    }
}

struct DiffSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: String
    @State private var diff = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Дифф · \(app.projectName(projectId))", "Diff · \(app.projectName(projectId))")).uiFont(16, .semibold)
                Spacer()
                OrbitButton(tr("Закоммитить", "Commit"), kind: .primary) { app.sheet = .commit(projectId: projectId) }
                OrbitButton(tr("Закрыть", "Close")) { dismiss() }
            }
            .padding(20).hairline()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(4000).enumerated()), id: \.offset) { _, line in
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(OrbitFont.mono(12))
                            .foregroundStyle(line.hasPrefix("+") ? Theme.green : line.hasPrefix("-") ? Theme.red : line.hasPrefix("@@") ? Theme.cyan : Theme.text2)
                            .fixedSize()
                    }
                }
                .textSelection(.enabled)
                .padding(20)
            }
        }
        .frame(width: 900, height: 680)
        .background(Theme.surface)
        .task {
            let id = projectId
            diff = await Task.detached { GitService.diff(id) }.value
        }
    }
}

/// "Открытые PR": pull requests of all GitHub repos with the one status that matters, via `gh`.
struct PullRequestsCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let pulls = app.openPulls
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("Открытые PR", "Open PRs")).uiFont(14, .semibold)
                    if app.githubSyncing { ProgressView().controlSize(.mini) }
                    Spacer()
                    if !pulls.isEmpty { Text("\(pulls.count)").uiFont(12, color: Theme.text3).numericTransition(pulls.count) }
                }
                .padding(.bottom, 8)
                content(pulls)
            }
        }
        .animation(Motion.pick(Motion.content), value: pulls.map(\.pr))
    }

    @ViewBuilder
    private func content(_ pulls: [(projectId: String, pr: PullRequest)]) -> some View {
        switch app.githubAccess {
        case .notInstalled where app.github.isEmpty:
            hint(tr("Нужен GitHub CLI", "GitHub CLI needed"),
                 tr("Установите gh (brew install gh) и войдите — Orbit покажет PR и статусы CI.", "Install gh (brew install gh) and sign in — Orbit will show PRs and CI status."))
        case .signedOut where app.github.isEmpty:
            hint(tr("Войдите в GitHub CLI", "Sign in to GitHub CLI"), tr("Orbit читает PR и CI через ваш аккаунт gh.", "Orbit reads PRs and CI with your gh account.")) {
                OrbitButton(tr("Войти через терминал", "Sign in in Terminal"), icon: "terminal", compact: true) { app.signInToGitHub() }
            }
        case .unknown where app.github.isEmpty:
            hint(tr("Связываюсь с GitHub…", "Contacting GitHub…"), "")
        default:
            if app.github.isEmpty {
                hint(tr("Нет репозиториев на GitHub", "No repositories on GitHub"), tr("У подключённых проектов нет origin на github.com.", "None of your projects has an origin on github.com."))
            } else if pulls.isEmpty {
                hint(tr("Открытых PR нет", "No open PRs"),
                     tr("Как только вы или агент откроете PR, он появится здесь со статусом проверок и ревью.", "As soon as you or an agent open a PR, it shows up here with its checks and review status."))
            } else {
                ForEach(Array(pulls.prefix(8).enumerated()), id: \.element.pr.url) { i, item in
                    row(item.projectId, item.pr)
                    if i < min(pulls.count, 8) - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }

    private func row(_ projectId: String, _ pr: PullRequest) -> some View {
        let status = PRStatus.describe(pr, me: app.githubAccess.login)
        let color = Theme.projectColor(app.project(projectId)?.colorIndex ?? 0)
        return Button { open(pr.url) } label: {
            HStack(spacing: 12) {
                Icon("arrow.triangle.pull", size: 13, weight: .regular).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title).uiFont(13).lineLimit(1)
                    Text("#\(pr.number) · \(app.projectName(projectId))").monoFont(11.5, color: Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(status.text).uiFont(12, color: tone(status.tone)).lineLimit(1)
            }
            .padding(.vertical, 10)
            .hoverHighlight()
        }
        .buttonStyle(PlainButtonStyle2())
        .help(tr("Открыть на GitHub · ветка \(pr.branch)", "Open on GitHub · branch \(pr.branch)"))
        .contextMenu {
            Button(tr("Открыть на GitHub", "Open on GitHub")) { open(pr.url) }
            Button(tr("Скопировать ссылку", "Copy link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
        }
    }

    private func hint(_ title: String, _ text: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            IconBox(symbol: "arrow.triangle.pull", color: Theme.text2, size: 40)
            Text(title).uiFont(14, .semibold)
            if !text.isEmpty { Text(text).uiFont(12.5, color: Theme.text2).multilineTextAlignment(.center) }
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func tone(_ t: PRStatus.Tone) -> Color {
        switch t {
        case .ok: Theme.green
        case .warn: Theme.yellow
        case .bad: Theme.red
        case .normal: Theme.text2
        case .muted: Theme.text3
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
