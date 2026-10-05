import SwiftUI

/// "Разбить цель на задачи": describe a goal, AI suggests steps, you keep the ones you want.
struct TaskGoalSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: String

    @State private var goal = ""
    @State private var drafts: [TaskDraft] = []
    @State private var thinking = false
    @State private var error: String?
    @State private var folders: [String] = []
    @FocusState private var goalFocused: Bool

    #if DEBUG
    /// Set by the snapshot tool: fill the goal and run at once; `debugDone` flips when the answer is in.
    nonisolated(unsafe) static var debugGoal: String?
    nonisolated(unsafe) static var debugDone = false
    #endif

    var body: some View {
        let selected = drafts.filter(\.selected).count
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                goalField
                if app.config.ai.isEnabled { actions } else { noModel }
                if let error {
                    Text(error).uiFont(12.5, color: Theme.red).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if !drafts.isEmpty { list.transition(Motion.transition(Motion.rise)) }
            }
            .padding(28)
            footer(selected)
        }
        .frame(width: 640)
        .background(Theme.surface)
        .animation(Motion.pick(Motion.page), value: drafts)
        .animation(Motion.pick(Motion.content), value: error)
        .animation(Motion.pick(Motion.content), value: thinking)
        .task {
            let path = app.project(projectId)?.path ?? projectId
            folders = await Task.detached { TaskArea.folders(in: path) }.value
            goalFocused = true
            #if DEBUG
            if let g = Self.debugGoal { goal = g; run() }
            #endif
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Разбить цель на задачи", "Break a goal into tasks")).uiFont(18, .semibold)
                Text(app.projectName(projectId)).monoFont(12.5, color: Theme.text2)
            }
            Spacer()
            Button { dismiss() } label: {
                Icon("xmark", size: 13, weight: .regular).foregroundStyle(Theme.text2).frame(width: 28, height: 28)
            }
            .buttonStyle(PlainButtonStyle2())
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
        .hairline()
    }

    private var goalField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Цель", "Goal")).uiFont(12, .medium, color: Theme.text2)
            ZStack(alignment: .topLeading) {
                if goal.isEmpty {
                    Text(tr("Например: оплата картой в кассе — от кнопки до чека", "For example: card payments at the checkout, from the button to the receipt"))
                        .uiFont(14, color: Theme.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $goal)
                    .font(OrbitFont.ui(14))
                    .scrollContentBackground(.hidden)
                    .focused($goalFocused)
            }
            .padding(12)
            .frame(height: 92)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(goalFocused ? Theme.text3 : Theme.border))
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            OrbitButton(drafts.isEmpty ? tr("Разбить на задачи", "Break it down") : tr("Ещё вариант", "Another option"),
                        icon: drafts.isEmpty ? "sparkles" : "arrow.clockwise", kind: drafts.isEmpty ? .primary : .secondary) { run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(thinking || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if thinking {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !Motion.reduced)
                    Text(tr("Думаю…", "Thinking…")).uiFont(12.5, color: Theme.text2)
                }
                .transition(.opacity)
            } else if !drafts.isEmpty, let label = app.aiLabel {
                Text(label).uiFont(12, color: Theme.text3).transition(.opacity)
            }
            Spacer()
            Text("⌘↵").monoFont(11, color: Theme.text3)
        }
    }

    private var noModel: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Чтобы разбивать цели на задачи, выберите модель: Claude, Codex, Ollama или API. Локальные эвристики этого не умеют.",
                        "To break goals into tasks, pick a model: Claude, Codex, Ollama or an API. Local heuristics can't do this."))
                    .uiFont(13, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text(tr("Открыть настройки", "Open Settings")).uiFont(12.5, .medium, color: Theme.accent) }
                    .buttonStyle(PlainButtonStyle2())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach($drafts) { $draft in
                    DraftRow(draft: $draft, folders: folders)
                        .transition(Motion.transition(.opacity.combined(with: .offset(y: -6))))
                }
            }
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle(radius: 10, fill: Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func footer(_ selected: Int) -> some View {
        HStack(spacing: 10) {
            if !drafts.isEmpty {
                Text(tr("Снимите лишнее и поправьте текст — задачи добавятся в этом порядке.",
                        "Untick what you don't need and edit the text — tasks are added in this order."))
                    .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
            if !drafts.isEmpty {
                OrbitButton(tr("Добавить \(plural(selected, ru: ("задачу", "задачи", "задач"), en: ("task", "tasks")))",
                               "Add \(plural(selected, ru: ("задачу", "задачи", "задач"), en: ("task", "tasks")))"),
                            icon: "plus", kind: .primary) {
                    withMotion { app.addTasks(projectId, drafts) }
                    app.toast = tr("Добавлено: \(plural(selected, ru: ("задача", "задачи", "задач"), en: ("task", "tasks")))",
                                   "Added \(plural(selected, ru: ("задача", "задачи", "задач"), en: ("task", "tasks")))")
                    dismiss()
                }
                .disabled(selected == 0)
                .transition(Motion.transition(Motion.pop))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .hairline(.top)
    }

    // MARK: - Actions

    private func run() {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        thinking = true
        error = nil
        Task {
            do {
                let result = try await app.aiTasks(projectId, goal: text)
                withMotion(Motion.page) { drafts = result }
            } catch {
                self.error = error.localizedDescription
            }
            thinking = false
            #if DEBUG
            Self.debugDone = true
            #endif
        }
    }
}

/// One suggested task: tick, editable title, urgency and folder.
private struct DraftRow: View {
    @Binding var draft: TaskDraft
    var folders: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { withMotion { draft.selected.toggle() } } label: { TaskCheckbox(checked: draft.selected) }
                .buttonStyle(PlainButtonStyle2())
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(OrbitFont.ui(13.5, .medium))
                    .foregroundStyle(draft.selected ? Theme.text : Theme.text3)
                HStack(spacing: 8) {
                    Button { withMotion { draft.urgent.toggle() } } label: {
                        HStack(spacing: 5) {
                            Dot(color: draft.urgent ? Theme.red : Theme.text3)
                            Text(tr("Срочно", "Urgent")).uiFont(11.5, .medium, color: draft.urgent ? Theme.red : Theme.text3)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .background(draft.urgent ? Theme.red.opacity(0.12) : Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(PlainButtonStyle2())
                    Menu {
                        ForEach(folders, id: \.self) { f in Button(f + "/") { draft.area = f } }
                        if !folders.isEmpty { Divider() }
                        Button(tr("Без папки", "No folder")) { draft.area = nil }
                    } label: {
                        Text(draft.area.map { $0 + "/" } ?? tr("папка", "folder"))
                            .monoFont(11.5, color: draft.area == nil ? Theme.text3 : Theme.text2)
                            .padding(.vertical, 2).padding(.horizontal, 7)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .menuStyle(.button)
                    .buttonStyle(PlainButtonStyle2())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(draft.selected ? 1 : 0.6)
        .hairline()
    }
}
