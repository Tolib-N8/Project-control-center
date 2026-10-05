import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var tab = "ai"

    var body: some View {
        // Tab contents are rebuilt when the language changes; the selected tab survives.
        TabView(selection: $tab) {
            AISettingsView()
                .id(app.languageRevision)
                .tabItem { Label(tr("Анализ", "Analysis"), systemImage: "sparkles") }
                .tag("ai")
            GeneralSettingsView()
                .id(app.languageRevision)
                .tabItem { Label(tr("Общие", "General"), systemImage: "gearshape") }
                .tag("general")
        }
        .frame(width: 680, height: 720)
        .preferredColorScheme(.dark)
    }
}

struct AISettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Чем анализировать проекты", "How to analyze projects")).uiFont(18, .semibold)
                    Text(tr("Модель пишет выводы по сессиям, следующие шаги, цель дня, разбор сессий, сообщения коммитов и брифы для агентов. Без модели работают локальные эвристики.", "The model writes session summaries, next steps, the goal for the day, session reviews, commit messages and agent briefs. Without a model, local heuristics do the job."))
                        .uiFont(13, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                ProviderPicker()
                if app.config.ai.provider != .heuristics {
                    ProviderDetails()
                }
                privacy
            }
            .padding(24)
        }
        .background(Theme.bg)
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock").foregroundStyle(Theme.text3)
            Text(tr("В модель уходят только сводки: названия файлов и веток, заголовки и итоговые сообщения сессий агентов, сообщения коммитов, ошибки тестов. Исходный код не отправляется — кроме диффа для сообщений коммитов, если это включено. Ключи API хранятся в связке ключей macOS.", "Only summaries go to the model: file and branch names, agent session titles and final messages, commit messages, test errors. Source code is never sent — except the diff for commit messages, if you turn that on. API keys are stored in the macOS Keychain."))
                .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Provider cards with availability; shared by settings and onboarding.
struct ProviderPicker: View {
    @Environment(AppState.self) private var app
    @State private var availability: [AIProviderKind: (ok: Bool, note: String)] = [:]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(AIProviderKind.allCases) { kind in card(kind) }
        }
        .task { await probe() }
    }

    private func probe() async {
        for kind in AIProviderKind.allCases {
            availability[kind] = await AIProviders.availability(kind, config: app.config.ai)
        }
    }

    private func card(_ kind: AIProviderKind) -> some View {
        let selected = app.config.ai.provider == kind
        let state = availability[kind]
        return Button { app.setAIProvider(kind) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: kind.symbol).foregroundStyle(selected ? Theme.accent : Theme.text2)
                    Text(kind.title).uiFont(13.5, .semibold)
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1.5)
                        if selected { Circle().fill(Theme.accent).padding(4) }
                    }
                    .frame(width: 18, height: 18)
                }
                Text(kind.subtitle).uiFont(12, color: Theme.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let state {
                    HStack(spacing: 6) {
                        Dot(color: state.ok ? Theme.green : Theme.text3)
                        Text(state.note).uiFont(11.5, color: state.ok ? Theme.text2 : Theme.text3).lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.accent.opacity(0.06) : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
    }
}

/// Model, key and behaviour settings for the selected provider.
struct ProviderDetails: View {
    @Environment(AppState.self) private var app
    @State private var key = ""
    @State private var ollamaModels: [String] = []
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        @Bindable var app = app
        let kind = app.config.ai.provider
        VStack(alignment: .leading, spacing: 16) {
            if kind.usesModel {
                row(tr("Модель", "Model")) {
                    HStack(spacing: 8) {
                        TextField(kind.defaultModel.isEmpty ? tr("по умолчанию", "default") : kind.defaultModel,
                                  text: Binding(get: { app.config.ai.models[kind.rawValue] ?? "" },
                                                set: { app.config.ai.models[kind.rawValue] = $0; app.saveConfig() }))
                            .textFieldStyle(.roundedBorder)
                        let suggestions = kind == .ollama ? ollamaModels : kind.modelSuggestions
                        if !suggestions.isEmpty {
                            MenuChip(title: tr("Выбрать", "Choose")) {
                                ForEach(suggestions, id: \.self) { m in
                                    Button(m) { app.config.ai.models[kind.rawValue] = m; app.saveConfig() }
                                }
                            }
                        }
                    }
                }
            }
            if kind == .claudeCode || kind == .anthropicAPI {
                row(tr("Глубина анализа", "Analysis depth")) {
                    SegmentedTabs(items: [("low", tr("Быстро", "Fast")), ("medium", tr("Обычно", "Normal")), ("high", tr("Тщательно", "Thorough"))],
                                  selection: Binding(get: { app.config.ai.effort }, set: { app.config.ai.effort = $0; app.saveConfig() }))
                }
            }
            if kind == .claudeCode {
                hint(tr("Используется аккаунт, в который выполнен вход в Claude Code (`claude` в терминале). Запросы расходуют лимиты подписки; Orbit повторяет анализ проекта не чаще, чем раз в \(Int(app.config.ai.minHoursBetweenRuns)) ч, и только если что-то изменилось.", "Uses the account you’re signed in to in Claude Code (`claude` in the terminal). Requests use your subscription limits; Orbit re-analyzes a project at most every \(Int(app.config.ai.minHoursBetweenRuns)) h, and only if something changed."))
            }
            if kind == .codexCLI {
                hint(tr("Используется аккаунт Codex CLI (`codex login`). Модель по умолчанию — из ~/.codex/config.toml.", "Uses your Codex CLI account (`codex login`). The default model comes from ~/.codex/config.toml."))
            }
            if kind == .ollama {
                row(tr("Адрес", "Address")) {
                    TextField("http://localhost:11434", text: Binding(get: { app.config.ai.ollamaURL }, set: { app.config.ai.ollamaURL = $0; app.saveConfig() }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if kind == .openAICompatible {
                row("Base URL") {
                    TextField("https://api.openai.com/v1", text: Binding(get: { app.config.ai.openAIBaseURL }, set: { app.config.ai.openAIBaseURL = $0; app.saveConfig() }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if kind.needsKey {
                row(tr("API-ключ", "API key")) {
                    HStack(spacing: 8) {
                        SecureField(Keychain.get(account(kind)) == nil ? tr("вставьте ключ", "paste the key") : tr("сохранён — введите новый, чтобы заменить", "saved — enter a new one to replace it"), text: $key)
                            .textFieldStyle(.roundedBorder)
                        OrbitButton(tr("Сохранить", "Save"), compact: true) {
                            Keychain.set(key.trimmed, for: account(kind))
                            key = ""
                            app.toast = tr("Ключ сохранён в связке ключей", "Key saved to the Keychain")
                        }
                        .disabled(key.trimmed.isEmpty)
                    }
                }
            }

            if kind.usesModel {
                Rectangle().fill(Theme.border).frame(height: 1)
                Toggle(tr("Анализировать автоматически после обновления данных", "Analyze automatically after data refresh"), isOn: Binding(get: { app.config.ai.autoAnalyze }, set: { app.config.ai.autoAnalyze = $0; app.saveConfig() }))
                Stepper(tr("Не чаще, чем раз в \(Int(app.config.ai.minHoursBetweenRuns)) ч на проект", "At most every \(Int(app.config.ai.minHoursBetweenRuns)) h per project"),
                        value: Binding(get: { app.config.ai.minHoursBetweenRuns }, set: { app.config.ai.minHoursBetweenRuns = $0; app.saveConfig() }),
                        in: 1...48, step: 1)
                Toggle(tr("Отправлять дифф при генерации сообщений коммитов", "Send the diff when generating commit messages"), isOn: Binding(get: { app.config.ai.sendDiffs }, set: { app.config.ai.sendDiffs = $0; app.saveConfig() }))

                HStack(spacing: 10) {
                    OrbitButton(testing ? tr("Проверяю…", "Checking…") : tr("Проверить подключение", "Test connection"), icon: "bolt") {
                        testing = true
                        Task {
                            testResult = await app.testAI()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    OrbitButton(tr("Проанализировать сейчас", "Analyze now"), icon: "sparkles", kind: .primary) { app.analyzeNow() }
                    Spacer()
                    if !app.aiCache.projects.isEmpty || !app.aiCache.sessions.isEmpty {
                        Button(tr("Очистить кэш", "Clear cache")) {
                            app.aiCache = AICache()
                            Store.save(app.aiCache, to: "ai-cache.json", pretty: false)
                        }
                        .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(12.5)).foregroundStyle(Theme.text3)
                    }
                }
                if let testResult {
                    status(testResult.ok, testResult.message)
                }
                if let error = app.aiError {
                    status(false, error)
                }
                if !app.aiBusy.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("В работе: \(app.aiBusy.count)", "In progress: \(app.aiBusy.count)")).uiFont(12.5, color: Theme.text2)
                    }
                }
            }
        }
        .font(OrbitFont.ui(13))
        .toggleStyle(.switch)
        .padding(18)
        .cardStyle(radius: 10)
        .task(id: kind) {
            testResult = nil
            if kind == .ollama { ollamaModels = await OllamaProvider.installedModels(baseURL: app.config.ai.ollamaURL) ?? [] }
        }
    }

    private func account(_ kind: AIProviderKind) -> Keychain.Account { kind == .anthropicAPI ? .anthropic : .openAI }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).uiFont(13, color: Theme.text2).frame(width: 120, alignment: .leading)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(.init(text)).uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(ok ? Theme.green : Theme.yellow)
            Text(text).uiFont(12.5, color: ok ? Theme.text2 : Theme.yellow).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Picker(tr("Язык", "Language"), selection: Binding(get: { app.config.language }, set: { app.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker(tr("Терминал", "Terminal"), selection: Binding(get: { app.config.terminalApp }, set: { app.config.terminalApp = $0; app.saveConfig() })) {
                ForEach(["Terminal", "iTerm", "Ghostty", "Warp"], id: \.self) { Text($0).tag($0) }
            }
            Toggle(tr("Уведомления macOS", "macOS notifications"), isOn: Binding(get: { app.config.notifyMacOS }, set: { app.config.notifyMacOS = $0; app.saveConfig() }))
            Toggle(tr("Утренняя сводка в 9:00", "Morning brief at 9:00"), isOn: Binding(get: { app.config.rhythm.morningBrief }, set: { app.config.rhythm.morningBrief = $0; app.saveConfig() }))
            Toggle(tr("Автоплан по воскресеньям в 20:00", "Auto-plan on Sundays at 20:00"), isOn: Binding(get: { app.config.rhythm.autoPlanSunday }, set: { app.config.rhythm.autoPlanSunday = $0; app.saveConfig() }))
            LabeledContent(tr("Данные", "Data")) {
                Button(Store.root.path.abbreviatingHome) { Shell.reveal(Store.root.path) }
            }
            Section(tr("Обновления", "Updates")) {
                LabeledContent(tr("Версия", "Version")) {
                    HStack(spacing: 10) {
                        Text(Updater.currentVersion)
                        if let release = app.availableUpdate {
                            Button(tr("Обновить до \(release.version)", "Update to \(release.version)")) { app.sheet = .update }
                        }
                    }
                }
                Toggle(tr("Проверять обновления автоматически", "Check for updates automatically"), isOn: Binding(get: { app.config.autoCheckUpdates }, set: { app.config.autoCheckUpdates = $0; app.saveConfig() }))
                Toggle(tr("Устанавливать без вопроса", "Install without asking"), isOn: Binding(get: { app.config.autoInstallUpdates }, set: { app.config.autoInstallUpdates = $0; app.saveConfig() }))
                    .disabled(!app.config.autoCheckUpdates)
                LabeledContent(tr("Последняя проверка", "Last checked")) {
                    HStack(spacing: 10) {
                        Text(app.updatePhase == .checking ? tr("проверяю…", "checking…") : app.lastUpdateCheck.map { DateFormat.ago($0, now: app.now) } ?? tr("ещё не было", "never"))
                        Button(tr("Проверить сейчас", "Check now")) { Task { await app.checkForUpdates(manual: true) } }
                            .disabled(app.updatePhase == .checking)
                    }
                }
                if let skipped = app.config.skippedVersion {
                    LabeledContent(tr("Пропущена версия \(skipped)", "Skipped version \(skipped)")) {
                        Button(tr("Не пропускать", "Don’t skip")) { app.config.skippedVersion = nil; app.saveConfig() }
                    }
                }
                if let blocker = Updater.installBlocker, Updater.isEnabled {
                    Text(blocker).foregroundStyle(Theme.yellow)
                }
            }
            Button(tr("Пройти онбординг заново", "Run onboarding again")) { app.resetOnboarding() }
        }
        .formStyle(.grouped)
    }
}
