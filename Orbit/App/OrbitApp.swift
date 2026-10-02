import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Orbit keeps monitoring from the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("Orbit", id: "main") {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    app.load()
                    #if DEBUG
                    await Snapshotter.run(app)
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 1000)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Обновить данные") { Task { await app.refresh() } }
                    .keyboardShortcut("r")
                Button("Запланировать неделю") { app.sheet = .planner(weekKey: app.currentWeekKey) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Перейти") {
                Button("Неделя") { app.screen = .week }.keyboardShortcut("1")
                Button("Проекты") { app.screen = .projects }.keyboardShortcut("2")
                Button("Сессии агентов") { app.screen = .sessions }.keyboardShortcut("3")
                Button("Git") { app.screen = .git }.keyboardShortcut("4")
                Button("Сигналы") { app.screen = .signals }.keyboardShortcut("5")
            }
        }

        Settings {
            SettingsView().environment(app)
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            Image(systemName: app.activeSignals.isEmpty ? "circle.circle" : "circle.circle.fill")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let focus = app.todayFocus {
            Text("Сегодня: \(app.projectName(focus.projectId)) · \(Duration.hours(focus.hours)) ч")
        } else {
            Text("На сегодня ничего не запланировано")
        }
        Text("Сигналов: \(app.activeSignals.count)")
        Divider()
        Button("Открыть Orbit") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Обновить") { Task { await app.refresh() } }
        Divider()
        Text("Orbit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        Button("Выйти") { NSApp.terminate(nil) }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.config.onboarded {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .background(Theme.bg)
        .font(OrbitFont.ui(13))
        .foregroundStyle(Theme.text)
    }
}

struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            SidebarView()
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let toast = app.toast {
                    ToastView(text: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation { app.toast = nil }
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: app.toast)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .sheet(item: $app.sheet) { sheet in
            SheetHost(sheet: sheet).environment(app)
        }
    }

    @ViewBuilder private var content: some View {
        switch app.screen {
        case .week: WeekView()
        case .projects: ProjectsView()
        case .project(let id): ProjectDetailView(projectId: id)
        case .sessions: SessionsView()
        case .git: GitView()
        case .signals: SignalsView()
        }
    }
}

struct SheetHost: View {
    var sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .planner(let key): WeekPlannerSheet(weekKey: key)
        case .commit(let pid): CommitSheet(projectId: pid)
        case .diff(let pid): DiffSheet(projectId: pid)
        case .brief(let sid): BriefSheet(signalId: sid)
        case .transcript(let sid): TranscriptSheet(sessionId: sid)
        case .addBlock(let day): AddBlockSheet(day: day)
        }
    }
}

struct ToastView: View {
    var text: String

    var body: some View {
        Text(text)
            .uiFont(13, .medium)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

/// Scrollable page container with the design's 28/36 paddings.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
    }
}
