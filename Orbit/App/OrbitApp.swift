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
            let _ = app.languageRevision
            CommandGroup(after: .appInfo) {
                Button(tr("Проверить обновления…", "Check for Updates…")) { Task { await app.checkForUpdates(manual: true) } }
            }
            CommandGroup(after: .newItem) {
                Button(tr("Обновить данные", "Refresh Data")) { Task { await app.refresh() } }
                    .keyboardShortcut("r")
                Button(tr("Запланировать неделю", "Plan the Week")) { app.sheet = .planner(weekKey: app.currentWeekKey) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu(tr("Перейти", "Go")) {
                Button(tr("Неделя", "Week")) { app.screen = .week }.keyboardShortcut("1")
                Button(tr("Проекты", "Projects")) { app.screen = .projects }.keyboardShortcut("2")
                Button(tr("Сессии агентов", "Agent Sessions")) { app.screen = .sessions }.keyboardShortcut("3")
                Button("Git") { app.screen = .git }.keyboardShortcut("4")
                Button(tr("Сигналы", "Signals")) { app.screen = .signals }.keyboardShortcut("5")
            }
        }

        Settings {
            SettingsView().environment(app)
        }

        MenuBarExtra {
            MenuBarPanel().environment(app)
        } label: {
            MenuBarLabel().environment(app)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var splash = LaunchSplash.shouldPlay
    @Namespace private var logoSpace

    var body: some View {
        ZStack {
            Group {
                if app.config.onboarded {
                    // Rebuilt on a language switch so every screen picks up the new strings.
                    MainView().id(app.languageRevision)
                } else {
                    OnboardingView()
                }
            }
            .environment(\.logoNamespace, logoSpace)
            .environment(\.splashActive, splash)

            if splash {
                // The splash dissolves while its logo flies into the sidebar.
                LaunchSplash(namespace: logoSpace) {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { splash = false }
                }
                .transition(.opacity)
                .zIndex(1)
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
                    .id(app.screen)
                    .transition(screenTransition)
                if let toast = app.toast {
                    ToastView(text: toast)
                        .padding(.bottom, 24)
                        .transition(Motion.transition(.move(edge: .bottom).combined(with: Motion.pop)))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(4))
                            withMotion { app.toast = nil }
                        }
                }
            }
            .clipped()
            .animation(Motion.pick(Motion.page), value: app.screen)
            .animation(Motion.pick(Motion.snappy), value: app.toast)
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .sheet(item: $app.sheet) { sheet in
            SheetHost(sheet: sheet).environment(app)
        }
    }

    /// Into a project slides in from the right, back out from the left, sidebar hops rise softly.
    /// The outgoing screen just fades so the two never fight for attention.
    private var screenTransition: AnyTransition {
        let insertion: AnyTransition
        switch app.navDirection {
        case .deeper: insertion = .opacity.combined(with: .offset(x: 24))
        case .back: insertion = .opacity.combined(with: .offset(x: -24))
        case .lateral: insertion = Motion.rise
        }
        // The old screen is gone in 80 ms and the new one starts right after, so they barely overlap.
        return Motion.transition(.asymmetric(insertion: insertion.animation(Motion.page.delay(0.06)),
                                             removal: .opacity.animation(.easeOut(duration: 0.08))))
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
        case .update: UpdateSheet()
        case .taskGoal(let pid): TaskGoalSheet(projectId: pid)
        case .launchSet(let pid): LaunchSetSheet(projectId: pid)
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
