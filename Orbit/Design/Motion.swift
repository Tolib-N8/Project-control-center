import AppKit
import SwiftUI

/// Orbit's motion language: short, well-damped springs, no bounce.
/// Every animation goes through here so "Reduce motion" turns movement into plain fades.
enum Motion {
    /// Selection, hover, toggles, tabs.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// Screen changes and onboarding steps.
    static let page = Animation.spring(response: 0.38, dampingFraction: 0.92)
    /// Text and content swaps.
    static let content = Animation.easeOut(duration: 0.25)
    /// Bars and charts filling up.
    static let grow = Animation.spring(response: 0.6, dampingFraction: 0.9)

    /// `--reduce-motion` forces the reduced path for testing.
    static let forceReduce = ProcessInfo.processInfo.arguments.contains("--reduce-motion")

    static var reduced: Bool {
        forceReduce || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The animation to use, or a short fade when motion is reduced.
    static func pick(_ animation: Animation) -> Animation {
        reduced ? .easeOut(duration: 0.15) : animation
    }

    /// Transitions collapse to opacity when motion is reduced.
    static func transition(_ t: AnyTransition) -> AnyTransition {
        reduced ? .opacity : t
    }

    /// Fade with a small rise, the default way content enters.
    static let rise: AnyTransition = .opacity.combined(with: .offset(y: 8))
    /// Blocks and chips appearing or disappearing.
    static let pop: AnyTransition = .opacity.combined(with: .scale(scale: 0.96))
}

func withMotion<Result>(_ animation: Animation = Motion.snappy, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.pick(animation), body)
}

// MARK: - Appear

/// Fades content in with a slight rise the first time it appears; `index` staggers siblings.
struct AppearStagger: ViewModifier {
    var index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                // Only the first dozen items cascade; the rest come in together.
                let delay = index < 12 ? Double(index) * 0.03 : 0
                withAnimation(Motion.pick(Motion.content).delay(Motion.reduced ? 0 : delay)) { shown = true }
            }
    }
}

// MARK: - Hover

enum HoverStyle { case row, card }

struct HoverHighlight: ViewModifier {
    var style: HoverStyle
    var radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if style == .row {
                    RoundedRectangle(cornerRadius: radius).fill(Theme.surface2.opacity(hovering ? 0.55 : 0))
                }
            }
            .overlay {
                if style == .card {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.text3.opacity(hovering ? 0.9 : 0), lineWidth: 1)
                }
            }
            .onHover { h in withMotion { hovering = h } }
    }
}

extension View {
    func appearStagger(_ index: Int = 0) -> some View { modifier(AppearStagger(index: index)) }

    func hoverHighlight(_ style: HoverStyle = .row, radius: CGFloat = 0) -> some View {
        modifier(HoverHighlight(style: style, radius: radius))
    }

    /// Digits roll when the value changes (health scores, counters).
    func numericTransition<V: Equatable>(_ value: V) -> some View {
        contentTransition(.numericText()).animation(Motion.pick(Motion.content), value: value)
    }
}
