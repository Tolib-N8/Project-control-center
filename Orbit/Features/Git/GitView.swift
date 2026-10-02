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
            PageHeader(eyebrow: "\(Plural.repos(snaps.count)) · обновлено \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "—")", title: "Git") {
                OrbitButton("Fetch всех", icon: "arrow.down.to.line") { app.fetchAll() }
                let dirty = snaps.filter { !$0.repo.changes.isEmpty }
                MenuChip(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "Закоммитить", kind: .primary) {
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
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Открытые PR").uiFont(14, .semibold)
                            Spacer()
                            Text("скоро").uiFont(12.5, color: Theme.text3)
                        }
                        Rectangle().fill(Theme.border).frame(height: 1)
                        EmptyHint(symbol: "arrow.triangle.pull", title: "GitHub ещё не подключён",
                                  text: "PR и статусы CI появятся во второй фазе — через gh CLI. Пока колонка «Тесты» берёт результат последнего прогона из сессий агентов.")
                    }
                }
                abandoned(snaps)
            }
            .appearStagger(3)
        }
        .alert(item: $confirm) { action in
            Alert(
                title: Text(action.delete ? "Удалить ветку \(action.branch)?" : "Rebase \(action.branch) на main?"),
                message: Text(action.delete
                              ? "Будет выполнено git branch -d — Git откажется удалять несмерженную ветку."
                              : "Orbit переключится на ветку, выполнит rebase и вернётся обратно. При конфликтах rebase будет отменён."),
                primaryButton: action.delete ? .destructive(Text("Удалить")) { run(action) } : .default(Text("Rebase")) { run(action) },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
    }

    private func run(_ action: BranchAction) {
        let repo = action.projectId, branch = action.branch
        if action.delete {
            app.runGit("Ветка \(branch) удалена") { GitService.deleteBranch(repo, branch) }
        } else if let main = app.repos[repo]?.mainBranch {
            app.runGit("Rebase \(branch) выполнен") { GitService.rebase(repo, branch: branch, onto: main) }
        }
    }

    private func totals(_ snaps: [ProjectSnapshot]) -> some View {
        let commits = snaps.flatMap { $0.commits(in: 14) }
        let agents = commits.filter { $0.agent != nil }.count
        let dirty = snaps.filter { !$0.repo.changes.isEmpty }
        let files = dirty.reduce(0) { $0 + $1.repo.changes.count }
        let failing = snaps.filter { $0.testsFailing > 0 }.count
        let behind = snaps.filter { $0.repo.behindMain >= 20 }.count
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Итого за 14 дней").uiFont(14, .semibold)
                totalRow("Коммитов", "\(commits.count)")
                totalRow("От агентов", commits.isEmpty ? "0" : "\(agents) · \(agents * 100 / max(commits.count, 1))%", color: Theme.violet)
                totalRow("Незакоммичено", files == 0 ? "чисто" : "\(Plural.files(files)) в \(dirty.count) репо", color: files == 0 ? Theme.text : Theme.yellow)
                totalRow("Падающие тесты", failing == 0 ? "нет" : Plural.repos(failing), color: failing == 0 ? Theme.text : Theme.red)
                totalRow("Отстают от main", behind == 0 ? "нет" : Plural.repos(behind), color: behind == 0 ? Theme.text : Theme.red)
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
                Eyebrow(text: "Репозиторий").frame(width: 180, alignment: .leading)
                Eyebrow(text: "Ветка").frame(width: 170, alignment: .leading)
                Eyebrow(text: "↑ / ↓").frame(width: 110, alignment: .leading)
                Eyebrow(text: "Последний коммит").frame(maxWidth: .infinity, alignment: .leading)
                Eyebrow(text: "Изменения").frame(width: 120, alignment: .leading)
                Eyebrow(text: "Тесты").frame(width: 90, alignment: .leading)
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
                    Text("\(c.agent?.title ?? "вы") · \(DateFormat.relativeDay(c.date, withTime: false))").uiFont(12, color: Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.changes.isEmpty ? "—" : Plural.files(r.changes.count))
                .uiFont(13.5, color: r.changes.isEmpty ? Theme.text3 : Theme.yellow)
                .frame(width: 120, alignment: .leading)
            HStack(spacing: 6) {
                if let _ = s.testsTotal {
                    Dot(color: s.testsFailing > 0 ? Theme.red : Theme.green)
                    Text(s.testsFailing > 0 ? "\(s.testsFailing) ✗" : "Ок").uiFont(13.5, color: s.testsFailing > 0 ? Theme.red : Theme.text2)
                } else {
                    Dot(color: Theme.text3)
                    Text("нет").uiFont(13.5, color: Theme.text3)
                }
            }
            .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func abandoned(_ snaps: [ProjectSnapshot]) -> some View {
        let items = snaps.flatMap { s in s.abandonedBranches.map { (s, $0) } }.sorted { $0.1.lastCommit < $1.1.lastCommit }
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Заброшенные ветки").uiFont(14, .semibold)
                    Spacer()
                    Text("> 7 дней без коммитов").uiFont(12.5, color: Theme.text3)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                if items.isEmpty {
                    Text("Все ветки свежие").uiFont(13, color: Theme.text3).padding(.vertical, 12)
                }
                ForEach(items.prefix(6), id: \.1.name) { s, b in
                    let days = Int(app.now.timeIntervalSince(b.lastCommit) / 86400)
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.text3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.name).monoFont(13.5).lineLimit(1)
                            Text("\(s.config.name) · " + (b.merged ? "смержена" : b.behindMain > 0 ? "отстала на \(b.behindMain)" : "не смержена"))
                                .uiFont(12.5, color: Theme.text3)
                        }
                        Spacer()
                        Text("\(days) дн.").uiFont(13, color: Theme.yellow)
                        if b.merged {
                            OrbitButton("Удалить", compact: true) { confirm = BranchAction(projectId: s.config.id, branch: b.name, delete: true) }
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
                    Text("Коммиты за 14 дней").uiFont(14, .semibold)
                    Spacer()
                    legend(Theme.violet, "Агенты")
                    legend(Theme.text3, "Вы")
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
                            .help("\(DateFormat.short(d)): агенты \(agents), вы \(you)")
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
            ?? "обновить \(Plural.files(changes.count))"
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
                    Text("Коммит · \(app.projectName(projectId))").uiFont(18, .semibold)
                    Text("ветка \(repo.branch) · сообщение составлено по файлам и последней сессии").uiFont(12.5, color: Theme.text2)
                }
                Spacer()
                if app.config.ai.isEnabled {
                    OrbitButton(generating ? "Пишу…" : "Сгенерировать с ИИ", icon: "sparkles") { generate() }
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
                Toggle("Запушить после коммита", isOn: $push).toggleStyle(.checkbox).disabled(repo.upstream == nil)
                Spacer()
                OrbitButton("Отмена") { dismiss() }
                OrbitButton("Закоммитить \(selected.count)", icon: "checkmark", kind: .primary) {
                    let files = Array(selected), msg = message, shouldPush = push
                    app.runGit(shouldPush ? "Закоммичено и запушено" : "Закоммичено") {
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
                Text("Дифф · \(app.projectName(projectId))").uiFont(16, .semibold)
                Spacer()
                OrbitButton("Закоммитить", kind: .primary) { app.sheet = .commit(projectId: projectId) }
                OrbitButton("Закрыть") { dismiss() }
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
