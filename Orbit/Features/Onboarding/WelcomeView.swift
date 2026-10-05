import SwiftUI

/// First screen of onboarding: the logo assembles, then the name, the tagline and the
/// signature appear one after another. "Начать" flies the logo into the onboarding top bar.
struct WelcomeView: View {
    var onContinue: () -> Void

    @Environment(AppState.self) private var app
    @Environment(\.logoNamespace) private var namespace
    @State private var title = false
    @State private var tagline = false
    @State private var signature = false
    @State private var actions = false

    var body: some View {
        let _ = app.languageRevision
        VStack(spacing: 0) {
            Spacer()
            logo
                .frame(width: 96, height: 96)
                .padding(.bottom, 28)

            Text("Orbit")
                .font(OrbitFont.ui(34, .semibold))
                .tracking(-0.6)
                .reveal(title)
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                Text(tr("Вайбкодинг без хаоса.", "Vibe coding without the chaos."))
                    .uiFont(17, .medium)
                Text(tr("Проекты, агенты и неделя — на одной орбите.", "Your projects, agents and week — in one orbit."))
                    .uiFont(15, color: Theme.text2)
            }
            .multilineTextAlignment(.center)
            .reveal(tagline)
            .padding(.bottom, 22)

            HStack(spacing: 10) {
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 18, height: 1)
                Text(tr("от вайбкодера к вайбкодерам", "by a vibe coder, for vibe coders"))
                    .monoFont(12.5, color: Theme.accent.opacity(0.75))
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 18, height: 1)
            }
            .reveal(signature)
            .padding(.bottom, 44)

            VStack(spacing: 10) {
                OrbitButton(tr("Начать", "Get started"), icon: "arrow.right", kind: .primary, action: onContinue)
                    .keyboardShortcut(.defaultAction)
                Text(tr("3 шага · около минуты", "3 steps · about a minute")).uiFont(12, color: Theme.text3)
            }
            .reveal(actions)
            Spacer()
            Spacer()
            languageSwitch
                .reveal(actions)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// "English · Русский": picking the system language keeps following the system.
    private var languageSwitch: some View {
        HStack(spacing: 4) {
            ForEach([Lang.en, Lang.ru], id: \.self) { lang in
                let selected = L10n.current == lang
                Button {
                    withMotion(Motion.content) { app.setLanguage(lang == Lang.system ? .system : lang == .ru ? .ru : .en) }
                } label: {
                    Text(lang == .ru ? "Русский" : "English")
                        .uiFont(12, selected ? .medium : .regular, color: selected ? Theme.text : Theme.text3)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(selected ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .hoverHighlight(.row, radius: 6)
                }
                .buttonStyle(PlainButtonStyle2())
            }
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var logo: some View {
        if let namespace {
            AnimatedLogo { Task { await revealText() } }
                .matchedGeometryEffect(id: "orbit-logo", in: namespace)
        } else {
            AnimatedLogo { Task { await revealText() } }
        }
    }

    /// Lines follow the logo at a calm pace; with "Reduce motion" everything fades in at once.
    private func revealText() async {
        let steps: [(ms: Int, set: () -> Void)] = [
            (500, { title = true }),
            (500, { tagline = true }),
            (500, { signature = true }),
            (400, { actions = true }),
        ]
        for step in steps {
            if !Motion.reduced { try? await Task.sleep(for: .milliseconds(step.ms)) }
            withMotion(Motion.content) { step.set() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--auto-continue") {
            try? await Task.sleep(for: .milliseconds(500))
            onContinue()
        }
        #endif
    }
}

private extension View {
    /// Fades in with a small rise once `shown` flips.
    func reveal(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0).offset(y: shown || Motion.reduced ? 0 : 8)
    }
}
