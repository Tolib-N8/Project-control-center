import SwiftUI

struct ProjectsView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var sort: Sort = .health

    enum Sort: String, CaseIterable {
        case health, name, activity

        var title: String {
            switch self {
            case .health: tr("здоровье", "health")
            case .name: tr("имя", "name")
            case .activity: tr("активность", "activity")
            }
        }
    }

    var body: some View {
        let archived = app.config.projects.filter(\.archived)
        Page {
            PageHeader(eyebrow: tr("\(app.config.activeProjects.count) активных · \(archived.count) в архиве", "\(app.config.activeProjects.count) active · \(archived.count) archived"), title: tr("Проекты", "Projects")) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    TextField("", text: $query, prompt: Text(tr("Поиск проекта", "Search projects")).foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain).font(OrbitFont.ui(13))
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .frame(width: 232)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

                MenuChip(icon: "arrow.up.arrow.down", title: tr("Сортировка: \(sort.title)", "Sort: \(sort.title)"), chevron: false) {
                    ForEach(Sort.allCases, id: \.self) { s in Button(s.title.capitalizedFirst) { sort = s } }
                }

                OrbitButton(tr("Добавить проект", "Add project"), icon: "folder.badge.plus", kind: .primary, action: addProject)
            }

            let cells: [ProjectSnapshot?] = sorted.map { Optional($0) } + [nil]
            Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                ForEach(Array(stride(from: 0, to: cells.count, by: 3)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(start..<min(start + 3, cells.count), id: \.self) { i in
                            Group {
                                if let snap = cells[i] { ProjectCard(snap: snap) } else { ConnectCard(action: addProject) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .appearStagger(i)
                        }
                        ForEach(0..<(3 - min(3, cells.count - start)), id: \.self) { _ in Color.clear.gridCellUnsizedAxes(.vertical) }
                    }
                }
            }

            MonthTimeCard().appearStagger(min(cells.count, 11))

            ForEach(archived) { p in
                HStack(spacing: 14) {
                    Image(systemName: "archivebox").foregroundStyle(Theme.text2)
                    Text(tr("Архив", "Archive")).uiFont(14, .semibold)
                    Text(p.name).monoFont(13, color: Theme.text2)
                    Text(app.repos[p.id]?.lastCommit.map { tr("последняя работа \(DateFormat.short($0.date))", "last worked \(DateFormat.short($0.date))") } ?? "").uiFont(13, color: Theme.text3)
                    Spacer()
                    Button(tr("Вернуть в работу", "Restore")) { app.updateProject(p.id) { $0.archived = false } }
                        .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(13, .medium))
                    Button(tr("Отключить", "Remove")) { app.removeProject(p.id) }
                        .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(13)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .cardStyle()
            }
        }
    }

    private var sorted: [ProjectSnapshot] {
        let list = app.activeSnapshots.filter { query.isEmpty || $0.config.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .health: return list.sorted { (app.health[$0.config.id] ?? 0) > (app.health[$1.config.id] ?? 0) }
        case .name: return list.sorted { $0.config.name < $1.config.name }
        case .activity: return list.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        }
    }

    private func addProject() {
        if let path = FolderPicker.pick(message: tr("Выберите папку с git-репозиторием", "Choose a folder with a git repository")) { app.addProject(path: path) }
    }
}

struct ProjectCard: View {
    @Environment(AppState.self) private var app
    var snap: ProjectSnapshot

    var body: some View {
        let pid = snap.config.id
        let score = app.health[pid] ?? 0
        let r = snap.repo
        Button { app.screen = .project(pid) } label: {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProjectSquare(colorIndex: snap.config.colorIndex, size: 10)
                        Text(snap.config.name).monoFont(16, .semibold).lineLimit(1)
                        Spacer()
                        Text("\(score)").font(OrbitFont.ui(26, .semibold)).foregroundStyle(Theme.healthColor(score))
                            .numericTransition(score)
                    }
                    Text(([snap.config.displayPath] + r.stack).joined(separator: " · ")).uiFont(12.5, color: Theme.text3)
                        .lineLimit(1).truncationMode(.head)
                }
                HealthBar(score: score)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: app.projectAI(pid) != nil ? "sparkles" : "function").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text(app.cardSummary(snap)).uiFont(13).lineSpacing(4).lineLimit(3)
                        .contentTransition(.opacity)
                        .animation(Motion.pick(Motion.content), value: app.cardSummary(snap))
                        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(alignment: .top) {
                    stat("\(snap.sessions(in: 7).count)", tr("Сессии / 7 дн.", "Sessions / 7 d"))
                    stat("\(snap.commits(in: 7).count)", tr("Коммиты / 7 дн.", "Commits / 7 d"))
                    stat("\(r.changes.count)", tr("Изменения", "Changes"), color: r.changes.isEmpty ? Theme.text : Theme.yellow)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 6) {
                    ForEach(workDays, id: \.self) { d in
                        Tag(text: Week.shortNames[d], color: Theme.projectColor(snap.config.colorIndex), size: 12)
                    }
                    if workDays.isEmpty { Text(tr("не запланирован", "not planned")).uiFont(12, color: Theme.text3) }
                    Spacer()
                    Text(snap.lastActivity.map { DateFormat.relativeDay($0) } ?? "—").uiFont(12.5, color: Theme.text3)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardStyle()
            .hoverHighlight(.card, radius: 12)
        }
        .buttonStyle(PlainButtonStyle2())
        .contextMenu {
            Button(tr("Открыть в терминале", "Open in Terminal")) { app.openTerminal(pid) }
            Button(tr("Показать в Finder", "Show in Finder")) { Shell.reveal(snap.config.path) }
            Button(tr("В архив", "Archive")) { app.updateProject(pid) { $0.archived = true } }
        }
    }

    private var workDays: [Int] {
        if !snap.config.workDays.isEmpty { return snap.config.workDays.sorted() }
        return Array(Set(app.plan(app.displayWeekKey).blocks.filter { $0.projectId == snap.config.id }.map(\.day))).sorted()
    }

    private func stat(_ value: String, _ label: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).uiFont(16, .semibold, color: color)
            Text(label).uiFont(12, color: Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                IconBox(symbol: "folder.badge.plus", color: Theme.text2, size: 40)
                Text(tr("Подключить репозиторий", "Add repository")).uiFont(14, .semibold)
                Text(tr("Укажите папку — Orbit найдёт git и логи сессий Claude Code, Codex и Aider", "Pick a folder — Orbit finds git and the Claude Code, Codex and Aider session logs"))
                    .uiFont(13, color: Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 240)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
    }
}

/// "Время по проектам · <месяц>": actual agent hours vs planned.
struct MonthTimeCard: View {
    @Environment(AppState.self) private var app
    @State private var barShown = false

    var body: some View {
        let cal = Week.calendar
        let start = cal.date(from: cal.dateComponents([.year, .month], from: app.now))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let rows = app.activeSnapshots.map { snap -> (ProjectSnapshot, Double, Double) in
            (snap, Activity.hours(snap.sessions, timer: app.worklog.intervals.filter { $0.projectId == snap.config.id }, from: start, to: end, now: app.now),
             plannedHours(snap.config.id, from: start, to: end))
        }
        .sorted { $0.1 > $1.1 }
        let actual = rows.reduce(0) { $0 + $1.1 }
        let planned = rows.reduce(0) { $0 + $1.2 }

        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(tr("Время по проектам · \(DateFormat.monthStandalone.string(from: app.now))", "Time per project · \(DateFormat.monthStandalone.string(from: app.now))")).uiFont(14, .semibold)
                    Spacer()
                    Text(tr("\(Duration.hours(actual)) ч фактически · \(Duration.hours(planned)) ч по плану", "\(Duration.hours(actual)) h actual · \(Duration.hours(planned)) h planned")).uiFont(12.5, color: Theme.text3)
                }
                GeometryReader { geo in
                    HStack(spacing: 4) {
                        ForEach(rows.filter { $0.1 > 0 }, id: \.0.config.id) { snap, hours, _ in
                            Capsule().fill(Theme.projectColor(snap.config.colorIndex))
                                .frame(width: max(4, (geo.size.width - 4 * CGFloat(rows.count)) * hours / max(actual, 0.01)))
                        }
                    }
                    // The stacked bar draws in from the left.
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: barShown ? geo.size.width : 0)
                    }
                }
                .frame(height: 10)
                .onAppear { withMotion(Motion.grow) { barShown = true } }
                HStack(alignment: .top) {
                    ForEach(rows.prefix(6), id: \.0.config.id) { snap, hours, plan in
                        VStack(alignment: .leading, spacing: 6) {
                            ProjectLabel(projectId: snap.config.id, size: 12.5)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(tr("\(Duration.hours(hours)) ч", "\(Duration.hours(hours)) h")).uiFont(16, .semibold)
                                if plan > 0 {
                                    Text(tr("из \(Duration.hours(plan)) ч", "of \(Duration.hours(plan)) h")).uiFont(12, color: hours < plan * 0.6 ? Theme.yellow : Theme.text3)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func plannedHours(_ pid: String, from: Date, to: Date) -> Double {
        app.plans.values.reduce(0) { sum, plan in
            guard let monday = Week.date(fromKey: plan.weekKey) else { return sum }
            return sum + plan.blocks.filter { b in
                let d = Week.day(b.day, of: monday)
                return b.projectId == pid && d >= from && d < to
            }.reduce(0) { $0 + $1.hours }
        }
    }
}
