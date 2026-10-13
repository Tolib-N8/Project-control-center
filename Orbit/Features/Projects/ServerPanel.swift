import SwiftUI

/// "Серверы" on a project page: is production up, and the deploy button.
struct ServerPanel: View {
    @Environment(AppState.self) private var app
    var projectId: String

    var body: some View {
        let servers = app.servers(for: projectId)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Серверы", "Servers")).uiFont(14, .semibold)
                Spacer()
                Button { app.sheet = .serverSetup(projectId: projectId, serverId: nil) } label: {
                    Icon("plus", size: 12).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle2())
                .help(tr("Добавить сервер", "Add a server"))
            }

            if servers.isEmpty {
                Text(tr("Добавьте боевой сервер — Orbit будет следить за ним и выкатывать новую версию по шагам.",
                        "Add the production server — Orbit will watch it and deploy new versions step by step."))
                    .uiFont(12.5, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    ForEach(servers) { server in row(server) }
                }
            }
        }
        .padding(20)
        .cardStyle()
    }

    private func row(_ server: ServerConfig) -> some View {
        let status = app.serverStatus[server.id] ?? ServerStatus()
        let overall = DeployText.overall(status.overall(server))
        let deploying = app.isDeploying(server.id)
        return HStack(spacing: 10) {
            Button { app.screen = .servers } label: {
                HStack(spacing: 10) {
                    Dot(color: overall.color, size: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name).uiFont(13.5, .medium).lineLimit(1)
                        Text(detail(server, status, overall.text)).uiFont(12, color: Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(PlainButtonStyle2())
            OrbitButton(deploying ? tr("Идёт…", "Running…") : tr("Выкатить", "Deploy"), icon: "arrow.up", compact: true) {
                app.sheet = .deploy(serverId: server.id)
            }
        }
    }

    private func detail(_ server: ServerConfig, _ status: ServerStatus, _ state: String) -> String {
        var parts = [state.lowercased()]
        if let site = status.site, site.up, let ms = site.ms { parts.append(tr("\(ms) мс", "\(ms) ms")) }
        if let behind = status.behind, behind > 0 {
            parts.append(tr("отстаёт на \(behind)", "\(behind) behind"))
        } else if let commit = status.host?.shortCommit {
            parts.append(commit)
        }
        return parts.joined(separator: " · ")
    }
}
