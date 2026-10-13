import Foundation

#if DEBUG
/// Made-up servers for the snapshot tool, so the server screens can be rendered without a real server.
/// Nothing is saved to the config; logs go under the (throwaway) data directory.
@MainActor
enum ServerFixtures {
    static var main: UUID?
    static var failing: UUID?
    static var failedRun: UUID?
    static var runningRun: UUID?
    static var successRun: UUID?

    static func install(_ app: AppState) {
        guard main == nil else { return }
        let ranked = app.activeSnapshots.sorted { $0.sessions.count > $1.sessions.count }.map(\.config.id)
        guard let a = ranked.first else { return }
        let b = ranked.dropFirst().first ?? a
        let now = Date()

        let prod = ServerConfig(name: tr("Основной", "Production"), host: "root@203.0.113.10", directory: "/opt/parking",
                                url: "https://parking.example.ru", branch: "main", runtime: .compose,
                                steps: [DeployStep(name: tr("Тесты", "Tests"), command: "npm ci && npm test", place: .mac), .code(),
                                        DeployStep(name: tr("Резервная копия", "Backup"), command: "docker exec parking-db pg_dump -U app app > ~/backup-$(date +%F-%H%M).sql"),
                                        DeployStep(name: tr("Сборка", "Build"), command: "docker compose build backend frontend"),
                                        DeployStep(name: tr("Запуск", "Start"), command: "docker compose up -d backend frontend")],
                                autoDeploy: true)
        let south = ServerConfig(name: tr("Клиент Юг", "Client South"), host: "deploy@198.51.100.24", port: 2222, directory: "/srv/parking",
                                 url: "http://198.51.100.24:8080", branch: "release", runtime: .compose,
                                 steps: [.code(), DeployStep(name: tr("Сборка и запуск", "Build and start"), command: "docker compose up -d --build")])
        let smena = ServerConfig(name: tr("Основной", "Production"), host: "smena-vps", directory: "/opt/smena", url: "https://smena.example.ru",
                                 branch: "main", runtime: .systemd, unit: "smena",
                                 steps: [DeployStep(name: tr("Тесты", "Tests"), command: "npm ci && npm test", place: .mac), .code(),
                                         DeployStep(name: tr("Обновление", "Update"), command: "npm ci && npm run build && sudo systemctl restart smena")])
        main = prod.id
        failing = smena.id

        for i in app.config.projects.indices {
            if app.config.projects[i].id == a { app.config.projects[i].servers = a == b ? [prod, south, smena] : [prod, south] }
            else if app.config.projects[i].id == b { app.config.projects[i].servers = [smena] }
        }

        func commit(_ seed: String) -> String { String((seed + "0123456789abcdef0123456789abcdef01234567").prefix(40)) }
        app.serverStatus[prod.id] = ServerStatus(
            site: SiteCheck(code: 200, ms: 142), siteCheckedAt: now.addingTimeInterval(-70),
            host: HostFacts(load1: 0.24, cores: 2, memTotalMB: 3915, memAvailableMB: 1520, diskTotalKB: 41_152_736, diskUsedKB: 18_107_204,
                            commit: commit("a1b2c3d"), commitSubject: "Fix exit barrier timeout for long plates", commitDate: now.addingTimeInterval(-26 * 3600), branch: "main",
                            services: [ServiceState(name: "backend", state: "running", health: "healthy"), ServiceState(name: "db", state: "running", health: "healthy"),
                                       ServiceState(name: "frontend", state: "running"), ServiceState(name: "redis", state: "running")]),
            hostCheckedAt: now.addingTimeInterval(-70), remoteCommit: commit("e4f5a6b"), behind: 3)
        app.serverStatus[south.id] = ServerStatus(
            site: SiteCheck(code: nil, ms: nil, error: tr("нет ответа", "no answer")), siteCheckedAt: now.addingTimeInterval(-40), siteFailures: 4,
            host: HostFacts(load1: 0.1, cores: 1, memTotalMB: 976, memAvailableMB: 310, diskTotalKB: 24_000_000, diskUsedKB: 9_100_000,
                            commit: commit("9c8d7e6"), commitSubject: "Release 1.8", commitDate: now.addingTimeInterval(-9 * 86400), branch: "release",
                            services: [ServiceState(name: "backend", state: "running"), ServiceState(name: "db", state: "running")]),
            hostCheckedAt: now.addingTimeInterval(-6 * 60), sshProblem: .timeout, sshMessage: "ssh: connect to host 198.51.100.24 port 2222: Operation timed out",
            sshFailures: 2, remoteCommit: commit("9c8d7e6"), behind: 0)
        app.serverStatus[smena.id] = ServerStatus(
            site: SiteCheck(code: 200, ms: 318), siteCheckedAt: now.addingTimeInterval(-55),
            host: HostFacts(load1: 0.92, cores: 1, memTotalMB: 976, memAvailableMB: 180, diskTotalKB: 15_000_000, diskUsedKB: 13_860_000,
                            commit: commit("5d6e7f8"), commitSubject: "Shift report: totals by restaurant", commitDate: now.addingTimeInterval(-3 * 86400), branch: "main", dirty: 1,
                            services: [ServiceState(name: "smena", state: "active", restarts: 0)]),
            hostCheckedAt: now.addingTimeInterval(-55), remoteCommit: commit("77aa88b"), behind: 2)

        // A week of checks: steady for the first two, one evening outage for the third; the second went down an hour ago.
        func samples(ms: Int, outage: ClosedRange<Double>?) -> [ServerSample] {
            stride(from: 7.0 * 86400, to: 0, by: -600).map { ago in
                let down = outage.map { $0.contains(ago) } ?? false
                return ServerSample(t: now.addingTimeInterval(-ago), up: !down, ms: down ? nil : ms + Int(ago.truncatingRemainder(dividingBy: 37)))
            }
        }
        app.serverSamples[prod.id] = samples(ms: 130, outage: nil)
        app.serverSamples[south.id] = samples(ms: 210, outage: 0...3600)
        app.serverSamples[smena.id] = samples(ms: 300, outage: (20 * 3600)...(21 * 3600))

        func steps(_ names: [(String, StepPlace, StepState, Double?)], note: String? = nil) -> [StepRun] {
            names.map { StepRun(name: $0.0, place: $0.1, state: $0.2, startedAt: now, seconds: $0.3, note: $0.2 == .failed ? note : nil) }
        }
        let ok = DeployRun(projectId: a, serverId: prod.id, trigger: .auto, startedAt: now.addingTimeInterval(-26 * 3600), finishedAt: now.addingTimeInterval(-26 * 3600 + 168),
                           fromCommit: commit("0f9e8d7"), toCommit: commit("a1b2c3d"), toSubject: "Fix exit barrier timeout for long plates",
                           steps: steps([(tr("Подключение", "Connect"), .server, .success, 1.2), (tr("Тесты", "Tests"), .mac, .success, 41), (tr("Код", "Code"), .server, .success, 2.8),
                                         (tr("Резервная копия", "Backup"), .server, .success, 3.1), (tr("Сборка", "Build"), .server, .success, 96),
                                         (tr("Запуск", "Start"), .server, .success, 14), (tr("Проверка", "Check"), .server, .success, 9.6)]),
                           state: .success)
        let older = DeployRun(projectId: a, serverId: prod.id, trigger: .manual, startedAt: now.addingTimeInterval(-4 * 86400), finishedAt: now.addingTimeInterval(-4 * 86400 + 201),
                              fromCommit: commit("3c4d5e6"), toCommit: commit("0f9e8d7"), toSubject: "Cashier zones", steps: ok.steps, state: .success)
        let failed = DeployRun(projectId: b, serverId: smena.id, trigger: .manual, startedAt: now.addingTimeInterval(-47 * 60), finishedAt: now.addingTimeInterval(-47 * 60 + 58),
                               fromCommit: commit("5d6e7f8"), toCommit: commit("77aa88b"), toSubject: "Geofence: allow 150 m radius",
                               steps: steps([(tr("Подключение", "Connect"), .server, .success, 1.4), (tr("Тесты", "Tests"), .mac, .failed, 56.2), (tr("Код", "Code"), .server, .skipped, nil),
                                             (tr("Обновление", "Update"), .server, .skipped, nil), (tr("Проверка", "Check"), .server, .skipped, nil)],
                                            note: "not ok 14 - geofence rejects a point 151 m away"),
                               state: .failed)
        let running = DeployRun(projectId: a, serverId: prod.id, trigger: .manual, startedAt: now.addingTimeInterval(-73), finishedAt: nil,
                                fromCommit: commit("a1b2c3d"), toCommit: commit("e4f5a6b"), toSubject: "Monthly passes: prorate the first month",
                                steps: steps([(tr("Подключение", "Connect"), .server, .success, 1.1), (tr("Тесты", "Tests"), .mac, .success, 39.4), (tr("Код", "Code"), .server, .success, 2.6),
                                              (tr("Резервная копия", "Backup"), .server, .success, 2.9), (tr("Сборка", "Build"), .server, .running, nil),
                                              (tr("Запуск", "Start"), .server, .pending, nil), (tr("Проверка", "Check"), .server, .pending, nil)]),
                                state: .running)
        failedRun = failed.id
        runningRun = running.id
        successRun = ok.id
        app.deployRuns = [failed, ok, older]

        StepLog.append("""
        $ npm ci && npm test
        77aa88b Geofence: allow 150 m radius
        added 212 packages in 9s

        > server@1.0.0 test
        > node --test test/*.test.ts

        ok 12 - check-in inside the radius
        ok 13 - check-in on the border
        not ok 14 - geofence rejects a point 151 m away
          ---
          error: 'Expected values to be strictly equal: true !== false'
          at: test/geofence.test.ts:48:10
          ...
        # tests 31
        # pass 30
        # fail 1
        not ok 14 - geofence rejects a point 151 m away

        """, to: app.stepLogURL(failed.id, step: 1))
        StepLog.append("ssh smena-vps\n\(tr("Подключение есть.", "Connected."))\n\(tr("Сейчас на сервере: 5d6e7f8 Shift report: totals by restaurant", "On the server now: 5d6e7f8 Shift report: totals by restaurant"))\n",
                       to: app.stepLogURL(failed.id, step: 0))
        StepLog.append("""
        #0 building with "default" instance using docker driver
        #1 [backend internal] load build definition from Dockerfile
        #1 transferring dockerfile: 1.21kB done
        #2 [backend internal] load metadata for docker.io/library/python:3.12-slim
        #2 DONE 0.9s
        #5 [backend 1/6] FROM docker.io/library/python:3.12-slim@sha256:af4e85f1cac90dd3771e47292ea7c8a9830abfabbe4faa5c53f158854c2e819d
        #5 CACHED
        #6 [backend 2/6] WORKDIR /app
        #6 CACHED
        #7 [backend 3/6] COPY requirements.txt .
        #7 DONE 0.1s
        #8 [backend 4/6] RUN pip install --no-cache-dir -r requirements.txt
        #8 2.412 Collecting fastapi==0.115.0
        #8 3.004 Collecting sqlmodel==0.0.22
        #8 11.87 Installing collected packages: sqlmodel, fastapi, uvicorn
        #8 14.20 Successfully installed fastapi-0.115.0 sqlmodel-0.0.22 uvicorn-0.30.6
        #8 DONE 15.1s
        #9 [frontend 3/5] RUN npm ci

        """, to: app.stepLogURL(running.id, step: 4))
        fixtureRunning = running
        app.evaluateSignals()
    }

    static var fixtureRunning: DeployRun?

    /// Puts the half-finished deploy on top of the history, for the "deploy in progress" picture.
    static func showRunning(_ app: AppState) {
        guard let run = fixtureRunning, !app.deployRuns.contains(where: { $0.id == run.id }) else { return }
        app.deployRuns.insert(run, at: 0)
    }

    static func preview() -> DeployPreview {
        let now = Date()
        func line(_ hash: String, _ subject: String, _ hours: Double) -> DeployGit.Line {
            DeployGit.Line(hash: hash + "0000000000000000000000000000000000", subject: subject, author: "Tolib-N8", date: now.addingTimeInterval(-hours * 3600))
        }
        return DeployPreview(target: "e4f5a6b00000000000000000000000000000000", subject: "Monthly passes: prorate the first month",
                             current: "a1b2c3d00000000000000000000000000000000",
                             commits: [line("e4f5a6b", "Monthly passes: prorate the first month", 2), line("c3d2e1f", "Cashier report: export to xlsx", 20),
                                       line("b7a6c5d", "Camera health: reconnect after RTSP timeout", 23)])
    }

    static let log = """
    backend-1   | INFO:     Started server process [1]
    backend-1   | INFO:     Waiting for application startup.
    backend-1   | INFO:     Database initialized successfully
    backend-1   | INFO:     Application startup complete.
    backend-1   | INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
    frontend-1  |    ▲ Next.js 15.1.0
    frontend-1  |    - Local:        http://localhost:3000
    frontend-1  |  ✓ Ready in 412ms
    backend-1   | INFO:     172.18.0.5:51822 - "GET /api/sessions/active HTTP/1.1" 200 OK
    backend-1   | INFO:     172.18.0.5:51822 - "POST /api/events/camera HTTP/1.1" 200 OK
    backend-1   | WARNING:  camera 4 (exit-north): no frames for 12 s, reconnecting
    backend-1   | ERROR:    camera 4 (exit-north): RTSP connection refused (attempt 1 of 5)
    backend-1   | ERROR:    camera 4 (exit-north): RTSP connection refused (attempt 2 of 5)
    backend-1   | INFO:     camera 4 (exit-north): stream restored
    backend-1   | INFO:     172.18.0.5:51840 - "POST /api/payments HTTP/1.1" 201 Created
    db-1        | 2026-10-13 09:14:02.118 UTC [1] LOG:  checkpoint starting: time
    db-1        | 2026-10-13 09:14:04.431 UTC [1] LOG:  checkpoint complete: wrote 23 buffers (0.1%)
    backend-1   | INFO:     172.18.0.5:51902 - "GET /api/tariffs HTTP/1.1" 200 OK
    backend-1   | Traceback (most recent call last):
    backend-1   |   File "/app/app/routers/reports.py", line 88, in export_report
    backend-1   |     rows = build_rows(session, period)
    backend-1   | ValueError: period end is before period start
    backend-1   | INFO:     172.18.0.5:51910 - "GET /api/reports/export?from=2026-10-12&to=2026-10-01 HTTP/1.1" 500 Internal Server Error
    redis-1     | 1:M 13 Oct 2026 09:15:11.004 * Background saving started by pid 42
    redis-1     | 1:M 13 Oct 2026 09:15:11.108 * Background saving terminated with success
    backend-1   | INFO:     172.18.0.5:51944 - "GET /api/sessions/active HTTP/1.1" 200 OK
    """
}
#endif
