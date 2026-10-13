import SwiftUI

/// "Журнал": the last lines of the server's log, without opening an SSH session by hand.
struct ServerLogSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var serverId: UUID

    @State private var lines: [String] = []
    @State private var error: String?
    @State private var loading = false
    @State private var errorsOnly = false
    @State private var loadedAt: Date?

    #if DEBUG
    /// Set by the snapshot tool instead of asking a server.
    nonisolated(unsafe) static var debugLog: String?
    #endif

    var body: some View {
        let ref = app.serverRef(serverId)
        let shown = errorsOnly ? lines.filter(LogText.isError) : lines
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Журнал", "Log")).uiFont(18, .semibold)
                    if let ref {
                        Text("\(app.projectName(ref.projectId)) · \(ref.server.name) · \(source(ref.server))").uiFont(12.5, color: Theme.text2).lineLimit(1)
                    }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                SegmentedTabs(items: [(false, tr("Все строки", "All lines")), (true, tr("Только ошибки · \(lines.filter(LogText.isError).count)", "Errors only · \(lines.filter(LogText.isError).count)"))],
                              selection: $errorsOnly)
                OrbitButton(tr("Обновить", "Refresh"), icon: "arrow.clockwise", compact: true) { load() }.disabled(loading)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
            .hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if let error {
                            Text(error).uiFont(13, color: Theme.red).fixedSize(horizontal: false, vertical: true)
                        } else if shown.isEmpty, !loading {
                            Text(errorsOnly && !lines.isEmpty ? tr("Строк с ошибками нет.", "No lines with errors.") : tr("Журнал пуст.", "The log is empty."))
                                .uiFont(13, color: Theme.text3)
                        }
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .monoFont(11.5, color: LogText.isError(line) ? Theme.red : Theme.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(18)
                }
                .onChange(of: shown.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)

            HStack {
                Text(loadedAt.map { tr("Строк: \(lines.count) · получено в \(DateFormat.time.string(from: $0))", "Lines: \(lines.count) · fetched at \(DateFormat.time.string(from: $0))") } ?? "")
                    .uiFont(12, color: Theme.text3)
                Spacer()
                if let ref { OrbitButton(tr("SSH в терминале", "SSH in Terminal"), icon: "terminal") { app.openServerTerminal(ref.server) } }
                OrbitButton(tr("Закрыть", "Close"), kind: .primary) { dismiss() }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .hairline(.top)
        }
        .frame(width: 900, height: 660)
        .background(Theme.surface)
        .onAppear(perform: load)
    }

    private func source(_ server: ServerConfig) -> String {
        server.runtime == .systemd ? "journalctl -u \(server.unit ?? "")" : "docker compose logs"
    }

    private func load() {
        #if DEBUG
        if let fixture = Self.debugLog {
            lines = fixture.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            loadedAt = Date()
            return
        }
        #endif
        guard let ref = app.serverRef(serverId), app.serverChecksAllowed else { return }
        loading = true
        let server = ref.server
        Task {
            let r = await Task.detached { ServerProbe.log(server) }.value
            error = r.error
            lines = r.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.last?.isEmpty == true { lines.removeLast() }
            loadedAt = Date()
            loading = false
        }
    }
}
