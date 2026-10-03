import SwiftUI

/// Short launch animation (~1.4 s): the tile appears, the orbit draws itself, the moon makes one
/// lap and settles, then the logo flies into its place in the window chrome.
struct LaunchSplash: View {
    var namespace: Namespace.ID
    var onFinish: () -> Void

    @State private var title: CGFloat = 0

    /// Plays once per launch, only once onboarding is done; skipped with "Reduce motion" and in snapshot runs.
    @MainActor static var shouldPlay: Bool {
        guard !played else { return false }
        played = true
        let args = ProcessInfo.processInfo.arguments
        // On first launch the onboarding welcome plays the logo animation itself.
        let onboarded = Store.load(OrbitConfig.self, from: "config.json")?.onboarded ?? false
        #if DEBUG
        if args.contains("--splash-frames") { return onboarded }
        if Snapshotter.directory != nil { return false }
        #endif
        return onboarded && !Motion.reduced && !args.contains("--no-splash")
    }

    @MainActor private static var played = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                AnimatedLogo { Task { await finish() } }
                    .matchedGeometryEffect(id: "orbit-logo", in: namespace)
                    .frame(width: 88, height: 88)
                Text("Orbit")
                    .uiFont(22, .semibold)
                    .opacity(Double(title))
                    .offset(y: (1 - title) * 6)
            }
        }
    }

    /// After the logo lands: show the title, hold, then hand over.
    private func finish() async {
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.3)) { title = 1 }
        try? await Task.sleep(for: .milliseconds(700))
        onFinish()
    }
}
