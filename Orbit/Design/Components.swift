import SwiftUI

// MARK: - Containers

struct Card<Content: View>: View {
    var padding: CGFloat = 24
    var radius: CGFloat = 12
    var fill: Color = Theme.surface
    var stroke: Color = Theme.border
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: 1))
    }
}

struct InnerPanel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Buttons

enum OrbitButtonKind { case primary, secondary, light, ghost }

struct OrbitButtonStyle: ButtonStyle {
    var kind: OrbitButtonKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrbitFont.ui(compact ? 12.5 : 13, kind == .primary || kind == .light ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.vertical, compact ? 6 : 9)
            .padding(.horizontal, compact ? 10 : 14)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: compact ? 7 : 8))
            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 8).strokeBorder(kind == .secondary ? Theme.border : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .light: Theme.bg
        case .secondary, .ghost: Theme.text
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: Theme.accent
        case .light: Theme.text
        case .secondary: pressed ? Theme.surface2 : .clear
        case .ghost: pressed ? Theme.surface2 : .clear
        }
    }
}

struct OrbitButton: View {
    var title: String
    var icon: String?
    var kind: OrbitButtonKind = .secondary
    var compact = false
    var action: () -> Void

    init(_ title: String, icon: String? = nil, kind: OrbitButtonKind = .secondary, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 11 : 12.5, weight: .medium)) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
        }
        .buttonStyle(OrbitButtonStyle(kind: kind, compact: compact))
    }
}

/// Plain clickable area without default button chrome.
struct PlainButtonStyle2: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Tags

struct Tag: View {
    var text: String
    var color: Color
    var mono = false
    var size: CGFloat = 11.5

    var body: some View {
        Text(text)
            .font(mono ? OrbitFont.mono(size, .medium) : OrbitFont.ui(size, .semibold))
            .foregroundStyle(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

extension AgentKind {
    var color: Color {
        switch self {
        case .claude: Theme.violet
        case .codex: Theme.cyan
        case .cursor: Theme.orange
        case .aider: Theme.pink
        }
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .active: Theme.cyan
        case .done: Theme.green
        case .unfinished: Theme.yellow
        case .rolledBack: Theme.red
        }
    }
}

struct AgentTag: View {
    var agent: AgentKind
    var body: some View { Tag(text: agent.title, color: agent.color) }
}

struct StatusTag: View {
    var status: SessionStatus
    var body: some View { Tag(text: status.title, color: status.color, size: 12) }
}

struct ProjectSquare: View {
    var colorIndex: Int
    var size: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Theme.projectColor(colorIndex))
            .frame(width: size, height: size)
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 6
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct ProjectLabel: View {
    @Environment(AppState.self) private var app
    var projectId: String
    var size: CGFloat = 12.5
    var color: Color = Theme.text

    var body: some View {
        HStack(spacing: 8) {
            ProjectSquare(colorIndex: app.colorIndex(projectId), size: size * 0.62)
            Text(app.projectName(projectId)).monoFont(size, color: color).lineLimit(1)
        }
    }
}

// MARK: - Indicators

struct HealthBar: View {
    var score: Int
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(Theme.healthColor(score))
                    .frame(width: geo.size.width * CGFloat(max(0, min(100, score))) / 100)
            }
        }
        .frame(height: height)
    }
}

struct ProgressLine: View {
    var fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Stacked horizontal bar (done / stuck / rollback).
struct SegmentBar: View {
    var segments: [(Double, Color)]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.0 }, 0.0001)
            let gaps = CGFloat(max(0, segments.filter { $0.0 > 0 }.count - 1)) * 3
            HStack(spacing: 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.0 > 0 {
                        Capsule().fill(seg.1).frame(width: (geo.size.width - gaps) * seg.0 / total)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

struct OrbitToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.border)
                Circle().fill(isOn ? Theme.bg : Theme.text3).padding(2)
            }
            .frame(width: 30, height: 18)
        }
        .buttonStyle(PlainButtonStyle2())
    }
}

struct SegmentedTabs<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.0 == selection
                Button { selection = item.0 } label: {
                    Text(item.1)
                        .font(OrbitFont.ui(12.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.text2)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(selected ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(PlainButtonStyle2())
            }
        }
        .padding(3)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

struct IconBox: View {
    var symbol: String
    var color: Color = Theme.text2
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25))
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var color: Color = Theme.text
    var mono = true

    var body: some View {
        HStack {
            Text(key).uiFont(12.5, color: Theme.text2)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? OrbitFont.mono(12) : OrbitFont.ui(12.5))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

struct Eyebrow: View {
    var text: String
    var color: Color = Theme.text3
    var body: some View {
        Text(text.uppercased())
            .font(OrbitFont.ui(11, .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

struct PageHeader<Actions: View>: View {
    var eyebrow: String
    var title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow).uiFont(12.5, color: Theme.text3)
                Text(title).font(OrbitFont.ui(26, .semibold)).tracking(-0.5).foregroundStyle(Theme.text)
            }
            Spacer()
            HStack(spacing: 10) { actions }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .overlay {
                Canvas { ctx, s in
                    let c = CGPoint(x: s.width / 2, y: s.height / 2)
                    let r = s.width * 0.3
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(Theme.bg), lineWidth: s.width * 0.09)
                    let d = s.width * 0.22
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(Theme.bg))
                    let m = s.width * 0.2
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x + r * 0.7 - m / 2, y: c.y - r * 0.7 - m / 2, width: m, height: m)), with: .color(Theme.accent))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x + r * 0.7 - m / 2, y: c.y - r * 0.7 - m / 2, width: m, height: m)), with: .color(Theme.bg), lineWidth: s.width * 0.08)
                }
                .padding(size * 0.12)
            }
    }
}

struct EmptyHint: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        VStack(spacing: 10) {
            IconBox(symbol: symbol, color: Theme.text2, size: 40)
            Text(title).uiFont(14, .semibold)
            Text(text).uiFont(12.5, color: Theme.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

extension View {
    func cardStyle(radius: CGFloat = 12, fill: Color = Theme.surface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border, lineWidth: 1))
    }

    func hairline(_ edge: Edge = .bottom) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// A dropdown whose chrome is drawn outside the Menu: macOS strips styling from Menu labels.
struct MenuChip<Items: View>: View {
    var icon: String?
    var title: String
    var kind: OrbitButtonKind = .secondary
    var chevron = true
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
                if chevron { Image(systemName: "chevron.down") }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(OrbitFont.ui(13, kind == .primary ? .semibold : .medium))
        .tint(kind == .primary ? Theme.bg : Theme.text)
        .foregroundStyle(kind == .primary ? Theme.bg : Theme.text)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(kind == .primary ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .secondary ? Theme.border : .clear))
        .colorScheme(kind == .primary ? .light : .dark)
    }
}

/// Wraps children onto new lines when they do not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
