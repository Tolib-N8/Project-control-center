import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Design tokens taken from design/exports/html.
enum Theme {
    static let bg = Color(hex: 0x0D0E10)
    static let surface = Color(hex: 0x15171A)
    static let surface2 = Color(hex: 0x1C1F23)
    static let border = Color(hex: 0x25292E)

    static let text = Color(hex: 0xECEDEF)
    static let text2 = Color(hex: 0x8D939C)
    static let text3 = Color(hex: 0x5C626B)

    static let accent = Color(hex: 0xC8F169)
    static let green = Color(hex: 0x5AD48A)
    static let yellow = Color(hex: 0xF2B84B)
    static let red = Color(hex: 0xF06A5C)

    static let violet = Color(hex: 0x9D8CFF)
    static let cyan = Color(hex: 0x5CC8E8)
    static let orange = Color(hex: 0xF59E5B)
    static let pink = Color(hex: 0xF07AB0)

    static let projectPalette: [Color] = [violet, cyan, orange, pink, accent, green, yellow]

    static func projectColor(_ index: Int) -> Color {
        projectPalette[((index % projectPalette.count) + projectPalette.count) % projectPalette.count]
    }

    static func healthColor(_ score: Int) -> Color {
        if score >= 75 { return green }
        if score >= 50 { return yellow }
        return red
    }

    static let sidebarWidth: CGFloat = 248
}

enum OrbitFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Inter", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("JetBrains Mono", size: size).weight(weight)
    }
}

extension View {
    func uiFont(_ size: CGFloat, _ weight: Font.Weight = .regular, color: Color = Theme.text) -> some View {
        font(OrbitFont.ui(size, weight)).foregroundStyle(color)
    }

    func monoFont(_ size: CGFloat, _ weight: Font.Weight = .regular, color: Color = Theme.text) -> some View {
        font(OrbitFont.mono(size, weight)).foregroundStyle(color)
    }
}
