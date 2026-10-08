import SwiftUI

/// "Память агентов": what fresh Claude Code and Codex sessions read about this project before they start.
struct MemoryPanel: View {
    @Environment(AppState.self) private var app
    var projectId: String

    var body: some View {
        let enabled = app.memoryEnabled(projectId)
        let record = app.memoryRecords[projectId]
        let busy = app.memoryBusy.contains(projectId)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Память агентов", "Agent memory")).uiFont(14, .semibold)
                Spacer()
                OrbitToggle(isOn: Binding(get: { enabled }, set: { app.setMemoryEnabled(projectId, $0) }))
                    .help(tr("Вести память для Claude Code и Codex", "Keep memory for Claude Code and Codex"))
            }

            if !enabled {
                Text(tr("Выключено — новые сессии агентов начинают без контекста от Orbit.", "Off — new agent sessions start without context from Orbit."))
                    .uiFont(12.5, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            } else if let record {
                status(record, busy: busy)
                preview(record.memory)
                actions(busy: busy, exists: true)
            } else {
                Text(busy ? tr("Собираю память по сессиям…", "Building memory from sessions…")
                          : tr("Памяти ещё нет. Orbit соберёт её после следующей сессии агента — или сейчас.", "No memory yet. Orbit builds it after the next agent session — or right now."))
                    .uiFont(12.5, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                actions(busy: busy, exists: false)
            }

            if enabled {
                Text(tr("Claude Code читает её через CLAUDE.local.md, Codex — через AGENTS.md. В git не попадает.",
                        "Claude Code reads it via CLAUDE.local.md, Codex via AGENTS.md. Stays out of git."))
                    .uiFont(11.5, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .cardStyle()
        .animation(Motion.pick(Motion.content), value: enabled)
        .animation(Motion.pick(Motion.content), value: busy)
        .animation(Motion.pick(Motion.content), value: record?.updatedAt)
    }

    private func status(_ record: MemoryRecord, busy: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(busy ? Theme.accent : Theme.text3)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busy && !Motion.reduced)
            Text(busy ? tr("Обновляю…", "Updating…")
                      : "\(DateFormat.ago(record.updatedAt, now: app.now)) · \(record.source) · \(Plural.sessions(record.sessions))")
                .uiFont(12, color: Theme.text3).lineLimit(1)
                .contentTransition(.opacity)
        }
    }

    @ViewBuilder
    private func preview(_ m: ProjectMemory) -> some View {
        let m = m.redacted()
        if !m.verify.isEmpty {
            section(tr("Как проверять", "How to verify")) {
                ForEach(m.verify.prefix(2), id: \.self) { c in
                    Text(c.command).monoFont(11.5, color: Theme.text2).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        if !m.next.isEmpty {
            section(tr("Что дальше", "What's next")) {
                ForEach(Array(m.next.prefix(3).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").uiFont(12.5, color: Theme.text3)
                        Text(line).uiFont(12.5, color: Theme.text2).lineLimit(2)
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).uiFont(11.5, .medium, color: Theme.text3)
            content()
        }
    }

    private func actions(busy: Bool, exists: Bool) -> some View {
        HStack(spacing: 8) {
            OrbitButton(exists ? tr("Обновить", "Update") : tr("Собрать сейчас", "Build now"), icon: "sparkles", compact: true) {
                Task { await app.refreshMemory(projectId, force: true) }
            }
            .disabled(busy)
            if exists {
                OrbitButton(tr("Открыть", "Open"), icon: "doc.text", compact: true) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: app.memoryFilePath(projectId)))
                }
                Button { Shell.reveal(app.memoryFilePath(projectId)) } label: {
                    Icon("folder", size: 12, weight: .regular).foregroundStyle(Theme.text2).frame(width: 28, height: 26)
                }
                .buttonStyle(PlainButtonStyle2())
                .help(tr("Показать в Finder", "Show in Finder"))
            }
        }
    }
}
