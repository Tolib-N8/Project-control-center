import SwiftUI

/// Short launch animation (~1.4 s): the tile appears, the orbit draws itself, the moon makes one
/// lap and settles, then the logo flies into its place in the window chrome.
struct LaunchSplash: View {
    var namespace: Namespace.ID
    var onFinish: () -> Void

    @State private var tile: CGFloat = 0
    @State private var ring: CGFloat = 0
    @State private var planet: CGFloat = 0
    @State private var moon: Angle = .degrees(45 - 360)
    @State private var moonVisible = false
    @State private var title: CGFloat = 0

    /// Plays once per launch; skipped with "Reduce motion" and in snapshot runs.
    @MainActor static var shouldPlay: Bool {
        guard !played else { return false }
        played = true
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if args.contains("--splash-frames") { return true }
        if Snapshotter.directory != nil { return false }
        #endif
        return !Motion.reduced && !args.contains("--no-splash")
    }

    @MainActor private static var played = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                LogoArt(tile: tile, ring: ring, planet: planet, moon: moon, moonVisible: moonVisible)
                    .matchedGeometryEffect(id: "orbit-logo", in: namespace)
                    .frame(width: 88, height: 88)
                Text("Orbit")
                    .uiFont(22, .semibold)
                    .opacity(Double(title))
                    .offset(y: (1 - title) * 6)
            }
        }
        .task { await play() }
    }

    private func play() async {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { tile = 1 }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut(duration: 0.5)) { ring = 1 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.15)) { moonVisible = true }
        withAnimation(.easeOut(duration: 0.75)) { moon = .degrees(45) }
        try? await Task.sleep(for: .milliseconds(130))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { planet = 1 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.3)) { title = 1 }
        try? await Task.sleep(for: .milliseconds(700))
        onFinish()
    }
}
