import SwiftUI

/// Planner modal: projects × days grid (design 07).
struct WeekPlannerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var weekKey: String
    @State private var plan = WeekPlan(weekKey: "")
    @State private var seed = 0
    @State private var demands: [Planner.Demand] = []

    init(weekKey: String) { _weekKey = State(initialValue: weekKey) }

    var body: some View {
        let monday = Week.date(fromKey: weekKey) ?? app.currentMonday
        let capacity = app.config.rhythm.weeklyHours
        VStack(spacing: 0) {
            header(monday, capacity: capacity)
            if let rationale = plan.rationale {
                HStack(alignment: .top, spacing: 14) {
                    IconBox(symbol: "sparkles", color: Theme.accent, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("План составлен по состоянию проектов").uiFont(13.5, .semibold)
                        Text(rationale).uiFont(13, color: Theme.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    OrbitButton("Другой вариант", icon: "arrow.triangle.2.circlepath") {
                        seed += 1
                        withMotion(Motion.page) { plan = app.makePlan(weekKey: weekKey, seed: seed) }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
                .background(Theme.surface2.opacity(0.6))
                .hairline()
            }
            grid(monday)
                .animation(Motion.pick(Motion.snappy), value: plan.blocks)
                .id(weekKey)
                .transition(Motion.transition(.opacity))
            footer(capacity: capacity)
        }
        .frame(width: 960)
        .background(Theme.surface)
        .onAppear(perform: load)
    }

    private func load() {
        let existing = app.plan(weekKey)
        plan = existing.blocks.isEmpty ? app.makePlan(weekKey: weekKey) : existing
        demands = Planner.demands(projects: app.activeSnapshots, signals: app.activeSignals, capacity: app.config.rhythm.weeklyHours)
    }

    private func header(_ monday: Date, capacity: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("План на неделю \(Week.number(monday))").uiFont(20, .semibold)
                Text("\(DateFormat.short(monday)) — \(DateFormat.short(Week.day(6, of: monday))) · доступно \(capacity) ч")
                    .uiFont(13, color: Theme.text2)
            }
            Spacer()
            HStack(spacing: 0) {
                navButton("chevron.left") { shiftWeek(-1) }
                navButton("chevron.right") { shiftWeek(1) }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14)).foregroundStyle(Theme.text2).frame(width: 32, height: 32)
            }
            .buttonStyle(PlainButtonStyle2())
            .padding(.leading, 12)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .hairline()
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).frame(width: 36, height: 32)
        }
        .buttonStyle(PlainButtonStyle2())
    }

    private func shiftWeek(_ delta: Int) {
        guard let monday = Week.date(fromKey: weekKey) else { return }
        withMotion(Motion.page) {
            weekKey = Week.key(Week.calendar.date(byAdding: .day, value: 7 * delta, to: monday)!)
            seed = 0
            load()
        }
    }

    private func grid(_ monday: Date) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(text: "Проект").frame(width: 250, alignment: .leading)
                ForEach(0..<7, id: \.self) { d in
                    Text("\(Week.shortNames[d]) \(Week.calendar.component(.day, from: Week.day(d, of: monday)))")
                        .uiFont(12.5, .medium, color: app.config.rhythm.hours[d] == 0 ? Theme.text3 : Theme.text2)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 12)
            .hairline()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(app.activeSnapshots, id: \.config.id) { snap in
                        row(snap).hairline()
                    }
                }
            }
            .frame(maxHeight: 420)

            HStack(spacing: 8) {
                Text("Итого в день").uiFont(13, color: Theme.text2).frame(width: 250, alignment: .leading)
                ForEach(0..<7, id: \.self) { d in
                    let h = plan.hours(on: d)
                    Text(h == 0 ? "—" : "\(Duration.hours(h)) ч")
                        .monoFont(12.5, color: h > Double(app.config.rhythm.hours[d]) ? Theme.red : (h == 0 ? Theme.text3 : Theme.text))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 32)
    }

    private func row(_ snap: ProjectSnapshot) -> some View {
        let pid = snap.config.id
        let score = app.health[pid] ?? 0
        let note = Planner.recommendation(for: pid, demands: demands) ?? InsightEngine.plannerNote(snap, signals: [])
        let urgent = app.activeSignals.contains { $0.projectId == pid && $0.severity == .critical }
        return HStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ProjectSquare(colorIndex: snap.config.colorIndex).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(snap.config.name).monoFont(13, .medium).lineLimit(1)
                        Text("\(score)").monoFont(12, .medium, color: Theme.healthColor(score))
                    }
                    Text(urgent ? InsightEngine.plannerNote(snap, signals: app.activeSignals.filter { $0.projectId == pid }) : note)
                        .uiFont(12, color: urgent ? Theme.red : Theme.text2).lineLimit(1)
                }
            }
            .frame(width: 250, alignment: .leading)
            ForEach(0..<7, id: \.self) { d in cell(pid: pid, day: d, color: Theme.projectColor(snap.config.colorIndex)) }
        }
        .padding(.vertical, 8)
    }

    private func cell(pid: String, day: Int, color: Color) -> some View {
        let block = plan.blocks.first { $0.projectId == pid && $0.day == day }
        let hours = block?.hours ?? 0
        return Button {
            setHours(pid: pid, day: day, hours: hours == 0 ? 2 : (hours >= 8 ? 0 : hours + 1))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(hours > 0 ? color.opacity(0.18) : Theme.bg.opacity(0.4))
                RoundedRectangle(cornerRadius: 7).strokeBorder(hours > 0 ? color.opacity(0.0) : Theme.border)
                if hours > 0 {
                    HStack(spacing: 0) {
                        Rectangle().fill(color).frame(width: 2)
                        Spacer()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    Text("\(Duration.hours(hours)) ч").monoFont(13, .semibold, color: color)
                        .numericTransition(hours)
                }
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle2())
        .contextMenu {
            ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8], id: \.self) { h in
                Button(h == 0 ? "Убрать" : "\(h) ч") { setHours(pid: pid, day: day, hours: Double(h)) }
            }
        }
        .frame(maxWidth: .infinity)
        .help("Клик — добавить час, правый клик — выбрать")
    }

    private func setHours(pid: String, day: Int, hours: Double) {
        if let i = plan.blocks.firstIndex(where: { $0.projectId == pid && $0.day == day }) {
            if hours == 0 { plan.blocks.remove(at: i) } else { plan.blocks[i].hours = hours }
        } else if hours > 0 {
            plan.blocks.append(PlanBlock(projectId: pid, day: day, hours: hours))
        }
        plan.generated = false
    }

    private func footer(capacity: Int) -> some View {
        let total = plan.totalHours
        let weekend = plan.blocks.allSatisfy { $0.day < 5 }
        return HStack(spacing: 14) {
            ProgressLine(fraction: capacity == 0 ? 0 : total / Double(capacity), color: total > Double(capacity) ? Theme.red : Theme.accent, height: 6)
                .frame(width: 200)
            Text("\(Duration.hours(total)) ч из \(capacity) ч" + (weekend ? " · выходные свободны" : "")).uiFont(13, color: Theme.text2)
            Spacer()
            if !plan.blocks.isEmpty {
                OrbitButton("Очистить") { plan.blocks.removeAll(); plan.rationale = nil }
            }
            OrbitButton("Отмена") { dismiss() }
            OrbitButton("Сохранить план", icon: "checkmark", kind: .primary) {
                app.savePlan(plan)
                app.toast = "План на неделю \(Week.number(Week.date(fromKey: weekKey) ?? Date())) сохранён"
                dismiss()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .hairline(.top)
    }
}

/// Fallback sheet for adding a project to a day.
struct AddBlockSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var day: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить проект на \(Week.shortNames[day])").uiFont(16, .semibold)
            ForEach(app.config.activeProjects) { p in
                Button { app.addBlock(projectId: p.id, day: day); dismiss() } label: {
                    ProjectLabel(projectId: p.id).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .buttonStyle(PlainButtonStyle2())
            }
            OrbitButton("Закрыть") { dismiss() }
        }
        .padding(24)
        .frame(width: 360)
        .background(Theme.surface)
    }
}
