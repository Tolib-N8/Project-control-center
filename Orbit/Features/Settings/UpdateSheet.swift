import SwiftUI

/// "Что нового" for an available version, with a one-click install and relaunch.
struct UpdateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release = app.availableUpdate {
                header(release)
                ScrollView {
                    Text(notes(release))
                        .font(OrbitFont.ui(13))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .frame(maxHeight: 360)
                .hairline(.top)
                footer(release)
            } else {
                EmptyHint(symbol: "checkmark.seal", title: tr("Установлена последняя версия", "You have the latest version"), text: "Orbit \(Updater.currentVersion)")
                    .padding(24)
                HStack { Spacer(); OrbitButton(tr("Закрыть", "Close")) { dismiss() } }.padding(20)
            }
        }
        .frame(width: 560)
        .background(Theme.surface)
    }

    private func header(_ release: ReleaseInfo) -> some View {
        HStack(spacing: 16) {
            LogoMark(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Orbit \(release.version)").uiFont(20, .semibold)
                Text(tr("У вас \(Updater.currentVersion) · \(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))", "You have \(Updater.currentVersion) · \(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))"))
                    .uiFont(12.5, color: Theme.text2)
            }
            Spacer()
            if let page = release.pageURL {
                Link(destination: page) {
                    Icon("arrow.up.right.square", size: 13, weight: .regular).foregroundStyle(Theme.text3)
                }
                .iconMotion()
                .help(tr("Открыть релиз на GitHub", "Open the release on GitHub"))
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func footer(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch app.updatePhase {
            case .downloading(let p):
                HStack(spacing: 12) {
                    ProgressLine(fraction: p, height: 6)
                    Text("\(Int(p * 100))%").monoFont(12, color: Theme.text2).numericTransition(Int(p * 100))
                }
                Text(tr("Скачиваю и проверяю…", "Downloading and verifying…")).uiFont(12.5, color: Theme.text2)
            case .installing:
                Text(tr("Устанавливаю — Orbit перезапустится через секунду…", "Installing — Orbit will relaunch in a second…")).uiFont(12.5, color: Theme.text2)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").uiFont(12.5, color: Theme.yellow)
            default:
                EmptyView()
            }
            if let blocker = Updater.installBlocker {
                Label(blocker, systemImage: "folder.badge.questionmark").uiFont(12.5, color: Theme.yellow)
            }
            HStack(spacing: 10) {
                Button(tr("Пропустить эту версию", "Skip this version")) { app.skipUpdate() }
                    .buttonStyle(PlainButtonStyle2()).font(OrbitFont.ui(12.5)).foregroundStyle(Theme.text3)
                Spacer()
                OrbitButton(tr("Позже", "Later")) { dismiss() }
                OrbitButton(busy ? tr("Обновляю…", "Updating…") : tr("Установить и перезапустить", "Install and relaunch"), icon: "arrow.down.circle", kind: .primary) {
                    app.installUpdate()
                }
                .disabled(busy || Updater.installBlocker != nil)
                .opacity(busy || Updater.installBlocker != nil ? 0.5 : 1)
            }
        }
        .padding(20)
        .hairline(.top)
        .animation(Motion.pick(Motion.content), value: app.updatePhase)
    }

    private var busy: Bool {
        switch app.updatePhase {
        case .downloading, .installing: true
        default: false
        }
    }

    private func notes(_ release: ReleaseInfo) -> AttributedString {
        // Drop the install instructions: the user is installing from inside the app.
        let text = ["\n## Установка", "\n## Install"].reduce(release.notes) { notes, marker in
            notes.components(separatedBy: marker).first ?? notes
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let cleaned = text.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }
}

/// Slim banner in the sidebar when a newer version is out.
struct UpdateBanner: View {
    @Environment(AppState.self) private var app
    var release: ReleaseInfo

    var body: some View {
        Button { app.sheet = .update } label: {
            HStack(spacing: 10) {
                Icon("arrow.down.circle.fill", size: 14, weight: .regular).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Доступна версия \(release.version)", "Version \(release.version) is available")).uiFont(12, .medium)
                    Text(progressText).uiFont(11.5, color: Theme.text3).contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.35)))
        }
        .buttonStyle(PlainButtonStyle2())
        .animation(Motion.pick(Motion.content), value: app.updatePhase)
    }

    private var progressText: String {
        switch app.updatePhase {
        case .downloading(let p): tr("Загрузка · \(Int(p * 100))%", "Downloading · \(Int(p * 100))%")
        case .installing: tr("Перезапуск…", "Relaunching…")
        case .failed: tr("Ошибка — нажмите, чтобы повторить", "Error — click to retry")
        default: tr("Нажмите, чтобы обновить", "Click to update")
        }
    }
}
