import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                LogoMark()
                Text("Orbit").uiFont(16, .semibold)
            }
            .padding(.horizontal, 6)
            .padding(.top, 30) // room for the window controls

            VStack(spacing: 2) {
                navItem(.week, "Неделя", "calendar")
                navItem(.projects, "Проекты", "square.grid.2x2")
                navItem(.sessions, "Сессии агентов", "cpu")
                navItem(.git, "Git", "arrow.triangle.branch")
                navItem(.signals, "Сигналы", "bell", badge: app.activeSignals.count)
            }

            VStack(spacing: 2) {
                HStack {
                    Eyebrow(text: "Проекты")
                    Spacer()
                    Button(action: pickFolder) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(PlainButtonStyle2())
                    .help("Подключить репозиторий")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(app.config.activeProjects) { p in projectItem(p) }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
            syncStatus
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func isSelected(_ screen: Screen) -> Bool {
        if app.screen == screen { return true }
        if case .project = app.screen, screen == .projects { return false }
        return false
    }

    private func navItem(_ screen: Screen, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        let selected = isSelected(screen)
        return Button { app.screen = screen } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Text(title).uiFont(13, selected ? .medium : .regular, color: selected ? Theme.text : Theme.text2)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)").uiFont(11, .semibold, color: Theme.red)
                        .padding(.vertical, 1).padding(.horizontal, 6)
                        .background(Theme.red.opacity(0.14), in: Capsule())
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(selected ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PlainButtonStyle2())
    }

    private func projectItem(_ p: ProjectConfig) -> some View {
        let selected = app.screen == .project(p.id)
        let score = app.health[p.id]
        return Button { app.screen = .project(p.id) } label: {
            HStack(spacing: 10) {
                ProjectSquare(colorIndex: p.colorIndex)
                Text(p.name).monoFont(12.5).lineLimit(1)
                Spacer(minLength: 0)
                if let score { Dot(color: Theme.healthColor(score)) }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(selected ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PlainButtonStyle2())
        .draggable(PlanDragItem(projectId: p.id))
        .contextMenu {
            Button("Открыть в терминале") { app.openTerminal(p.id) }
            Button("Показать в Finder") { Shell.reveal(p.path) }
            Divider()
            Button("В архив") { app.updateProject(p.id) { $0.archived = true } }
        }
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if app.isSyncing {
                    ProgressView().controlSize(.mini).frame(width: 6, height: 6)
                    Text("Синхронизация…").uiFont(12, .medium)
                } else {
                    Dot(color: app.lastSync == nil ? Theme.text3 : Theme.green)
                    Text(app.lastSync == nil ? "Ожидание" : "Синхронизировано").uiFont(12, .medium)
                }
            }
            Text("\(Plural.repos(app.config.activeProjects.count)) · \(app.lastSync.map { DateFormat.ago($0, now: app.now) } ?? "—")")
                .uiFont(11.5, color: Theme.text3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { Task { await app.refresh() } }
        .help("Обновить сейчас")
    }

    private func pickFolder() {
        if let path = FolderPicker.pick(message: "Выберите папку с git-репозиторием") {
            app.addProject(path: path)
        }
    }
}

/// Payload for dragging a project from the sidebar onto a day.
struct PlanDragItem: Codable, Transferable {
    var projectId: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

enum FolderPicker {
    @MainActor
    static func pick(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: "~/Documents".expandingTilde)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
