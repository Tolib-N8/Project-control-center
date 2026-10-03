import SwiftUI

/// The Orbit mark, drawn relative to its frame so it scales cleanly (the launch animation
/// flies it from the centre of the window into the sidebar). Every part can be animated.
struct LogoArt: View {
    /// Tile scale and opacity, 0…1.
    var tile: CGFloat = 1
    /// How much of the orbit ring is drawn, 0…1.
    var ring: CGFloat = 1
    /// Planet scale, 0…1.
    var planet: CGFloat = 1
    /// Moon position on the ring, clockwise from the top; it rests at the top right.
    var moon: Angle = .degrees(45)
    var moonVisible = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let inner = s * 0.76 // 12% padding on each side
            let r = inner * 0.3
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.27)
                    .fill(Theme.accent)
                    .scaleEffect(0.8 + 0.2 * tile)
                    .opacity(Double(tile))
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Theme.bg, style: StrokeStyle(lineWidth: inner * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2, height: r * 2)
                Circle()
                    .fill(Theme.bg)
                    .frame(width: inner * 0.22, height: inner * 0.22)
                    .scaleEffect(planet)
                Circle()
                    .fill(Theme.accent)
                    .overlay(Circle().stroke(Theme.bg, lineWidth: inner * 0.08))
                    .frame(width: inner * 0.2, height: inner * 0.2)
                    .offset(y: -r)
                    .rotationEffect(moon)
                    .opacity(moonVisible ? 1 : 0)
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 26
    var body: some View { LogoArt().frame(width: size, height: size) }
}

// MARK: - Launch hand-off

private struct LogoNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private struct SplashActiveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Shared with the launch splash so its logo can fly into place.
    var logoNamespace: Namespace.ID? {
        get { self[LogoNamespaceKey.self] }
        set { self[LogoNamespaceKey.self] = newValue }
    }

    var splashActive: Bool {
        get { self[SplashActiveKey.self] }
        set { self[SplashActiveKey.self] = newValue }
    }
}

/// The logo in the window chrome (sidebar, onboarding). While the splash plays it leaves an
/// empty slot; when the splash ends the splash logo lands here.
struct BrandLogo: View {
    var size: CGFloat
    @Environment(\.logoNamespace) private var namespace
    @Environment(\.splashActive) private var splashActive

    var body: some View {
        if splashActive {
            Color.clear.frame(width: size, height: size)
        } else if let namespace {
            LogoArt()
                .matchedGeometryEffect(id: "orbit-logo", in: namespace)
                .frame(width: size, height: size)
        } else {
            LogoMark(size: size)
        }
    }
}

// MARK: - Assembly animation

/// The logo assembling itself: tile, orbit ring, the moon's lap, the planet.
/// Shared by the launch splash and the onboarding welcome; `onAssembled` fires once the
/// planet lands (~0.35 s) so callers can chain their own content.
struct AnimatedLogo: View {
    var onAssembled: () -> Void = {}

    @State private var tile: CGFloat = 0
    @State private var ring: CGFloat = 0
    @State private var planet: CGFloat = 0
    @State private var moon: Angle = .degrees(45 - 360)
    @State private var moonVisible = false

    var body: some View {
        LogoArt(tile: tile, ring: ring, planet: planet, moon: moon, moonVisible: moonVisible)
            .task { await play() }
    }

    private func play() async {
        if Motion.reduced {
            withAnimation(.easeOut(duration: 0.2)) {
                tile = 1; ring = 1; planet = 1; moon = .degrees(45); moonVisible = true
            }
            onAssembled()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { tile = 1 }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut(duration: 0.5)) { ring = 1 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.15)) { moonVisible = true }
        withAnimation(.easeOut(duration: 0.75)) { moon = .degrees(45) }
        try? await Task.sleep(for: .milliseconds(130))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { planet = 1 }
        onAssembled()
    }
}
