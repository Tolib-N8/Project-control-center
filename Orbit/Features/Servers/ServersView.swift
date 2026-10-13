import SwiftUI

/// "Серверы": is production alive, what runs there, and the button that deploys a new version step by step.
struct ServersView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let servers = app.allServers
        let checking = !app.serverChecking.isEmpty
        Page {
            PageHeader(eyebrow: eyebrow(servers), title: tr("Серверы", "Servers")) {
                if !servers.isEmpty {
                    OrbitButton(checking ? tr("Проверяю…", "Checking…") : tr("Проверить", "Check now"), icon: "arrow.clockwise") {
                        Task { await app.checkServers(force: true) }
                    }
                    .disabled(checking)
                }
                AddServerMenu(kind: servers.isEmpty ? .primary : .secondary)
            }

            if servers.isEmpty {
                VStack(spacing: 16) {
                    EmptyHint(symbol: "server.rack", title: tr("Серверов пока нет", "No servers yet"),
                              text: tr("Добавьте боевой сервер проекта — Orbit будет следить, что сайт отвечает и контейнеры живы,\nи выкатывать новую версию по шагам: проверки, код, сборка, запуск.",
                                       "Add a project’s production server — Orbit will watch that the site answers and the containers are alive,\nand deploy a new version step by step: checks, code, build, start."))
                    AddServerMenu(kind: .primary)
                }
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
                .cardStyle()
            } else {
                ServerTiles(servers: servers).appearStagger(0)
                ForEach(Array(app.config.activeProjects.filter { !($0.servers ?? []).isEmpty }.enumerated()), id: \.element.id) { i, project in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { app.screen = .project(project.id) } label: {
                            ProjectLabel(projectId: project.id, size: 13, color: Theme.text2)
                        }
                        .buttonStyle(PlainButtonStyle2())
                        ForEach(project.servers ?? []) { server in
                            ServerCard(projectId: project.id, server: server)
                        }
                    }
                    .appearStagger(i + 1)
                }
                if !app.macOnline {
                    Text(tr("На Mac нет сети — проверки приостановлены.", "The Mac is offline — checks are paused."))
                        .uiFont(12.5, color: Theme.yellow)
                }
            }
        }
        .task {
            // Opening the screen is a reason to look again, unless Orbit just did.
            let stale = servers.contains { ref in
                app.serverStatus[ref.id]?.hostCheckedAt.map { Date().timeIntervalSince($0) > 60 } ?? true
            }
            if stale { await app.checkServers(force: true) }
        }
    }

    private func eyebrow(_ servers: [AppState.ServerRef]) -> String {
        guard !servers.isEmpty else { return tr("Боевые серверы проектов", "Production servers of your projects") }
        let down = app.serversDown.count
        let count = plural(servers.count, ru: ("сервер", "сервера", "серверов"), en: ("server", "servers"))
        let checked = servers.compactMap { app.serverStatus[$0.id]?.siteCheckedAt ?? app.serverStatus[$0.id]?.hostCheckedAt }.max()
        let state = down > 0 ? tr("не отвечает: \(down)", "\(down) not responding") : checked == nil ? tr("ещё не проверены", "not checked yet") : tr("проверено \(DateFormat.ago(checked!, now: app.now))", "checked \(DateFormat.ago(checked!, now: app.now))")
        return "\(count) · \(state)"
    }
}

/// "+ Сервер": picks the project the new server belongs to.
struct AddServerMenu: View {
    @Environment(AppState.self) private var app
    var kind: OrbitButtonKind = .secondary

    var body: some View {
        MenuChip(icon: "plus", title: tr("Сервер", "Server"), kind: kind, chevron: false) {
            ForEach(app.config.activeProjects) { p in
                Button(p.name) { app.sheet = .serverSetup(projectId: p.id, serverId: nil) }
            }
        }
    }
}

// MARK: - Tiles

private struct ServerTiles: View {
    @Environment(AppState.self) private var app
    var servers: [AppState.ServerRef]

    var body: some View {
        let states = servers.map { app.serverStatus[$0.id]?.overall($0.server) ?? .unknown }
        let up = states.filter { $0 == .up }.count
        let down = app.serversDown
        let troubled = states.filter { $0 == .degraded || $0 == .noAccess }.count
        let dayAgo = app.now.addingTimeInterval(-86400)
        let responses = servers.compactMap { Uptime.averageMs(app.serverSamples[$0.id] ?? [], from: dayAgo) }
        let week = app.deployRuns.filter { $0.startedAt >= app.now.addingTimeInterval(-7 * 86400) && $0.state != .running }
        let failed = week.filter { $0.state == .failed }.count
        let last = app.deployRuns.first
        HStack(spacing: 0) {
            tile(tr("Работают", "Up"), tr("\(up) из \(servers.count)", "\(up) of \(servers.count)"),
                 !down.isEmpty ? tr("не отвечает: \(down.map(\.server.name).joined(separator: ", "))", "down: \(down.map(\.server.name).joined(separator: ", "))")
                    : troubled > 0 ? tr("требуют внимания: \(troubled)", "\(troubled) need attention")
                    : up == servers.count ? tr("все на связи", "all reachable") : tr("идёт первая проверка", "first check in progress"),
                 color: !down.isEmpty ? Theme.red : up == servers.count ? Theme.green : Theme.text,
                 captionColor: !down.isEmpty ? Theme.red : troubled > 0 ? Theme.yellow : Theme.text3)
            divider
            tile(tr("Ответ сайта", "Site response"), responses.isEmpty ? "—" : tr("\(responses.reduce(0, +) / responses.count) мс", "\(responses.reduce(0, +) / responses.count) ms"),
                 tr("в среднем за сутки", "average over 24 h"))
            divider
            tile(tr("Выкладок за 7 дней", "Deploys in 7 days"), "\(week.count)",
                 week.isEmpty ? tr("ещё не было", "none yet") : failed > 0 ? tr("неудачных: \(failed)", "\(failed) failed") : tr("все успешные", "all succeeded"),
                 captionColor: failed > 0 ? Theme.yellow : Theme.text3)
            divider
            if let last {
                tile(tr("Последняя выкладка", "Latest deploy"), DateFormat.ago(last.finishedAt ?? last.startedAt, now: app.now),
                     "\(app.projectName(last.projectId)) · \(DeployText.state(last))",
                     captionColor: last.state == .failed ? Theme.red : Theme.text3)
            } else {
                tile(tr("Последняя выкладка", "Latest deploy"), "—", tr("нажмите «Выкатить» на сервере", "press “Deploy” on a server"), color: Theme.text3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle()
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(width: 1) }

    private func tile(_ title: String, _ value: String, _ caption: String, color: Color = Theme.text, captionColor: Color = Theme.text3) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).uiFont(12.5, color: Theme.text2).lineLimit(1)
            Text(value).font(OrbitFont.ui(28, .semibold)).foregroundStyle(color).lineLimit(1).numericTransition(value)
            Text(caption).uiFont(12, color: captionColor).lineLimit(1)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Words shared by the server screens.
enum DeployText {
    static func state(_ run: DeployRun) -> String {
        switch run.state {
        case .running: tr("идёт", "running")
        case .success: run.trigger == .rollback ? tr("откат выполнен", "rolled back") : tr("успешно", "succeeded")
        case .failed: tr("не удалась", "failed")
        case .cancelled: tr("остановлена", "stopped")
        }
    }

    /// "Выкладка прошла", "Откат не удался"
    static func sentence(_ run: DeployRun) -> String {
        let rollback = run.trigger == .rollback
        switch run.state {
        case .running: return rollback ? tr("Идёт откат", "Rolling back") : tr("Идёт выкладка", "Deploying")
        case .success: return rollback ? tr("Откат выполнен", "Rolled back") : tr("Выкладка прошла", "Deploy succeeded")
        case .failed: return rollback ? tr("Откат не удался", "Rollback failed") : tr("Выкладка не удалась", "Deploy failed")
        case .cancelled: return rollback ? tr("Откат остановлен", "Rollback stopped") : tr("Выкладка остановлена", "Deploy stopped")
        }
    }

    static func color(_ state: DeployState) -> Color {
        switch state {
        case .running: Theme.accent
        case .success: Theme.green
        case .failed: Theme.red
        case .cancelled: Theme.yellow
        }
    }

    static func symbol(_ state: DeployState) -> String {
        switch state {
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    static func overall(_ o: ServerStatus.Overall) -> (text: String, color: Color) {
        switch o {
        case .up: (tr("Работает", "Up"), Theme.green)
        case .degraded: (tr("Есть проблемы", "Has problems"), Theme.yellow)
        case .down: (tr("Не отвечает", "Down"), Theme.red)
        case .noAccess: (tr("Нет доступа", "No access"), Theme.yellow)
        case .unknown: (tr("Не проверен", "Not checked"), Theme.text3)
        }
    }

    static func load(_ fraction: Double) -> Color {
        fraction >= 0.9 ? Theme.red : fraction >= 0.75 ? Theme.yellow : Theme.text2
    }
}

// MARK: - Card

struct ServerCard: View {
    @Environment(AppState.self) private var app
    var projectId: String
    var server: ServerConfig
    @State private var confirmRollback = false

    var body: some View {
        let status = app.serverStatus[server.id] ?? ServerStatus()
        let overall = DeployText.overall(status.overall(server))
        let deploying = app.isDeploying(server.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Dot(color: overall.color, size: 8)
                Text(server.name).uiFont(15, .semibold).lineLimit(1)
                Tag(text: overall.text, color: overall.color)
                Text("\(server.host) · \(server.directory)").monoFont(12, color: Theme.text3).lineLimit(1).truncationMode(.middle)
                if server.autoDeploy { Tag(text: tr("авто", "auto"), color: Theme.accent) }
                if !server.monitor { Tag(text: tr("слежение выключено", "not watched"), color: Theme.text3) }
                Spacer(minLength: 12)
                if app.serverChecking.contains(server.id) { ProgressView().controlSize(.small) }
                if server.runtime != .none {
                    OrbitButton(tr("Журнал", "Log"), icon: "scroll", compact: true) { app.sheet = .serverLog(serverId: server.id) }
                }
                MenuChip(icon: "ellipsis", title: "", chevron: false) {
                    Button(tr("Настроить…", "Settings…")) { app.sheet = .serverSetup(projectId: projectId, serverId: server.id) }
                    if server.siteURL != nil { Button(tr("Открыть сайт", "Open the site")) { app.openSite(server) } }
                    Button(tr("SSH в терминале", "SSH in Terminal")) { app.openServerTerminal(server) }
                    Divider()
                    Button(tr("Откатить на прошлую версию…", "Roll back to the previous version…")) { confirmRollback = true }
                        .disabled(deploying || app.rollbackTarget(server.id) == nil)
                }
                OrbitButton(deploying ? tr("Идёт выкладка…", "Deploying…") : tr("Выкатить", "Deploy"), icon: "arrow.up", kind: .primary, compact: true) {
                    app.sheet = .deploy(serverId: server.id)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .hairline()

            if let problem = status.sshProblem {
                ServerProblemNote(server: server, problem: problem, message: status.sshMessage,
                                  staleSince: status.host == nil || problem == .noDirectory ? nil : status.hostCheckedAt)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .hairline()
            }

            HStack(alignment: .top, spacing: 0) {
                column(tr("Сайт", "Site")) { SiteColumn(server: server, status: status) }
                divider
                column(tr("Версия", "Version")) { VersionColumn(server: server, status: status) }
                divider
                column(server.runtime == .systemd ? tr("Служба", "Service") : tr("Контейнеры", "Containers")) { ServicesColumn(server: server, status: status) }
                divider
                column(tr("Ресурсы", "Resources")) { ResourcesColumn(host: status.host) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .hairline()

            LastDeployRow(server: server)
                .padding(.horizontal, 20).padding(.vertical, 13)
        }
        .cardStyle()
        .animation(Motion.pick(Motion.content), value: status)
        .confirmationDialog(tr("Откатить «\(server.name)»?", "Roll back “\(server.name)”?"), isPresented: $confirmRollback) {
            Button(tr("Откатить", "Roll back")) {
                app.startRollback(server.id)
                app.sheet = .deploy(serverId: server.id)
            }
            Button(tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Код вернётся на \(String((app.rollbackTarget(server.id) ?? "").prefix(7))), шаги на сервере выполнятся заново. Изменения в базе данных не откатываются.",
                    "The code goes back to \(String((app.rollbackTarget(server.id) ?? "").prefix(7))) and the server steps run again. Database changes are not rolled back."))
        }
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(width: 1) }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            content()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Why SSH doesn't work and what to do about it.
struct ServerProblemNote: View {
    @Environment(AppState.self) private var app
    var server: ServerConfig
    var problem: SSHProblem
    var message: String?
    /// The numbers under the note are from the last visit that worked; this says so.
    var staleSince: Date? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Theme.yellow).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(problem.title).uiFont(13.5, .semibold)
                Text(problem.hint).uiFont(12.5, color: Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let message, !message.isEmpty, problem != .auth {
                    Text(message).monoFont(11.5, color: Theme.text3).lineLimit(2).textSelection(.enabled)
                }
                if staleSince != nil {
                    Text(tr("Версия, контейнеры и ресурсы ниже — с последнего удачного захода на сервер.", "The version, containers and resources below are from the last visit that worked."))
                        .uiFont(12, color: Theme.text3)
                }
            }
            Spacer(minLength: 12)
            if problem == .auth {
                OrbitButton(tr("Положить ключ на сервер", "Install a key on the server"), icon: "key", compact: true) { app.installKey(server) }
            }
        }
    }
}

private struct SiteColumn: View {
    @Environment(AppState.self) private var app
    var server: ServerConfig
    var status: ServerStatus

    var body: some View {
        let samples = app.serverSamples[server.id] ?? []
        if server.siteURL == nil {
            Text(tr("Адрес не задан", "No address set")).uiFont(13.5, color: Theme.text3)
            Text(tr("Доступность считается по SSH", "Availability is measured over SSH")).uiFont(12, color: Theme.text3)
        } else if let site = status.site {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(site.code.map(String.init) ?? site.error ?? tr("нет ответа", "no answer"))
                    .uiFont(20, .semibold, color: site.up ? Theme.text : Theme.red).lineLimit(1)
                if site.up, let ms = site.ms { Text(tr("\(ms) мс", "\(ms) ms")).uiFont(13, color: ms > 1500 ? Theme.yellow : Theme.text2) }
                if !site.up, site.code != nil { Text(tr("ошибка сервера", "server error")).uiFont(12.5, color: Theme.red).lineLimit(1) }
            }
        } else {
            Text("—").uiFont(20, .semibold, color: Theme.text3)
        }
        UptimeStrip(samples: samples, now: app.now)
        if let share = Uptime.share(samples, from: app.now.addingTimeInterval(-7 * 86400)) {
            Text(tr("\(Uptime.text(share)) за 7 дней · по проверкам Orbit", "\(Uptime.text(share)) over 7 days · by Orbit’s checks"))
                .uiFont(12, color: share < 0.99 ? Theme.yellow : Theme.text3).lineLimit(1)
        } else {
            Text(samples.isEmpty ? tr("проверок ещё не было", "no checks yet") : tr("доступность появится после \(Uptime.enoughSamples) проверок", "availability shows after \(Uptime.enoughSamples) checks"))
                .uiFont(12, color: Theme.text3).lineLimit(1)
        }
    }
}

/// The last 24 hours in half-hour slices: green — every check passed, red — at least one failed.
struct UptimeStrip: View {
    var samples: [ServerSample]
    var now: Date

    var body: some View {
        let slices = Uptime.strip(samples, now: now)
        HStack(spacing: 2) {
            ForEach(Array(slices.enumerated()), id: \.offset) { _, s in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(s == nil ? Theme.surface2 : s == true ? Theme.green.opacity(0.75) : Theme.red)
                    .frame(height: 16)
            }
        }
        .help(tr("Последние 24 часа, по получасам. Серое — Orbit не проверял (Mac спал или был выключен).",
                 "The last 24 hours in half-hour slices. Grey — Orbit didn’t check (the Mac was asleep or off)."))
    }
}

private struct VersionColumn: View {
    @Environment(AppState.self) private var app
    var server: ServerConfig
    var status: ServerStatus

    var body: some View {
        if let host = status.host, let commit = host.shortCommit {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit).monoFont(15, .semibold)
                if let date = host.commitDate { Text(DateFormat.ago(date, now: app.now)).uiFont(12.5, color: Theme.text3) }
            }
            if let subject = host.commitSubject {
                Text(subject).uiFont(12.5, color: Theme.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let behind = status.behind {
                Text(behind == 0 ? tr("последняя версия ветки \(server.branch)", "latest of branch \(server.branch)")
                                 : tr("отстаёт от \(server.branch) на \(Plural.commits(behind))", "\(Plural.commits(behind)) behind \(server.branch)"))
                    .uiFont(12, color: behind == 0 ? Theme.green : Theme.yellow).lineLimit(1)
            } else if let tip = status.remoteCommit, tip != host.commit {
                Text(tr("в ветке \(server.branch) есть новые коммиты", "branch \(server.branch) has new commits")).uiFont(12, color: Theme.yellow).lineLimit(1)
            }
            if let branch = host.branch, branch != server.branch {
                Text(tr("на сервере ветка \(branch)", "the server is on branch \(branch)")).uiFont(12, color: Theme.yellow).lineLimit(1)
            } else if host.branch == nil {
                Text(tr("вне ветки — так бывает после отката", "detached — as after a rollback")).uiFont(12, color: Theme.text3).lineLimit(1)
            }
            if host.dirty > 0 {
                Text(tr("изменено руками: \(Plural.files(host.dirty))", "edited by hand: \(Plural.files(host.dirty))")).uiFont(12, color: Theme.yellow).lineLimit(1)
            }
        } else if let host = status.host, !host.directoryMissing {
            Text(tr("git не найден", "no git found")).uiFont(13.5, color: Theme.text3)
            Text(tr("в папке нет репозитория", "no repository in the folder")).uiFont(12, color: Theme.text3)
        } else {
            Text("—").monoFont(15, .semibold, color: Theme.text3)
        }
    }
}

private struct ServicesColumn: View {
    var server: ServerConfig
    var status: ServerStatus

    var body: some View {
        if server.runtime == .none {
            Text(tr("Не отслеживается", "Not tracked")).uiFont(13.5, color: Theme.text3)
            Text(tr("выберите Docker Compose или службу в настройках", "choose Docker Compose or a service in settings"))
                .uiFont(12, color: Theme.text3).fixedSize(horizontal: false, vertical: true)
        } else if let host = status.host {
            if let error = host.runtimeError {
                Text(error).uiFont(12.5, color: Theme.yellow).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(host.services.prefix(6)) { s in
                HStack(spacing: 8) {
                    Dot(color: s.ok ? Theme.green : s.restarting ? Theme.yellow : Theme.red)
                    Text(s.name).monoFont(12.5).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(label(s)).uiFont(12, color: s.ok ? Theme.text3 : Theme.red).lineLimit(1)
                }
            }
            if host.services.count > 6 {
                Text(tr("и ещё \(host.services.count - 6)", "and \(host.services.count - 6) more")).uiFont(12, color: Theme.text3)
            }
        } else {
            Text("—").uiFont(13.5, color: Theme.text3)
        }
    }

    private func label(_ s: ServiceState) -> String {
        if s.health == "unhealthy" { return "unhealthy" }
        switch s.state {
        case "running", "active": return tr("работает", "running")
        case "restarting", "activating": return tr("перезапуск", "restarting")
        case "exited", "inactive": return tr("остановлен", "stopped")
        case "failed", "dead": return tr("упал", "failed")
        default: return s.state
        }
    }
}

private struct ResourcesColumn: View {
    var host: HostFacts?

    var body: some View {
        if let host, host.cpuFraction != nil || host.memFraction != nil || host.diskFraction != nil {
            row(tr("Процессор", "CPU"), host.cpuFraction, detail: host.load1.map { String(format: "load %.2f", $0) })
            row(tr("Память", "Memory"), host.memFraction, detail: host.memTotalMB.map { gb(Double($0) / 1024) })
            row(tr("Диск", "Disk"), host.diskFraction, detail: host.diskTotalKB.map { gb(Double($0) / 1_048_576) })
        } else {
            Text("—").uiFont(13.5, color: Theme.text3)
        }
    }

    private func gb(_ value: Double) -> String { String(format: value < 10 ? "%.1f GB" : "%.0f GB", value) }

    @ViewBuilder
    private func row(_ title: String, _ fraction: Double?, detail: String?) -> some View {
        if let fraction {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).uiFont(12.5, color: Theme.text2)
                    Spacer(minLength: 6)
                    Text("\(Int((fraction * 100).rounded())) %").monoFont(12, color: DeployText.load(fraction) == Theme.text2 ? Theme.text : DeployText.load(fraction))
                }
                ProgressLine(fraction: fraction, color: DeployText.load(fraction))
            }
            .help(detail ?? "")
        }
    }
}

private struct LastDeployRow: View {
    @Environment(AppState.self) private var app
    var server: ServerConfig

    var body: some View {
        HStack(spacing: 10) {
            if let run = app.lastRun(server.id) {
                Image(systemName: DeployText.symbol(run.state)).font(.system(size: 12)).foregroundStyle(DeployText.color(run.state))
                    .symbolEffect(.rotate, options: .repeating, isActive: run.state == .running && !Motion.reduced)
                Text(text(run)).uiFont(12.5, color: Theme.text2).lineLimit(1)
                if run.state == .failed, let step = run.failedStep {
                    Text(tr("шаг «\(step.name)»", "step “\(step.name)”")).uiFont(12.5, color: Theme.red).lineLimit(1)
                }
            } else {
                Text(tr("Выкладок с этого Mac ещё не было", "No deploys from this Mac yet")).uiFont(12.5, color: Theme.text3)
            }
            Spacer()
            let count = app.runs(server.id).count
            if count > 0 {
                Button { app.sheet = .deploy(serverId: server.id) } label: {
                    HStack(spacing: 5) {
                        Text(tr("История · \(count)", "History · \(count)")).uiFont(12.5, color: Theme.text2)
                        Icon("chevron.right", size: 9).foregroundStyle(Theme.text3)
                    }
                }
                .buttonStyle(PlainButtonStyle2())
            }
        }
    }

    private func text(_ run: DeployRun) -> String {
        var parts = [DeployText.sentence(run), DateFormat.relativeDay(run.startedAt)]
        if let s = run.seconds { parts.append(Elapsed.text(s)) }
        parts.append(run.trigger.title)
        if let c = run.shortTo { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}
