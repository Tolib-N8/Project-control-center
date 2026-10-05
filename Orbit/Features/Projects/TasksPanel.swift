import SwiftUI

/// "Задачи" on the project screen: a quick inbox of to-dos with urgency, due day and folder.
struct TasksPanel: View {
    @Environment(AppState.self) private var app
    var projectId: String

    enum Tab: Hashable { case open, done }

    @State private var tab = Tab.open
    @State private var showDone = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    /// Just-checked tasks stay in "Open" for a moment so the tick is visible before they leave.
    @State private var lingering: Set<UUID> = []
    @State private var folders: [String] = []

    var body: some View {
        let all = app.tasks(for: projectId)
        let openCount = all.filter { !$0.done }.count
        let done = TaskOrdering.done(all)
        let open = TaskOrdering.open(all.map { t in
            var t = t
            if lingering.contains(t.id) { t.completedAt = nil }
            return t
        })
        // Rows show the real state, the order keeps lingering tasks in place.
        let openRows = open.compactMap { t in all.first { $0.id == t.id } }

        VStack(spacing: 0) {
            header(open: openCount, done: done.count)
            if tab == .open {
                input
                ForEach(openRows) { row($0) }
                if openRows.isEmpty {
                    hint(done.isEmpty ? tr("Задач пока нет — запишите первую", "No tasks yet — write down the first one")
                                      : tr("Все задачи выполнены", "All tasks are done"))
                }
                if !done.isEmpty { doneToggle(done.count) }
                if showDone {
                    ForEach(done) { row($0) }
                }
            } else {
                ForEach(done) { row($0) }
                if done.isEmpty { hint(tr("Пока ничего не выполнено", "Nothing done yet")) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .cardStyle()
        .animation(Motion.pick(Motion.snappy), value: all)
        .animation(Motion.pick(Motion.snappy), value: lingering)
        .animation(Motion.pick(Motion.snappy), value: showDone)
        .animation(Motion.pick(Motion.page), value: tab)
        .task(id: projectId) {
            let path = app.project(projectId)?.path ?? projectId
            folders = await Task.detached { TaskArea.folders(in: path) }.value
        }
    }

    // MARK: - Parts

    private func header(open: Int, done: Int) -> some View {
        HStack {
            Text(tr("Задачи", "Tasks")).uiFont(14, .semibold)
            Spacer()
            SegmentedTabs(items: [(Tab.open, tr("Открытые · \(open)", "Open · \(open)")),
                                  (Tab.done, tr("Готово · \(done)", "Done · \(done)"))],
                          selection: $tab)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .hairline()
    }

    private var input: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(inputFocused ? Theme.accent : Theme.text3)
                .frame(width: 16, height: 16)
                .animation(Motion.pick(Motion.snappy), value: inputFocused)
            TextField("", text: $draft, prompt: Text(tr("Новая задача…", "New task…")).foregroundStyle(Theme.text3))
                .textFieldStyle(.plain)
                .font(OrbitFont.ui(13))
                .focused($inputFocused)
                .onSubmit(add)
            Text("↵").monoFont(11, color: Theme.text3)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(inputFocused ? Theme.text3 : Theme.border))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .hairline()
    }

    private func row(_ task: ProjectTask) -> some View {
        TaskRow(task: task, folders: folders, onToggle: { toggle(task) })
            .transition(Motion.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                                                      removal: .opacity.combined(with: .offset(x: 12)))))
    }

    private func doneToggle(_ count: Int) -> some View {
        Button { withMotion { showDone.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .rotationEffect(.degrees(showDone ? 90 : 0))
                    .frame(width: 16, height: 16)
                Text(tr("Выполненные · \(count)", "Completed · \(count)")).uiFont(12, color: Theme.text2)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .hoverHighlight()
        }
        .buttonStyle(PlainButtonStyle2())
        .hairline(showDone ? .bottom : .top)
    }

    private func hint(_ text: String) -> some View {
        Text(text).uiFont(12.5, color: Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 18)
            .transition(.opacity)
    }

    // MARK: - Actions

    private func add() {
        guard app.addTask(projectId, title: draft) != nil else { return }
        draft = ""
        inputFocused = true
    }

    private func toggle(_ task: ProjectTask) {
        let finishing = !task.done && tab == .open
        withMotion { app.toggleTask(task.id) }
        guard finishing else { return }
        lingering.insert(task.id)
        Task {
            try? await Task.sleep(for: .milliseconds(Motion.reduced ? 250 : 650))
            withMotion { _ = lingering.remove(task.id) }
        }
    }
}

struct TaskRow: View {
    @Environment(AppState.self) private var app
    var task: ProjectTask
    var folders: [String]
    var onToggle: () -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) { TaskCheckbox(checked: task.done) }
                .buttonStyle(PlainButtonStyle2())
                .help(task.done ? tr("Вернуть в открытые", "Reopen") : tr("Отметить выполненной", "Mark as done"))

            VStack(alignment: .leading, spacing: 4) {
                title
                if task.urgent || task.area != nil {
                    HStack(spacing: 10) {
                        if task.urgent && !task.done {
                            HStack(spacing: 5) {
                                Dot(color: Theme.red)
                                Text(tr("Срочно", "Urgent")).uiFont(11.5, .medium, color: Theme.red)
                            }
                        }
                        if let area = task.area {
                            Text(area + "/").monoFont(11.5, color: Theme.text2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !task.done {
                Button {} label: { BotIcon() }
                    .buttonStyle(AssignAgentButtonStyle())
                    .help(tr("Назначение агенту — скоро", "Assigning to an agent — coming soon"))
            }
            trailing.frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 12)
        .hoverHighlight()
        .hairline()
        .contextMenu { menu }
    }

    @ViewBuilder private var title: some View {
        if editing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(OrbitFont.ui(13.5, .medium))
                .focused($editFocused)
                .onSubmit(commitRename)
                .onExitCommand { editing = false }
                .onChange(of: editFocused) { _, focused in if !focused { commitRename() } }
        } else {
            Text(task.title)
                .uiFont(13.5, task.done ? .regular : .medium, color: task.done ? Theme.text3 : Theme.text)
                .strikethrough(task.done, color: Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { startRename() }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let completed = task.completedAt {
            Text(DateFormat.relativeDay(completed, withTime: false)).uiFont(12, color: Theme.text3)
        } else {
            let due = TaskDue.label(task.due, now: app.now)
            Text(due.text).uiFont(12, color: color(due.tone)).lineLimit(1)
                .help(due.tone == .overdue ? tr("Просрочено", "Overdue") : "")
        }
    }

    private func color(_ tone: TaskDue.Tone) -> Color {
        switch tone {
        case .overdue: Theme.red
        case .today: Theme.yellow
        case .normal, .none: Theme.text3
        }
    }

    @ViewBuilder private var menu: some View {
        if task.done {
            Button(tr("Вернуть в открытые", "Reopen")) { onToggle() }
        } else {
            Button(task.urgent ? tr("Снять «Срочно»", "Remove “Urgent”") : tr("Срочно", "Urgent")) {
                withMotion { app.updateTask(task.id) { $0.urgent.toggle() } }
            }
            Menu(tr("Срок", "Due")) {
                ForEach(TaskDue.choices(now: app.now), id: \.key) { choice in
                    Button(choice.title) { withMotion { app.updateTask(task.id) { $0.due = choice.key } } }
                }
                Divider()
                Button(tr("Без срока", "No due date")) { withMotion { app.updateTask(task.id) { $0.due = nil } } }
            }
            Menu(tr("Папка", "Folder")) {
                ForEach(folders, id: \.self) { folder in
                    Button(folder + "/") { withMotion { app.updateTask(task.id) { $0.area = folder } } }
                }
                if !folders.isEmpty { Divider() }
                Button(tr("Без папки", "No folder")) { withMotion { app.updateTask(task.id) { $0.area = nil } } }
            }
            Button(tr("Переименовать", "Rename")) { startRename() }
        }
        Divider()
        Button(tr("Удалить", "Delete"), role: .destructive) { withMotion { app.deleteTask(task.id) } }
    }

    private func startRename() {
        text = task.title
        editing = true
        editFocused = true
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != task.title { app.updateTask(task.id) { $0.title = title } }
    }
}

/// 16 pt checkbox: outlined, brighter on hover, filled green with a tick that pops in.
struct TaskCheckbox: View {
    var checked: Bool
    @State private var hover = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(checked ? Theme.green : hover ? Theme.surface2 : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(checked ? .clear : hover ? Theme.text2 : Theme.text3, lineWidth: 1.5))
            .overlay {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.bg)
                        .transition(Motion.transition(.scale(scale: 0.4).combined(with: .opacity)))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onHover { h in withMotion { hover = h } }
            .animation(Motion.pick(.spring(response: 0.25, dampingFraction: 0.7)), value: checked)
    }
}

/// The "assign an agent" button: outlined, pressed state fills like the design.
struct AssignAgentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hover in
            configuration.label
                .foregroundStyle(configuration.isPressed || hover ? Theme.text : Theme.text2)
                .frame(width: 24, height: 24)
                .background(configuration.isPressed ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(configuration.isPressed || hover ? Theme.text3 : Theme.border))
                .contentShape(Rectangle())
                .animation(Motion.pick(Motion.snappy), value: configuration.isPressed)
        }
    }
}

private struct Hovering<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        content(hover).onHover { h in withMotion { hover = h } }
    }
}

/// Lucide's "bot" glyph, the icon the design uses for agents.
struct BotIcon: View {
    var size: CGFloat = 12

    var body: some View {
        BotShape()
            .stroke(style: StrokeStyle(lineWidth: size / 12 * 1.1, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct BotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(12, 8)); path.addLine(to: p(12, 4)); path.addLine(to: p(8, 4))
        path.addRoundedRect(in: CGRect(origin: p(4, 8), size: CGSize(width: 16 * s, height: 12 * s)), cornerSize: CGSize(width: 2 * s, height: 2 * s))
        path.move(to: p(2, 14)); path.addLine(to: p(4, 14))
        path.move(to: p(20, 14)); path.addLine(to: p(22, 14))
        path.move(to: p(15, 13)); path.addLine(to: p(15, 15))
        path.move(to: p(9, 13)); path.addLine(to: p(9, 15))
        return path
    }
}
