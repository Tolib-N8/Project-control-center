import SwiftUI

/// Each clickable icon has its own short move, played on hover and on press.
/// Buttons publish a trigger through the environment (`iconMotion`); `Icon` plays its effect when it changes.
enum IconEffect: Equatable {
    case bounceUp, bounceDown, bounceLayers
    case wiggleForward, wiggleLeft, wiggleRight, wiggleUp, wiggleDown, ring, wiggleLayers
    case rotate, rotateBack, breathe, sparkle, pulse
}

enum IconMotion {
    static func effect(for symbol: String) -> IconEffect {
        switch symbol {
        case _ where symbol.hasPrefix("calendar"): .bounceDown          // a page flips over
        case "square.grid.2x2": .bounceLayers                         // the squares spring one by one
        case "cpu": .breathe
        case "arrow.triangle.branch", "arrow.triangle.pull", "pencil", "point.topleft.down.to.point.bottomright.curvepath", "hand.draw", "paperplane": .wiggleForward
        case "bell", "bell.slash", "xmark", "magnifyingglass", "doc.text.magnifyingglass": .ring
        case "gearshape", "plus", "arrow.clockwise", "arrow.triangle.2.circlepath": .rotate
        case "arrow.counterclockwise": .rotateBack
        case "sparkles": .sparkle
        case _ where symbol.hasPrefix("folder"): .bounceUp
        case "terminal", "checkmark", "checkmark.circle", "checkmark.seal", "key": .bounceUp
        case "play", "arrow.right", "chevron.right": .wiggleRight
        case "arrow.left", "chevron.left": .wiggleLeft
        case "arrow.up", "arrow.up.right.square": .wiggleUp
        case _ where symbol.hasPrefix("arrow.down"): .wiggleDown
        case "chevron.left.forwardslash.chevron.right": .wiggleLayers
        case "doc.on.doc": .bounceLayers
        case "archivebox", "scroll": .bounceDown
        case "arrow.up.arrow.down", "network": .wiggleLayers
        case "eye", "bolt", "viewfinder": .pulse
        case "desktopcomputer", "function": .breathe
        default: .bounceUp
        }
    }
}

private struct IconTriggerKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Bumped by the enclosing button on hover and press.
    var iconTrigger: Int {
        get { self[IconTriggerKey.self] }
        set { self[IconTriggerKey.self] = newValue }
    }
}

/// Fires icon effects inside a control when the pointer enters it and when it is pressed.
struct IconMotionHost: ViewModifier {
    var pressed = false
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .environment(\.iconTrigger, trigger)
            .onHover { inside in if inside { fire() } }
            .onChange(of: pressed) { _, isPressed in if isPressed { fire() } }
    }

    private func fire() {
        guard !Motion.reduced else { return }
        trigger &+= 1
    }
}

extension View {
    /// Makes `Icon`s inside this control play their effect on hover and press.
    func iconMotion(pressed: Bool = false) -> some View {
        modifier(IconMotionHost(pressed: pressed))
    }

    @ViewBuilder
    func iconEffect(_ effect: IconEffect, trigger: Int) -> some View {
        switch effect {
        case .bounceUp: symbolEffect(.bounce.up, options: .nonRepeating, value: trigger)
        case .bounceDown: symbolEffect(.bounce.down, options: .nonRepeating, value: trigger)
        case .bounceLayers: symbolEffect(.bounce.byLayer, options: .nonRepeating, value: trigger)
        case .wiggleForward: symbolEffect(.wiggle.forward, options: .nonRepeating, value: trigger)
        case .wiggleLeft: symbolEffect(.wiggle.left, options: .nonRepeating, value: trigger)
        case .wiggleRight: symbolEffect(.wiggle.right, options: .nonRepeating, value: trigger)
        case .wiggleUp: symbolEffect(.wiggle.up, options: .nonRepeating, value: trigger)
        case .wiggleDown: symbolEffect(.wiggle.down, options: .nonRepeating, value: trigger)
        case .ring: symbolEffect(.wiggle.clockwise, options: .nonRepeating, value: trigger)
        case .wiggleLayers: symbolEffect(.wiggle.byLayer, options: .nonRepeating, value: trigger)
        case .rotate: symbolEffect(.rotate.clockwise, options: .nonRepeating, value: trigger)
        case .rotateBack: symbolEffect(.rotate.counterClockwise, options: .nonRepeating, value: trigger)
        case .breathe: symbolEffect(.breathe, options: .nonRepeating, value: trigger)
        case .sparkle: symbolEffect(.variableColor.iterative, options: .nonRepeating, value: trigger)
        case .pulse: symbolEffect(.pulse, options: .nonRepeating, value: trigger)
        }
    }
}

/// An SF Symbol in a clickable control; animates with the control's hover and press.
struct Icon: View {
    var name: String
    var size: CGFloat
    var weight: Font.Weight
    @Environment(\.iconTrigger) private var trigger

    init(_ name: String, size: CGFloat = 12, weight: Font.Weight = .medium) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .iconEffect(IconMotion.effect(for: name), trigger: trigger)
    }
}
