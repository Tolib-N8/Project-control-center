import SwiftUI

/// "Время": how much you really worked, on what, when, and how much of it was you versus the agents.
struct TimeView: View {
    @Environment(AppState.self) private var app
    @State private var kind = TimePeriod.Kind.week
    /// 0 = the current period, −1 = the previous one…
    @State private var offset = 0

    #if DEBUG
    /// Set by the snapshot tool to open on a given period.
    nonisolated(unsafe) static var debugStart: (kind: TimePeriod.Kind, offset: Int)?
    #endif

    init() {
        #if DEBUG
        if let start = Self.debugStart {
            _kind = State(initialValue: start.kind)
            _offset = State(initialValue: start.offset)
        }
        #endif
    }

    var body: some View {
        let period = TimePeriod.containing(app.now, kind: kind).shifted(offset)
        let stats = TimeEngine.compute(period: period, projects: app.activeSnapshots, worklog: app.worklog.intervals, plans: app.plans, now: app.now)
        Page {
            PageHeader(eyebrow: period.title, title: tr("Время", "Time")) {
                if offset != 0 {
                    OrbitButton(tr("Сегодня", "Today"), icon: "arrow.right") { withMotion { offset = 0 } }
                        .transition(Motion.transition(Motion.pop))
                }
                HStack(spacing: 0) {
                    stepper("chevron.left") { offset -= 1 }
                    stepper("chevron.right") { offset += 1 }.disabled(offset >= 0).opacity(offset >= 0 ? 0.35 : 1)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                SegmentedTabs(items: [(TimePeriod.Kind.week, tr("Неделя", "Week")), (TimePeriod.Kind.month, tr("Месяц", "Month"))],
                              selection: Binding(get: { kind }, set: { kind = $0; offset = 0 }))
            }

            if stats.isEmpty {
                EmptyHint(symbol: "clock", title: tr("За этот период времени нет", "No time in this period"),
                          text: tr("Нажмите «Начать разработку» — таймер и сессии агентов появятся здесь.", "Press “Start development” — the timer and agent sessions will show up here."))
                    .padding(.vertical, 60)
                    .cardStyle()
            } else {
                TimeTiles(stats: stats, period: period, now: app.now).appearStagger(0)
                DayChart(stats: stats, period: period).appearStagger(1)
                HStack(alignment: .top, spacing: 28) {
                    ProjectTimeTable(stats: stats).appearStagger(2)
                    VStack(spacing: 28) {
                        HeatmapCard(stats: stats)
                        WhoWorkedCard(stats: stats)
                    }
                    .frame(width: 460)
                    .appearStagger(3)
                }
            }
        }
        .animation(Motion.pick(Motion.page), value: period)
    }

    private func stepper(_ icon: String, action: @escaping () -> Void) -> some View {
        Button { withMotion { action() } } label: {
            Icon(icon, size: 12).foregroundStyle(Theme.text2).frame(width: 34, height: 32)
        }
        .buttonStyle(PlainButtonStyle2())
    }
}

// MARK: - Tiles

private struct TimeTiles: View {
    var stats: TimeStats
    var period: TimePeriod
    var now: Date

    var body: some View {
        let delta = stats.total - stats.previousTotal
        let previous = period.kind == .week ? tr("к прошлой неделе", "vs last week") : tr("к прошлому месяцу", "vs last month")
        HStack(spacing: 0) {
            tile(tr("Всего", "Total"), hours(stats.total),
                 abs(delta) < 0.25 ? tr("как в прошлый раз", "same as before") : "\(delta > 0 ? "↑" : "↓") \(hours(abs(delta))) \(previous)",
                 captionColor: abs(delta) < 0.25 ? Theme.text3 : delta > 0 ? Theme.green : Theme.yellow)
            divider
            tile(tr("В среднем за рабочий день", "Average per worked day"), hours(stats.averagePerWorkedDay),
                 tr("дней с работой: \(stats.days.filter { $0.total >= TimeEngine.workedThreshold }.count)", "days worked: \(stats.days.filter { $0.total >= TimeEngine.workedThreshold }.count)"))
            divider
            if let best = stats.bestDay {
                tile(tr("Лучший день", "Best day"), hours(best.total), DateFormat.weekdayShort(best.date))
            } else {
                tile(tr("Лучший день", "Best day"), "—", "")
            }
            divider
            tile(tr("Серия", "Streak"), plural(stats.streak.current, ru: ("день", "дня", "дней"), en: ("day", "days")),
                 tr("рекорд — \(Plural.days(stats.streak.best)) подряд", "record: \(Plural.days(stats.streak.best)) in a row"),
                 color: stats.streak.current >= 3 ? Theme.accent : Theme.text)
            divider
            if stats.planned > 0 {
                // While the period is running, compare with what was planned up to today.
                let running = period.contains(now)
                let target = running ? stats.planned(through: Week.calendar.startOfDay(for: now)) : stats.planned
                let share = target > 0 ? stats.total / target : 1
                tile(running ? tr("План на сегодня", "Plan to date") : tr("План", "Plan"), target > 0 ? "\(Int((share * 100).rounded()))%" : "—",
                     running ? tr("\(hours(stats.total)) из \(hours(target)) · всего \(hours(stats.planned))", "\(hours(stats.total)) of \(hours(target)) · \(hours(stats.planned)) in all")
                             : tr("\(hours(stats.total)) из \(hours(stats.planned))", "\(hours(stats.total)) of \(hours(stats.planned))"),
                     color: share >= 0.9 ? Theme.green : share >= 0.6 ? Theme.yellow : Theme.red)
            } else {
                tile(tr("План", "Plan"), "—", tr("на период ничего не запланировано", "nothing planned for this period"), color: Theme.text3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle()
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(width: 1) }

    private func hours(_ h: Double) -> String { TimeEngine.text(hours: h) }

    private func tile(_ title: String, _ value: String, _ caption: String, color: Color = Theme.text, captionColor: Color = Theme.text3) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).uiFont(12.5, color: Theme.text2).lineLimit(1)
            Text(value).font(OrbitFont.ui(28, .semibold)).foregroundStyle(color).numericTransition(value)
            Text(caption).uiFont(12, color: captionColor).lineLimit(1)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Days

/// One column per day, stacked by project; a thin mark shows that day's plan.
private struct DayChart: View {
    @Environment(AppState.self) private var app
    var stats: TimeStats
    var period: TimePeriod
    @State private var grown = false

    private let height: CGFloat = 150

    var body: some View {
        let today = Week.calendar.startOfDay(for: app.now)
        let top = max(1, stats.days.map { max($0.total, $0.planned) }.max() ?? 1)
        let order = stats.projects.map(\.id)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Text(tr("По дням", "By day")).uiFont(14, .semibold)
                    Spacer()
                    ForEach(order.prefix(5), id: \.self) { ProjectLabel(projectId: $0, size: 12, color: Theme.text2) }
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.text2).frame(width: 12, height: 1.5)
                        Text(tr("план", "plan")).uiFont(12, color: Theme.text3)
                    }
                }
                HStack(alignment: .bottom, spacing: period.kind == .week ? 14 : 5) {
                    ForEach(Array(stats.days.enumerated()), id: \.element.id) { i, day in
                        VStack(spacing: 8) {
                            ZStack(alignment: .bottom) {
                                VStack(spacing: 1) {
                                    Spacer(minLength: 0)
                                    ForEach(order.reversed().filter { day.byProject[$0] != nil }, id: \.self) { id in
                                        Rectangle()
                                            .fill(Theme.projectColor(app.colorIndex(id)).opacity(day.date == today ? 1 : 0.85))
                                            .frame(height: grown ? max(2, height * (day.byProject[id] ?? 0) / top) : 0)
                                    }
                                    if day.total == 0 { Rectangle().fill(Theme.border).frame(height: 2) }
                                }
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                                if day.planned > 0 {
                                    Rectangle().fill(Theme.text2).frame(height: 1.5)
                                        .offset(y: -height * day.planned / top)
                                        .opacity(grown ? 1 : 0)
                                }
                            }
                            .frame(height: height)
                            .animation(Motion.pick(Motion.grow).delay(Motion.reduced ? 0 : Double(i) * 0.02), value: grown)
                            .help(tooltip(day))
                            Text(label(day.date)).monoFont(11.5, color: day.date == today ? Theme.accent : Theme.text3).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear { withMotion(Motion.grow) { grown = true } }
    }

    private func label(_ date: Date) -> String {
        period.kind == .week ? Week.shortNames[Week.weekdayIndex(date)] : "\(Week.calendar.component(.day, from: date))"
    }

    private func tooltip(_ day: TimeStats.Day) -> String {
        var lines = ["\(DateFormat.weekdayShort(day.date)): \(TimeEngine.text(hours: day.total))"]
        for (id, h) in day.byProject.sorted(by: { $0.value > $1.value }) { lines.append("\(app.projectName(id)) — \(TimeEngine.text(hours: h))") }
        if day.planned > 0 { lines.append(tr("план — \(TimeEngine.text(hours: day.planned))", "planned — \(TimeEngine.text(hours: day.planned))")) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Projects

private struct ProjectTimeTable: View {
    @Environment(AppState.self) private var app
    var stats: TimeStats

    var body: some View {
        let total = max(stats.total, 0.01)
        let top = max(stats.projects.map(\.hours).max() ?? 1, 0.01)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Eyebrow(text: tr("Проект", "Project")).frame(width: 190, alignment: .leading)
                Eyebrow(text: tr("Время", "Time")).frame(maxWidth: .infinity, alignment: .leading)
                Eyebrow(text: tr("Доля", "Share")).frame(width: 50, alignment: .trailing)
                Eyebrow(text: tr("План", "Plan")).frame(width: 70, alignment: .trailing)
                Eyebrow(text: tr("Сессии", "Sessions")).frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .hairline()
            ForEach(Array(stats.projects.enumerated()), id: \.element.id) { i, row in
                Button { app.screen = .project(row.id) } label: {
                    HStack(spacing: 16) {
                        ProjectLabel(projectId: row.id, size: 13).frame(width: 190, alignment: .leading)
                        HStack(spacing: 10) {
                            GeometryReader { geo in
                                Capsule().fill(Theme.projectColor(app.colorIndex(row.id)))
                                    .frame(width: max(row.hours > 0 ? 3 : 0, geo.size.width * row.hours / top), height: 6)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 16)
                            Text(TimeEngine.text(hours: row.hours)).uiFont(13.5, .medium).frame(width: 84, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                        Text("\(Int((row.hours / total * 100).rounded()))%").uiFont(13, color: Theme.text2).frame(width: 50, alignment: .trailing)
                        Text(row.planned > 0 ? TimeEngine.text(hours: row.planned) : "—")
                            .uiFont(13, color: row.planned > 0 && row.hours < row.planned * 0.6 ? Theme.yellow : Theme.text2).frame(width: 70, alignment: .trailing)
                        Text("\(row.sessions)").uiFont(13, color: Theme.text2).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .hoverHighlight()
                }
                .buttonStyle(PlainButtonStyle2())
                if i < stats.projects.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .cardStyle()
    }
}

// MARK: - When

/// Weekdays × hours of the day; brighter cells hold more work.
private struct HeatmapCard: View {
    var stats: TimeStats

    var body: some View {
        let top = max(stats.heat.flatMap { $0 }.max() ?? 0, 0.01)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(tr("Когда я работаю", "When I work")).uiFont(14, .semibold)
                    Spacer()
                    if let peak = stats.peak {
                        Text(tr("чаще всего: \(days(peak.days)), \(peak.hours.lowerBound)–\(peak.hours.upperBound + 1)",
                                "mostly \(days(peak.days)), \(peak.hours.lowerBound)–\(peak.hours.upperBound + 1)"))
                            .uiFont(12, color: Theme.text3)
                    }
                }
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        HStack(spacing: 3) {
                            Text(Week.shortNames[d]).monoFont(10.5, color: Theme.text3).frame(width: 26, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                let v = stats.heat[d][h]
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(v > 0.01 ? Theme.accent.opacity(0.18 + 0.82 * min(1, v / top)) : Theme.surface2)
                                    .frame(height: 14)
                                    .help(v > 0.01 ? "\(Week.shortNames[d]) \(h):00 — \(Duration.text(minutes: max(1, Int(v * 60))))" : "")
                            }
                        }
                    }
                    HStack(spacing: 3) {
                        Text("").frame(width: 26)
                        ForEach(0..<24, id: \.self) { h in
                            Text(h % 6 == 0 ? "\(h)" : "").monoFont(10, color: Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func days(_ r: ClosedRange<Int>) -> String {
        let names = Week.shortNames.map { $0.lowercased() }
        return r.count == 1 ? names[r.lowerBound] : "\(names[r.lowerBound])–\(names[r.upperBound])"
    }
}

// MARK: - Who

/// Time under the timer (you were at it) against agent time outside the timer (they worked without you).
private struct WhoWorkedCard: View {
    var stats: TimeStats
    @State private var shown = false

    var body: some View {
        let agents = stats.agentHours.values.reduce(0, +)
        let total = max(stats.timerHours + agents, 0.01)
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Сам и агенты", "You and the agents")).uiFont(14, .semibold)
                    Spacer()
                    if stats.sessions > 0 {
                        Text(tr("\(stats.sessionsWithCommit) из \(stats.sessions) сессий — с коммитом", "\(stats.sessionsWithCommit) of \(stats.sessions) sessions ended in a commit"))
                            .uiFont(12, color: Theme.text3)
                    }
                }
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        if stats.timerHours > 0.01 {
                            Capsule().fill(Theme.accent).frame(width: max(4, (geo.size.width - 3) * stats.timerHours / total))
                        }
                        if agents > 0.01 { Capsule().fill(Theme.violet) }
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: shown ? geo.size.width : 0) }
                }
                .frame(height: 10)
                HStack(alignment: .top, spacing: 20) {
                    part(Theme.accent, tr("Под таймером", "With the timer"), stats.timerHours, tr("вы за работой", "you at work"))
                    part(Theme.violet, tr("Агенты без таймера", "Agents on their own"), agents, breakdown)
                }
            }
        }
        .onAppear { withMotion(Motion.grow) { shown = true } }
    }

    private var breakdown: String {
        let parts = stats.agentHours.sorted { $0.value > $1.value }.map { "\($0.key.title) \(TimeEngine.text(hours: $0.value))" }
        return parts.isEmpty ? tr("сессий не было", "no sessions") : parts.joined(separator: " · ")
    }

    private func part(_ color: Color, _ title: String, _ hours: Double, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Dot(color: color)
                Text(title).uiFont(12.5, color: Theme.text2)
            }
            Text(TimeEngine.text(hours: hours)).uiFont(18, .semibold)
            Text(note).uiFont(12, color: Theme.text3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
