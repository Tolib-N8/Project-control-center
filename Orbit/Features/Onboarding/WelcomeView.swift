import SwiftUI

/// First screen of onboarding: the logo assembles, then the name, the tagline and the
/// signature appear one after another. "Начать" flies the logo into the onboarding top bar.
struct WelcomeView: View {
    var onContinue: () -> Void

    @Environment(\.logoNamespace) private var namespace
    @State private var title = false
    @State private var tagline = false
    @State private var signature = false
    @State private var actions = false

    var body: some View {
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
                Text("Вайбкодинг без хаоса.")
                    .uiFont(17, .medium)
                Text("Проекты, агенты и неделя — на одной орбите.")
                    .uiFont(15, color: Theme.text2)
            }
            .multilineTextAlignment(.center)
            .reveal(tagline)
            .padding(.bottom, 22)

            HStack(spacing: 10) {
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 18, height: 1)
                Text("от вайбкодера к вайбкодерам")
                    .monoFont(12.5, color: Theme.accent.opacity(0.75))
                Rectangle().fill(Theme.accent.opacity(0.35)).frame(width: 18, height: 1)
            }
            .reveal(signature)
            .padding(.bottom, 44)

            VStack(spacing: 10) {
                OrbitButton("Начать", icon: "arrow.right", kind: .primary, action: onContinue)
                    .keyboardShortcut(.defaultAction)
                Text("3 шага · около минуты").uiFont(12, color: Theme.text3)
            }
            .reveal(actions)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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
