import SwiftUI
import UniformTypeIdentifiers

/// "Что открывать": the apps and links "Начать разработку" opens for a project.
struct LaunchSetSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: String

    @State private var items: [LaunchItem] = []
    @State private var link = ""
    @State private var linkError = false
    @State private var trusted = SpaceManager.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Что открывать", "What to open")).uiFont(18, .semibold)
                Text(tr("«Начать разработку» откроет это и запустит таймер · \(app.projectName(projectId))",
                        "“Start development” opens these and starts the timer · \(app.projectName(projectId))"))
                    .uiFont(12.5, color: Theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            .hairline()

            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    ForEach($items) { $item in
                        LaunchRow(item: $item) { withMotion { items.removeAll { $0.id == item.id } } }
                            .transition(Motion.transition(.opacity.combined(with: .offset(y: -6))))
                    }
                    if items.isEmpty {
                        Text(tr("Ничего не выбрано — будет только таймер.", "Nothing selected — just the timer."))
                            .uiFont(12.5, color: Theme.text3).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                .cardStyle(radius: 10, fill: Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    OrbitButton(tr("Приложение", "App"), icon: "plus", compact: true) { pickApp() }
                    if !items.contains(where: { $0.kind == .terminalAgent }) {
                        OrbitButton(tr("Терминал с агентом", "Terminal with agent"), icon: "terminal", compact: true) {
                            withMotion { items.insert(LaunchSet.terminalItem(), at: 0) }
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    TextField("", text: $link, prompt: Text(tr("Ссылка: localhost:3000, figma.com/…", "Link: localhost:3000, figma.com/…")).foregroundStyle(Theme.text3))
                        .textFieldStyle(.plain)
                        .font(OrbitFont.ui(13))
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(linkError ? Theme.red : Theme.border))
                        .onSubmit(addLink)
                        .onChange(of: link) { linkError = false }
                    OrbitButton(tr("Добавить", "Add"), compact: true) { addLink() }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                workspace.padding(.top, 6)
            }
            .padding(28)

            HStack(spacing: 10) {
                OrbitButton(tr("Сбросить к стандартному", "Reset to default"), kind: .ghost) {
                    withMotion { items = LaunchSet.defaults() }
                }
                Spacer()
                OrbitButton(tr("Отмена", "Cancel")) { dismiss() }
                OrbitButton(tr("Сохранить", "Save"), icon: "checkmark", kind: .primary) {
                    app.updateProject(projectId) { $0.launch = items }
                    dismiss()
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .hairline(.top)
        }
        .frame(width: 560)
        .background(Theme.surface)
        .onAppear {
            if let p = app.project(projectId) { items = LaunchSet.items(for: p) }
        }
        .task {
            // Picks up the Accessibility permission as soon as it is granted in System Settings.
            while !Task.isCancelled {
                trusted = SpaceManager.isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .animation(Motion.pick(Motion.content), value: trusted)
    }

    /// Settings shared by all projects: a desktop of its own, and tidying up on "Стоп".
    private var workspace: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("Для всех проектов", "For all projects")).uiFont(12, .medium, color: Theme.text3)
            option(tr("Открывать на новом рабочем столе", "Open on a new desktop"),
                   tr("По «Стоп» стол удаляется, оставшиеся окна переедут на соседний", "On “Stop” the desktop is removed; windows left on it move next door"),
                   isOn: Binding(get: { app.config.devNewDesktop }, set: { app.config.devNewDesktop = $0; app.saveConfig() }))
            if app.config.devNewDesktop && !trusted {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.yellow)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Нужен «Универсальный доступ»: так Orbit добавляет и убирает рабочие столы через Mission Control.",
                                "Orbit needs Accessibility to add and remove desktops through Mission Control."))
                            .uiFont(12.5, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                        OrbitButton(tr("Открыть настройки", "Open Settings"), icon: "lock", compact: true) {
                            SpaceManager.requestTrust()
                            SpaceManager.openAccessibilitySettings()
                        }
                    }
                }
                .padding(12)
                .background(Theme.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .transition(Motion.transition(Motion.rise))
            }
            option(tr("По «Стоп» закрывать все окна на столе проекта", "Close every window on the project desktop on “Stop”"),
                   tr("Приложение без окон на других столах завершится. Если что-то спросит про несохранённое — Orbit подождёт вас", "Apps with no windows on other desktops quit. If one asks about unsaved work, Orbit waits for you"),
                   isOn: Binding(get: { app.config.devCloseOnStop }, set: { app.config.devCloseOnStop = $0; app.saveConfig() }))
        }
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

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.message = tr("Выберите приложения для этого проекта", "Choose apps for this project")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { LaunchSet.appItem($0.path) }
            .filter { new in !items.contains { $0.kind == new.kind } }
        withMotion { items += added }
    }

    private func addLink() {
        guard let item = LaunchSet.urlItem(link) else { linkError = true; return }
        withMotion { items.append(item) }
        link = ""
    }
}

private struct LaunchRow: View {
    @Binding var item: LaunchItem
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).uiFont(13.5, .medium, color: item.enabled ? Theme.text : Theme.text3)
                Text(subtitle).monoFont(11.5, color: Theme.text3).lineLimit(1).truncationMode(path.isEmpty ? .tail : .middle)
            }
            Spacer(minLength: 8)
            if case .app = item.kind, LaunchSet.isEditor(path) {
                Toggle(tr("С папкой проекта", "With project folder"), isOn: $item.opensFolder)
                    .toggleStyle(.checkbox).font(OrbitFont.ui(12)).foregroundStyle(Theme.text2)
            }
            OrbitToggle(isOn: $item.enabled)
            Button(action: onRemove) {
                Icon("xmark", size: 11, weight: .regular).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle2())
            .help(tr("Убрать", "Remove"))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .hairline()
    }

    private var path: String { if case .app(let p) = item.kind { p } else { "" } }

    private var subtitle: String {
        switch item.kind {
        case .terminalAgent: tr("продолжит сессию или запустит claude", "resumes a session or starts claude")
        case .app(let p): p.abbreviatingHome
        case .url(let s): s
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .terminalAgent: Image(systemName: "terminal").font(.system(size: 14)).foregroundStyle(Theme.text2)
        case .app(let p): Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable()
        case .url: Image(systemName: "link").font(.system(size: 14)).foregroundStyle(Theme.text2)
        }
    }
}
