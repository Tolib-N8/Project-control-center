import XCTest
@testable import Orbit

/// Reading a server's answer. The samples are real output from an Ubuntu 24.04 machine with Docker Compose 2.40.
final class ServerProbeTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .ru }

    private let composeLines = [
        #"{"Command":"\"python -m http.serv…\"","CreatedAt":"2026-10-13 06:51:06 +0000 UTC","ExitCode":0,"Health":"unhealthy","ID":"d163cc838936","Image":"orbit-toy-web","Labels":"com.docker.compose.service=web","LocalVolumes":"0","Mounts":"","Name":"orbit-toy-web-1","Names":"orbit-toy-web-1","Networks":"orbit-toy_default","Ports":"127.0.0.1:18473-\u003e8000/tcp","Project":"orbit-toy","Publishers":[{"URL":"127.0.0.1","TargetPort":8000,"PublishedPort":18473,"Protocol":"tcp"}],"RunningFor":"52 seconds ago","Service":"web","Size":"0B","State":"running","Status":"Up 52 seconds (unhealthy)"}"#,
        #"{"Command":"\"sleep infinity\"","CreatedAt":"2026-10-13 06:51:06 +0000 UTC","ExitCode":0,"Health":"","ID":"3969546ac1e0","Image":"busybox:1.36","Labels":"com.docker.compose.service=worker","LocalVolumes":"0","Mounts":"","Name":"orbit-toy-worker-1","Names":"orbit-toy-worker-1","Networks":"orbit-toy_default","Ports":"","Project":"orbit-toy","Publishers":[],"RunningFor":"52 seconds ago","Service":"worker","Size":"0B","State":"running","Status":"Up 52 seconds"}"#,
    ]

    func testComposeOneObjectPerLine() {
        let (services, error) = ServerProbe.parseCompose(composeLines)
        XCTAssertNil(error)
        XCTAssertEqual(services.map(\.name), ["web", "worker"])
        XCTAssertEqual(services[0].health, "unhealthy")
        XCTAssertFalse(services[0].ok, "a running but unhealthy container is not fine")
        XCTAssertNil(services[1].health)
        XCTAssertTrue(services[1].ok)
    }

    func testComposeArrayFromOlderVersions() {
        let array = #"[{"Name":"app-db-1","Service":"db","State":"exited","Health":"","ExitCode":1},{"Name":"app-web-1","Service":"web","State":"restarting","Health":""}]"#
        let (services, error) = ServerProbe.parseCompose([array])
        XCTAssertNil(error)
        XCTAssertEqual(services.map(\.state), ["exited", "restarting"])
        XCTAssertTrue(services.allSatisfy { !$0.ok })
        XCTAssertTrue(services[1].restarting)
    }

    func testComposeWarningsDoNotHideContainers() {
        let warning = #"time="2026-10-13T14:42:27+08:00" level=warning msg="The \"STAFF_DOMAIN\" variable is not set. Defaulting to a blank string.""#
        let (services, error) = ServerProbe.parseCompose([warning] + composeLines)
        XCTAssertNil(error)
        XCTAssertEqual(services.count, 2)
    }

    func testComposeErrorsAreExplained() {
        XCTAssertEqual(ServerProbe.parseCompose(["permission denied while trying to connect to the Docker daemon socket", "@@error 1"]).1, "нет прав на Docker у этого пользователя")
        XCTAssertEqual(ServerProbe.parseCompose(["sh: 1: docker: not found", "@@error 127"]).1, "Docker Compose не установлен")
        XCTAssertEqual(ServerProbe.parseCompose(["no configuration file provided: not found", "@@error 14"]).1, "в папке нет docker-compose.yml")
        XCTAssertEqual(ServerProbe.parseCompose([]).1, "контейнеров нет")
    }

    func testSystemdUnit() {
        let (services, error) = ServerProbe.parseSystemd(["Id=smena.service", "LoadState=loaded", "ActiveState=active", "SubState=running", "NRestarts=3"])
        XCTAssertNil(error)
        XCTAssertEqual(services, [ServiceState(name: "smena", state: "active", health: nil, restarts: 3)])
        XCTAssertTrue(services[0].ok)

        let failed = ServerProbe.parseSystemd(["Id=smena.service", "LoadState=loaded", "ActiveState=failed", "SubState=failed", "NRestarts=12"]).0
        XCTAssertFalse(failed[0].ok)
        XCTAssertEqual(ServerProbe.parseSystemd(["Id=nosuch.service", "LoadState=not-found", "ActiveState=inactive", "SubState=dead", "NRestarts=0"]).1, "такой службы нет")
        XCTAssertNotNil(ServerProbe.parseSystemd(["sh: 1: systemctl: not found", "@@error 127"]).1)
    }

    func testWholeAnswer() {
        let answer = """
        Welcome to Ubuntu
        @@load
        0.12 0.20 0.12 5/310 591
        @@cores
        6
        @@mem
        MemTotal:        4010616 kB
        MemAvailable:    3113932 kB
        @@disk
        overlay          234443752 17768952 204692928       8% /
        @@git
        dacefcb67ff479be3d8c60196147092f4e691143
        main
        1791874172\tToy version 1: tabs\tand more
        dirty        2
        @@services
        \(composeLines[0])
        \(composeLines[1])
        @@end
        """
        let f = ServerProbe.parse(answer, runtime: .compose)
        XCTAssertEqual(f.load1, 0.12)
        XCTAssertEqual(f.cores, 6)
        XCTAssertEqual(f.memTotalMB, 3916)
        XCTAssertEqual(f.memAvailableMB, 3040)
        XCTAssertEqual(f.diskTotalKB, 234_443_752)
        XCTAssertEqual(f.diskUsedKB, 17_768_952)
        XCTAssertEqual(f.commit, "dacefcb67ff479be3d8c60196147092f4e691143")
        XCTAssertEqual(f.shortCommit, "dacefcb")
        XCTAssertEqual(f.branch, "main")
        XCTAssertEqual(f.commitSubject, "Toy version 1: tabs\tand more")
        XCTAssertEqual(f.commitDate, Date(timeIntervalSince1970: 1_791_874_172))
        XCTAssertEqual(f.dirty, 2)
        XCTAssertEqual(f.services.count, 2)
        XCTAssertEqual(f.failingServices.map(\.name), ["web"])
        XCTAssertEqual(f.cpuFraction ?? 0, 0.02, accuracy: 0.001)
        XCTAssertEqual(f.memFraction ?? 0, 0.2237, accuracy: 0.001)
        XCTAssertEqual(f.diskFraction ?? 0, 0.0758, accuracy: 0.001)
    }

    func testMissingFolderAndDetachedHead() {
        let missing = ServerProbe.parse("@@load\n0.08 0.1 0.1 1/200 9\n@@cores\n2\n@@mem\n@@disk\n@@git\nnodir\n@@end\n", runtime: .compose)
        XCTAssertTrue(missing.directoryMissing)
        XCTAssertNil(missing.commit)
        XCTAssertEqual(missing.cores, 2)

        let detached = ServerProbe.parse("@@git\nfadaec7000000000000000000000000000000000\nHEAD\n1791874172\tAdd a greeting\ndirty 0\n@@services\n@@end\n", runtime: .none)
        XCTAssertNil(detached.branch, "a detached HEAD has no branch")
        XCTAssertEqual(detached.shortCommit, "fadaec7")

        let noGit = ServerProbe.parse("@@git\n-\n-\n-\ndirty 0\n@@services\n@@end\n", runtime: .none)
        XCTAssertNil(noGit.commit)
        XCTAssertFalse(noGit.directoryMissing)

        // The commit goes on to the local git as an argument; a server can't smuggle an option in its place.
        let hostile = ServerProbe.parse("@@git\n--output=/tmp/x\nmain\n1\tx\ndirty 0\n@@services\n@@end\n", runtime: .none)
        XCTAssertNil(hostile.commit)
    }

    func testScriptIsReadOnlyAndQuotesTheFolder() {
        let server = ServerConfig(name: "x", host: "root@h", directory: "/opt/my app's", runtime: .systemd, unit: "smena")
        let script = ServerProbe.script(server)
        XCTAssertTrue(script.contains(#"D='/opt/my app'\''s'"#))
        XCTAssertTrue(script.contains("systemctl show 'smena'"))
        for forbidden in ["rm ", "restart", " up ", "git pull", "git checkout", "sudo"] {
            XCTAssertFalse(script.contains(forbidden), "the probe must not change anything: \(forbidden)")
        }
    }

    func testSiteAnswer() {
        XCTAssertEqual(ServerProbe.parseSite(stdout: "200 0.142381", stderr: "", status: 0), SiteCheck(code: 200, ms: 142, error: nil))
        XCTAssertTrue(ServerProbe.parseSite(stdout: "401 0,020", stderr: "", status: 0).up, "a login page still means the server is alive")
        let bad = ServerProbe.parseSite(stdout: "502 0.03", stderr: "", status: 0)
        XCTAssertFalse(bad.up)
        XCTAssertEqual(bad.code, 502)
        let refused = ServerProbe.parseSite(stdout: "000 0.000", stderr: "curl: (7) Failed to connect to localhost port 18473", status: 7)
        XCTAssertNil(refused.code)
        XCTAssertEqual(refused.error, "соединение отклонено")
        XCTAssertFalse(refused.up)
        XCTAssertEqual(ServerProbe.parseSite(stdout: "000 0", stderr: "curl: (52) Empty reply from server", status: 52).error, "Empty reply from server")
        XCTAssertEqual(ServerProbe.parseSite(stdout: "000 0", stderr: "", status: 60).error, "ошибка сертификата")
    }

    func testLogCleaning() {
        XCTAssertEqual(LogText.clean("\u{1B}[32mok\u{1B}[0m\r\nstep 1\rstep 2\rdone\nlast"), "ok\ndone\nlast")
        XCTAssertTrue(LogText.isError("backend-1 | ValueError: period end is before period start"))
        XCTAssertTrue(LogText.isError("GET /api HTTP/1.1 500 Internal Server Error"))
        XCTAssertTrue(LogText.isError("Traceback (most recent call last):"))
        XCTAssertFalse(LogText.isError("INFO: Application startup complete."))
    }
}

final class SSHTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .ru }

    private func problem(_ stderr: String, status: Int32 = 255) -> SSHProblem? {
        SSH.problem(ShellResult(status: status, stdout: "", stderr: stderr))?.kind
    }

    /// The messages are what the system ssh printed for each of these situations.
    func testProblemsFromRealMessages() {
        XCTAssertEqual(problem("root@localhost: Permission denied (publickey,password).\n"), .auth)
        XCTAssertEqual(problem("ssh: Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known\n"), .unknownHost)
        XCTAssertEqual(problem("ssh: connect to host localhost port 2222: Connection refused\n"), .refused)
        XCTAssertEqual(problem("Connection timed out during banner exchange\n"), .timeout)
        XCTAssertEqual(problem("ssh: connect to host 198.51.100.24 port 22: Operation timed out\n"), .timeout)
        XCTAssertEqual(problem("@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.\r\n"), .hostKey)
        XCTAssertEqual(problem("kex_exchange_identification: read: Connection reset by peer\n"), .other)
        XCTAssertEqual(problem("", status: -1), .timeout, "our own timeout")
    }

    func testCommandFailureIsNotAnSSHProblem() {
        XCTAssertNil(problem("fatal: not a git repository", status: 128))
        XCTAssertNil(problem("", status: 0))
        XCTAssertNil(problem("bash: line 3: nosuch: command not found", status: 127))
    }

    func testCommandLine() {
        var server = ServerConfig(name: "x", host: " deploy@203.0.113.10 ", port: 2222, directory: "/opt/app")
        let args = SSH.command(server, script: "echo 'hi'")
        XCTAssertTrue(args.contains("BatchMode=yes"), "never waits for a password")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"), "a changed server key is refused")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(args[args.count - 3], "--", "the address can never be read as an option")
        XCTAssertEqual(args[args.count - 2], "deploy@203.0.113.10")
        XCTAssertEqual(args.last, SSH.remoteCommand(script: "echo 'hi'"))
        server.port = 22
        XCTAssertFalse(SSH.arguments(server).contains("-p"))
    }

    /// sshd gives the command to whatever login shell the user has on the server. The same line is run here
    /// through every shell on this Mac — fish included, which rejects `if … then … fi` — and must do the same thing.
    func testRemoteCommandMeansTheSameInEveryLoginShell() throws {
        let script = #"""
        printf '%s\n' 'single '\''quote' "double \"q\" and $((6 * 7))" 'back\\slash' 'star * and ; | & < > ( ) { } [ ] ! # ~ ` $x'
        if [ -n "$ORBIT_NOT_SET" ]; then echo set; else echo "not set"; fi
        echo end
        """#
        let expected = #"""
        single 'quote
        double "q" and 42
        back\\slash
        star * and ; | & < > ( ) { } [ ] ! # ~ ` $x
        not set
        end

        """#
        let remote = SSH.remoteCommand(script: script)
        XCTAssertFalse(remote.contains("\\"), "nothing in the line needs escaping, so no shell can read it differently")
        XCTAssertEqual(remote.filter { $0 == "'" }.count, 2)

        var shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/tcsh", "/bin/dash", "/bin/ksh"]
        if let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"].first(where: FileManager.default.isExecutableFile) { shells.append(fish) }
        var tried: [String] = []
        for shell in shells where FileManager.default.isExecutableFile(atPath: shell) {
            let r = Shell.run(shell, ["-c", remote], timeout: 30)
            XCTAssertTrue(r.stdout.hasSuffix(expected), "\(shell): \(r.stdout) \(r.stderr)")
            XCTAssertEqual(r.status, 0, shell)
            tried.append(shell)
        }
        XCTAssertGreaterThanOrEqual(tried.count, 3, "\(tried)")

        // The exit status of the script is what comes back.
        XCTAssertEqual(Shell.run("/bin/zsh", ["-c", SSH.remoteCommand(script: "echo out; exit 7")], timeout: 30).status, 7)
    }

    func testAnswerSummary() {
        XCTAssertEqual(SSH.summary("fish: Missing end to balance this if statement\nif command -v bash\n^^\nmore\n"), "fish: Missing end to balance this if statement · if command -v bash · ^^")
        XCTAssertEqual(SSH.summary("\n\n"), "")
        XCTAssertEqual(SSH.problem(ShellResult(status: 255, stdout: "", stderr: "kex_exchange_identification: read: Connection reset by peer\nConnection reset by 1.2.3.4 port 22\n"))?.message,
                       "kex_exchange_identification: read: Connection reset by peer · Connection reset by 1.2.3.4 port 22")
    }

    func testKnownHostsNameAndKeyCommands() {
        var server = ServerConfig(name: "x", host: "root@localhost", port: 2222, directory: "/opt/app")
        XCTAssertEqual(SSH.knownHostsName(server), "[localhost]:2222")
        XCTAssertEqual(SSH.forgetHostCommand(server), "ssh-keygen -R '[localhost]:2222'")
        XCTAssertEqual(SSH.installKeyCommand(server, publicKey: "/k/orbit.pub"), "ssh-copy-id -f -i '/k/orbit.pub' -p 2222 'root@localhost'")
        server.port = nil
        server.host = "smena-vps"
        XCTAssertEqual(SSH.knownHostsName(server), "smena-vps")
        XCTAssertEqual(SSH.installKeyCommand(server, publicKey: "/k/orbit.pub"), "ssh-copy-id -f -i '/k/orbit.pub' 'smena-vps'")
    }

    func testSudoHint() {
        XCTAssertNotNil(SSH.sudoHint("sudo: a terminal is required to read the password; either use the -S option"))
        XCTAssertNotNil(SSH.sudoHint("sudo: a password is required"))
        XCTAssertNil(SSH.sudoHint("npm ERR! code 1"))
    }
}

final class ServerConfigTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .ru }

    func testOldConfigWithoutServersStillLoads() throws {
        let json = #"{"onboarded":true,"projects":[{"path":"/p/a","name":"a","colorIndex":0,"archived":false,"workDays":[]}]}"#
        let config = try JSONDecoder().decode(OrbitConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.projects[0].servers)
        XCTAssertTrue(config.rules.isEmpty == false)
    }

    func testServerRoundTripAndForwardCompatibility() throws {
        let server = ServerConfig(name: "Основной", host: "root@1.2.3.4", port: 2222, directory: "/opt/app", url: "example.ru", branch: "release",
                                  runtime: .systemd, unit: "app", steps: [.code(), DeployStep(name: "Сборка", command: "make", place: .mac)], autoDeploy: true)
        let data = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: data), server)

        // A config from a version that knew fewer fields.
        let sparse = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"name":"x","host":"h","directory":"/d","steps":[{"name":"Run","command":"make"}]}"#.utf8))
        XCTAssertEqual(sparse.branch, "main")
        XCTAssertTrue(sparse.monitor)
        XCTAssertFalse(sparse.autoDeploy, "automatic deploys are never on by default")
        XCTAssertEqual(sparse.steps[0].place, .server)
        XCTAssertTrue(sparse.steps[0].enabled)
    }

    func testSiteAddress() {
        XCTAssertEqual(ServerConfig.normalizedURL("smena.example.ru"), "https://smena.example.ru")
        XCTAssertEqual(ServerConfig.normalizedURL(" http://198.51.100.24:8080 "), "http://198.51.100.24:8080")
        XCTAssertEqual(ServerConfig.normalizedURL("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(ServerConfig.normalizedURL("198.51.100.24:8080"), "http://198.51.100.24:8080")
        XCTAssertNil(ServerConfig.normalizedURL("file:///etc/passwd"))
        XCTAssertNil(ServerConfig.normalizedURL("-o /tmp/x"))
        XCTAssertNil(ServerConfig.normalizedURL(""))
        XCTAssertNil(ServerConfig.normalizedURL(nil))
    }

    func testValidation() {
        var s = ServerConfig(name: "x", host: "root@1.2.3.4", directory: "/opt/app")
        XCTAssertNil(s.problem)
        s.host = "-oProxyCommand=evil"
        XCTAssertNotNil(s.problem, "an address can't start with a dash")
        s.host = "root@1.2.3.4 extra"
        XCTAssertNotNil(s.problem)
        s.host = "root@1.2.3.4"
        s.directory = "app"
        XCTAssertNotNil(s.problem)
        s.directory = "/opt/app"
        s.runtime = .systemd
        XCTAssertNotNil(s.problem, "a service needs its name")
        s.unit = "app"
        XCTAssertNil(s.problem)
        s.url = "not a link"
        XCTAssertNotNil(s.problem)
    }

    func testTemplatesFromProjectFiles() {
        func detect(_ files: [String: String]) -> (runtime: ServerRuntime, steps: [DeployStep]) {
            DeployTemplate.detect(projectPath: "/p", fileExists: { files[String($0.dropFirst(3))] != nil }, read: { files[String($0.dropFirst(3))].map { Data($0.utf8) } })
        }
        let yaml = "services:\n  db:\n    image: postgres:15-alpine\n  web:\n    build: .\n"
        let compose = detect(["docker-compose.yml": yaml, "package.json": #"{"scripts":{"test":"node --test"}}"#, "package-lock.json": ""])
        XCTAssertEqual(compose.runtime, .compose)
        XCTAssertEqual(compose.steps.map(\.kind), [.command, .backup, .code, .command, .command], "the backup comes before anything changes the server")
        XCTAssertEqual(compose.steps.map(\.place), [.mac, .server, .server, .server, .server])
        XCTAssertEqual(compose.steps[0].command, "npm ci && npm test")
        XCTAssertTrue(compose.steps[1].command.contains("pg_dumpall"))
        XCTAssertEqual(compose.steps.suffix(2).map(\.command), ["docker compose build", "docker compose up -d"])

        let script = detect(["deploy/update.sh": "", "package.json": #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#])
        XCTAssertEqual(script.runtime, .systemd)
        XCTAssertEqual(script.steps.map(\.kind), [.backup, .code, .command])
        XCTAssertEqual(script.steps.map(\.command), ["", "", "sudo bash deploy/update.sh"])
        XCTAssertFalse(script.steps[1].enabled, "the script pulls the code itself")

        let bare = detect([:])
        XCTAssertEqual(bare.runtime, .none)
        XCTAssertEqual(bare.steps.map(\.kind), [.backup, .code, .command])
        XCTAssertFalse(bare.steps.last?.enabled ?? true)
    }

    func testDangerousCommandsAreFlagged() {
        XCTAssertNotNil(DeployLint.warning("docker compose down -v"))
        XCTAssertNotNil(DeployLint.warning("docker compose down --volumes && docker compose up -d"))
        XCTAssertNotNil(DeployLint.warning("docker system prune -af"))
        XCTAssertNotNil(DeployLint.warning("docker volume prune -f"))
        XCTAssertNotNil(DeployLint.warning("rm -rf /"))
        XCTAssertNotNil(DeployLint.warning("git reset --hard origin/main"))
        XCTAssertNotNil(DeployLint.warning("psql -c 'DROP DATABASE app'"))
        XCTAssertNil(DeployLint.warning("docker compose down"))
        XCTAssertNil(DeployLint.warning("docker compose up -d --build"))
        XCTAssertNil(DeployLint.warning("docker compose build && docker image prune -f"))
        XCTAssertNil(DeployLint.warning("rm -rf ./dist && npm run build"))
        XCTAssertNil(DeployLint.warning("sudo bash deploy/update.sh"))
    }

    func testUptime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var samples = (0..<100).map { ServerSample(t: now.addingTimeInterval(-Double($0) * 600), up: true, ms: 100 + $0) }
        XCTAssertEqual(Uptime.share(samples, from: now.addingTimeInterval(-86400 * 7)), 1)
        samples[3].up = false
        XCTAssertEqual(Uptime.share(samples, from: now.addingTimeInterval(-86400 * 7)) ?? 0, 0.99, accuracy: 0.0001)
        XCTAssertNil(Uptime.share(Array(samples.prefix(5)), from: now.addingTimeInterval(-86400)), "five checks say nothing yet")
        XCTAssertEqual(Uptime.text(1), "100 %")
        XCTAssertEqual(Uptime.text(0.99999), "99,9 %", "an outage never rounds up to a clean hundred")
        XCTAssertEqual(Uptime.text(0.9982), "99,8 %")

        let strip = Uptime.strip(samples, hours: 24, count: 48, now: now)
        XCTAssertEqual(strip.count, 48)
        XCTAssertEqual(strip.last ?? nil, false, "the failed check half an hour ago sits in the newest slice")
        XCTAssertEqual(strip[46], true)
        XCTAssertEqual(strip.filter { $0 == false }.count, 1)
        XCTAssertTrue(strip.prefix(14).allSatisfy { $0 == nil }, "nothing was checked before the first sample")
        XCTAssertEqual(Uptime.averageMs([ServerSample(t: now, up: true, ms: 100), ServerSample(t: now, up: false, ms: nil), ServerSample(t: now, up: true, ms: 200)], from: now.addingTimeInterval(-1)), 150)
    }

    func testOverallState() {
        let server = ServerConfig(name: "x", host: "h", directory: "/d", url: "https://example.ru", runtime: .compose)
        let healthy = HostFacts(commit: "abc1234", services: [ServiceState(name: "web", state: "running")])
        XCTAssertEqual(ServerStatus().overall(server), .unknown)
        XCTAssertEqual(ServerStatus(site: SiteCheck(code: 200, ms: 10), host: healthy).overall(server), .up)
        XCTAssertEqual(ServerStatus(site: SiteCheck(code: nil, error: "x"), siteFailures: 1, host: healthy).overall(server), .degraded, "one failed check isn't an outage yet")
        XCTAssertEqual(ServerStatus(site: SiteCheck(code: nil, error: "x"), siteFailures: 2, host: healthy).overall(server), .down)
        XCTAssertEqual(ServerStatus(site: SiteCheck(code: 200, ms: 10), host: HostFacts(services: [ServiceState(name: "db", state: "exited")])).overall(server), .degraded)
        XCTAssertEqual(ServerStatus(site: SiteCheck(code: 200, ms: 10), siteCheckedAt: Date(), sshProblem: .auth, sshFailures: 3).overall(server), .degraded, "the site is up; only SSH is closed")

        var noSite = server
        noSite.url = nil
        XCTAssertEqual(ServerStatus(hostCheckedAt: Date(), sshProblem: .timeout, sshFailures: 2).overall(noSite), .down)
        XCTAssertEqual(ServerStatus(hostCheckedAt: Date(), sshProblem: .auth, sshFailures: 2).overall(noSite), .noAccess)
        XCTAssertEqual(ServerStatus(host: healthy).overall(noSite), .up)
    }

    func testElapsedText() {
        XCTAssertEqual(Elapsed.text(0.2), "<1 с")
        XCTAssertEqual(Elapsed.text(12.4), "12 с")
        XCTAssertEqual(Elapsed.text(108), "1 мин 48 с")
        XCTAssertEqual(Elapsed.text(120), "2 мин")
    }
}

final class DeployTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .ru }

    private func server() -> ServerConfig {
        ServerConfig(name: "Основной", host: "root@h", directory: "/opt/app", url: "https://example.ru", branch: "release", runtime: .compose,
                     steps: [DeployStep(name: "Тесты", command: "npm test", place: .mac), .backup(command: "make dump"), .code(),
                             DeployStep(name: "Выключено", command: "echo off", enabled: false),
                             DeployStep(name: "Пусто", command: "  "),
                             DeployStep(name: "Запуск", command: "docker compose up -d --build")])
    }

    func testPlan() {
        let plan = DeployPipeline.plan(server(), target: "abc123", previous: "old456")
        XCTAssertEqual(plan.map(\.run.name), ["Подключение", "Тесты", "Резервная копия", "Код", "Запуск", "Проверка"], "disabled and empty steps are left out")
        XCTAssertEqual(plan.map(\.run.place), [.server, .mac, .server, .server, .server, .server])
        XCTAssertEqual(plan[0].action, .connect)
        XCTAssertEqual(plan[1].action, .local("npm test"))
        XCTAssertEqual(plan[5].action, .verify)
        guard case .remote(let backup) = plan[2].action, case .remote(let code) = plan[3].action, case .remote(let start) = plan[4].action else { return XCTFail("server steps expected") }
        XCTAssertTrue(backup.hasPrefix("set -e\ncd '/opt/app'\n"))
        XCTAssertTrue(backup.contains("\nmake dump\n"))
        XCTAssertTrue(backup.contains("export ORBIT_BACKUP_DIR"))
        XCTAssertFalse(backup.contains("git merge"), "the backup changes nothing in the project")
        XCTAssertTrue(code.hasPrefix("set -e\ncd '/opt/app'\n"), "the first failing command stops the step")
        XCTAssertTrue(code.contains("git merge --ff-only 'abc123'"), "exactly the previewed commit, fast-forward only")
        XCTAssertTrue(code.contains("git checkout -q 'release'"))
        XCTAssertFalse(code.contains("reset --hard"))
        XCTAssertTrue(start.contains("export ORBIT_COMMIT='abc123'"))
        XCTAssertTrue(start.contains("export ORBIT_PREVIOUS='old456'"))
        XCTAssertTrue(start.contains("export ORBIT_BRANCH='release'"))
        XCTAssertTrue(start.hasSuffix("docker compose up -d --build"))
    }

    func testRollbackSkipsMacStepsAndGoesBackToTheCommit() {
        let plan = DeployPipeline.rollback(server(), to: "old456", previous: "abc123")
        XCTAssertEqual(plan.map(\.run.name), ["Подключение", "Резервная копия", "Код назад", "Запуск", "Проверка"], "going back is a change too")
        guard case .remote(let back) = plan[2].action else { return XCTFail() }
        XCTAssertTrue(back.contains("git checkout -q --detach 'old456'"))
        XCTAssertFalse(back.contains("merge"))
    }

    func testBackupStepCanBeAddedAndSwitchedBackOn() {
        var bare = ServerConfig(name: "x", host: "h", directory: "/d", steps: [DeployStep(name: "Тесты", command: "npm test", place: .mac), .code(), DeployStep(name: "Запуск", command: "up")])
        XCTAssertFalse(bare.hasBackup)
        bare.addBackup(.backup(command: "dump"))
        XCTAssertEqual(bare.steps.map(\.kind), [.command, .backup, .code, .command], "after the checks on the Mac, before the code")
        XCTAssertTrue(bare.hasBackup)
        bare.steps[1].enabled = false
        XCTAssertFalse(bare.hasBackup)
        bare.addBackup()
        XCTAssertEqual(bare.steps.filter { $0.kind == .backup }.count, 1, "never a second one")
        XCTAssertEqual(bare.steps[1].command, "dump", "the user's command survives")
        XCTAssertTrue(bare.hasBackup)

        var scriptOnly = ServerConfig(name: "x", host: "h", directory: "/d", steps: [DeployStep(name: "Обновление", command: "sudo bash deploy/update.sh")])
        scriptOnly.addBackup()
        XCTAssertEqual(scriptOnly.steps.map(\.kind), [.backup, .command])
    }

    func testDatabaseDumpSuggestedFromCompose() {
        let yaml = """
        # ParkingFlow
        services:
          db:
            image: postgres:15-alpine
            container_name: parkingflow-db
            environment:
              POSTGRES_USER: ${POSTGRES_USER}
          redis:
            image: redis:7-alpine
          backend:
            build:
              context: ./backend
            image: parkingflow-backend:latest
          legacy:
            image: "docker.io/library/mysql:8"
          maria:
            image: mariadb:11
        volumes:
          db_data:
        networks:
          internal:
        """
        XCTAssertEqual(BackupTemplate.services(compose: yaml).map(\.name), ["db", "redis", "backend", "legacy", "maria"])
        let lines = BackupTemplate.command(compose: yaml).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "one dump per database, nothing for redis or the app itself")
        XCTAssertEqual(lines[0], #"docker compose exec -T db sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' | gzip > "$ORBIT_BACKUP_DIR/db.sql.gz""#)
        XCTAssertTrue(lines[1].contains("exec -T legacy") && lines[1].contains("mysqldump"))
        XCTAssertTrue(lines[2].contains("exec -T maria") && lines[2].contains("mariadb-dump"))
        XCTAssertEqual(BackupTemplate.command(compose: "services:\n  app:\n    image: smena:latest\n  caddy:\n    image: caddy:2-alpine\n"), "", "no database container — nothing to suggest")
        XCTAssertEqual(BackupTemplate.command(compose: ""), "")
        XCTAssertEqual(BackupTemplate.command(compose: "services:\n  \"bad name; rm -rf\":\n    image: postgres:16\n"), "", "a service name never ends up in a command unchecked")
    }

    func testOldConfigWithAnUnknownStepKindStillLoads() throws {
        let server = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"name":"x","host":"h","directory":"/d","steps":[{"kind":"something-new","name":"Run","command":"make"}]}"#.utf8))
        XCTAssertEqual(server.steps.first?.kind, .command)
    }

    func testLocalScriptWorksInACopy() {
        let script = DeployPipeline.localScript(projectPath: "/p/my app", workDir: "/w/copy", branch: "release", target: "abc123", command: "npm test", env: ["ORBIT_COMMIT": "abc123"])
        XCTAssertTrue(script.contains("P='/p/my app'"))
        XCTAssertTrue(script.contains("git checkout -q -f --detach 'abc123'"))
        XCTAssertTrue(script.contains(#"git fetch -q "$P" 'refs/remotes/origin/release'"#))
        XCTAssertTrue(script.hasSuffix("export ORBIT_COMMIT='abc123'\nnpm test"))
        // Everything that changes files happens after `cd "$W"`, never in the project folder.
        let beforeCd = script.components(separatedBy: "cd \"$W\"")[0]
        XCTAssertFalse(beforeCd.contains("checkout -q -f"))
        XCTAssertFalse(beforeCd.contains("git clean"))
    }

    private func planned(_ names: [String]) -> [PlannedStep] {
        names.map { PlannedStep(run: StepRun(name: $0, place: .server), action: .remote($0)) }
    }

    @MainActor
    private func run(_ names: [String], cancelAfter: Int? = nil, outcome: @escaping (String) -> StepOutcome) async -> (state: DeployState, steps: [StepRun], executed: [String]) {
        let steps = planned(names)
        var result = steps.map(\.run), executed: [String] = [], done = 0
        let state = await DeployEngine.run(steps, isCancelled: { cancelAfter.map { done >= $0 } ?? false },
                                           execute: { _, step in
                                               executed.append(step.run.name)
                                               done += 1
                                               return outcome(step.run.name)
                                           },
                                           update: { i, step in result[i] = step })
        return (state, result, executed)
    }

    @MainActor
    func testAllStepsSucceed() async {
        let r = await run(["a", "b", "c"]) { _ in .success }
        XCTAssertEqual(r.state, .success)
        XCTAssertEqual(r.steps.map(\.state), [.success, .success, .success])
        XCTAssertEqual(r.executed, ["a", "b", "c"])
        XCTAssertTrue(r.steps.allSatisfy { $0.seconds != nil && $0.startedAt != nil })
    }

    @MainActor
    func testFailureStopsTheChain() async {
        let r = await run(["connect", "tests", "code", "start"]) { $0 == "tests" ? .failed("1 failing") : .success }
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(r.steps.map(\.state), [.success, .failed, .skipped, .skipped])
        XCTAssertEqual(r.executed, ["connect", "tests"], "nothing touches the server after a failed check")
        XCTAssertEqual(r.steps[1].note, "1 failing")
    }

    @MainActor
    func testStopBetweenStepsAndDuringAStep() async {
        let between = await run(["a", "b", "c"], cancelAfter: 1) { _ in .success }
        XCTAssertEqual(between.state, .cancelled)
        XCTAssertEqual(between.steps.map(\.state), [.success, .cancelled, .skipped])
        XCTAssertEqual(between.executed, ["a"])

        let during = await run(["a", "b", "c"]) { $0 == "b" ? .cancelled : .success }
        XCTAssertEqual(during.state, .cancelled)
        XCTAssertEqual(during.steps.map(\.state), [.success, .cancelled, .skipped])
    }

    func testFailureReasonAndHints() {
        let node = """
        ✖ page has a version (1.043ms)
          AssertionError [ERR_ASSERTION]: The input did not match the regular expression /toy version \\d+/. Input:

              at TestContext.<anonymous> (/work/test/basic.test.js:5:10)
              at Test.run (node:internal/test_runner/test:1402:25) {
            generatedMessage: true,
            code: 'ERR_ASSERTION',
            diff: 'simple'
          }
        """
        XCTAssertEqual(StepLog.reason(in: node), "AssertionError [ERR_ASSERTION]: The input did not match the regular expression /toy version \\d+/. Input:")
        XCTAssertEqual(StepLog.reason(in: "#8 0.201 compiling assets\n------\nfailed to solve: process \"/bin/sh -c exit 7\" did not complete successfully: exit code: 7\n"),
                       "failed to solve: process \"/bin/sh -c exit 7\" did not complete successfully: exit code: 7")
        XCTAssertEqual(StepLog.reason(in: "step one\nstep two\n}\n"), "step two", "falls back to the last line that says something")
        XCTAssertNil(StepLog.reason(in: "\n\n"))

        let dirty = "error: Your local changes to the following files would be overwritten by merge:\n\tindex.html\nPlease commit your changes or stash them before you merge.\nAborting\n"
        XCTAssertTrue(StepLog.hint(in: dirty)?.contains("git stash") ?? false)
        XCTAssertNotNil(StepLog.hint(in: "fatal: Not possible to fast-forward, aborting."))
        XCTAssertNotNil(StepLog.hint(in: "fatal: Could not read from remote repository."))
        XCTAssertNotNil(StepLog.hint(in: "write /var/lib/docker/tmp/x: no space left on device"))
        XCTAssertNotNil(StepLog.hint(in: "sudo: a terminal is required to read the password"))
        XCTAssertNil(StepLog.hint(in: "npm ERR! Test failed."))
    }

    private static let current = "aaa", tip = "bbb"
    private static let reachable = ServerStatus(host: HostFacts(commit: current))

    func testAutoDeployDecision() {
        var s = ServerConfig(name: "x", host: "h", directory: "/d", autoDeploy: true)
        let current = Self.current, tip = Self.tip
        func decide(_ status: ServerStatus? = Self.reachable, tip: String? = Self.tip, runs: [DeployRun] = [], deploying: Bool = false, online: Bool = true) -> Bool {
            AutoDeploy.decide(server: s, status: status, remoteTip: tip, runs: runs, deploying: deploying, online: online)
        }
        func ran(_ commit: String, _ state: DeployState, server: UUID? = nil) -> DeployRun {
            DeployRun(projectId: "/p", serverId: server ?? s.id, trigger: .auto, startedAt: Date(), toCommit: commit, steps: [], state: state)
        }
        XCTAssertTrue(decide(), "a new commit on the branch goes out")
        XCTAssertFalse(decide(tip: current), "nothing new")
        XCTAssertFalse(decide(tip: nil), "origin didn't answer")
        XCTAssertFalse(decide(deploying: true))
        XCTAssertFalse(decide(online: false), "the Mac is offline")
        XCTAssertFalse(decide(nil), "the server hasn't been checked")
        XCTAssertFalse(decide(ServerStatus(host: HostFacts(commit: current), sshProblem: .timeout)), "the server can't be reached")
        XCTAssertFalse(decide(ServerStatus(host: HostFacts())), "what the server runs is unknown")
        XCTAssertFalse(decide(runs: [ran(tip, .failed)]), "a commit that failed is not retried")
        XCTAssertFalse(decide(runs: [ran(tip, .cancelled)]), "nor one the user stopped")
        XCTAssertFalse(decide(runs: [ran(tip, .success)]), "nor one that went out and was rolled back")
        XCTAssertTrue(decide(runs: [ran("older", .failed)]), "an older failure doesn't block a newer commit")
        XCTAssertTrue(decide(runs: [ran(tip, .failed, server: UUID())]), "another server's history doesn't count")
        s.autoDeploy = false
        XCTAssertFalse(decide(), "only where the user switched it on")
    }

    func testCommitLines() {
        let lines = DeployGit.parseLines("fadaec7aa\t1791874172\tTolib N8\tAdd a greeting\twith a tab\n1b7f1adbb\t1791870000\tTest\tToy version 2\nbroken line\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].subject, "Add a greeting\twith a tab")
        XCTAssertEqual(lines[0].author, "Tolib N8")
        XCTAssertEqual(lines[0].shortHash, "fadaec7")
        XCTAssertEqual(lines[1].date, Date(timeIntervalSince1970: 1_791_870_000))
    }
}

/// The parts that only make sense against real git: an origin, a project and a clean copy for the Mac steps.
final class DeployGitTests: XCTestCase {
    private var root: URL!
    private var project: String { root.appendingPathComponent("project").path }

    private func git(_ dir: String, _ args: String...) -> ShellResult {
        Shell.run("/usr/bin/git", ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + args)
    }

    private func commit(_ text: String, _ message: String) -> String {
        try? text.write(toFile: project + "/page.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(git(project, "add", "-A").ok)
        XCTAssertTrue(git(project, "commit", "-q", "-m", message).ok)
        return git(project, "rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-deploy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin.git").path
        XCTAssertTrue(Shell.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", origin]).ok)
        XCTAssertTrue(Shell.run("/usr/bin/git", ["clone", "-q", origin, project]).ok)
        _ = git(project, "checkout", "-q", "-b", "main")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOriginTipBehindAndOutgoingCommits() {
        let first = commit("one", "First")
        XCTAssertTrue(git(project, "push", "-q", "origin", "main").ok)
        XCTAssertEqual(DeployGit.remoteTip(project, branch: "main"), first)
        XCTAssertNil(DeployGit.remoteTip(project, branch: "no-such-branch"))

        // Someone else pushes two commits; this clone hasn't fetched them yet.
        let other = root.appendingPathComponent("other").path
        XCTAssertTrue(Shell.run("/usr/bin/git", ["clone", "-q", root.appendingPathComponent("origin.git").path, other]).ok)
        for (text, message) in [("two", "Second"), ("three", "Third")] {
            try? text.write(toFile: other + "/page.txt", atomically: true, encoding: .utf8)
            XCTAssertTrue(git(other, "commit", "-q", "-am", message).ok)
        }
        XCTAssertTrue(git(other, "push", "-q", "origin", "main").ok)
        let tip = git(other, "rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(DeployGit.remoteTip(project, branch: "main"), tip, "asked over the wire, without fetching")
        XCTAssertNil(DeployGit.behind(project, from: first, to: tip), "unknown until the commits are here")
        XCTAssertEqual(DeployGit.fetch(project, branch: "main").tip, tip)
        XCTAssertEqual(DeployGit.behind(project, from: first, to: tip), 2)
        XCTAssertEqual(DeployGit.commits(project, from: first, to: tip)?.map(\.subject), ["Third", "Second"])
        XCTAssertEqual(DeployGit.subject(project, commit: tip), "Third")
        XCTAssertEqual(git(project, "rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines), first, "the fetch doesn't move the working branch")
    }

    func testMacStepRunsInACleanCopyOfTheCommit() throws {
        let deployed = commit("deployed", "Deployed")
        XCTAssertTrue(git(project, "push", "-q", "origin", "main").ok)
        XCTAssertEqual(DeployGit.fetch(project, branch: "main").tip, deployed)
        // Work in progress in the project folder must neither leak into the check nor be lost.
        try "uncommitted".write(toFile: project + "/page.txt", atomically: true, encoding: .utf8)
        try "scratch".write(toFile: project + "/notes.txt", atomically: true, encoding: .utf8)

        let work = root.appendingPathComponent("work/copy").path
        let script = DeployPipeline.localScript(projectPath: project, workDir: work, branch: "main", target: deployed,
                                                command: "cat page.txt > \"$ORBIT_OUT\"; test ! -e notes.txt", env: ["ORBIT_OUT": root.appendingPathComponent("seen.txt").path])
        let log = root.appendingPathComponent("step.log")
        XCTAssertEqual(StepProcess().run("/bin/zsh", ["-c", script], log: log, timeout: 60), 0, LogText.tail(log))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("seen.txt"), encoding: .utf8), "deployed")
        XCTAssertEqual(try String(contentsOfFile: project + "/page.txt", encoding: .utf8), "uncommitted", "the project folder is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/notes.txt"))
        XCTAssertTrue(LogText.tail(log).contains("Deployed"))

        // The copy is reused: the next commit lands in the same folder, and a failing command fails the step.
        try FileManager.default.removeItem(atPath: project + "/notes.txt")
        _ = git(project, "checkout", "-q", "--", "page.txt")
        let next = commit("next", "Next")
        XCTAssertTrue(git(project, "push", "-q", "origin", "main").ok)
        XCTAssertEqual(DeployGit.fetch(project, branch: "main").tip, next)
        let failing = DeployPipeline.localScript(projectPath: project, workDir: work, branch: "main", target: next, command: "grep -q deployed page.txt", env: [:])
        XCTAssertNotEqual(StepProcess().run("/bin/zsh", ["-c", failing], log: log, timeout: 60), 0)
    }

    /// The backup script for real, in a throwaway folder: what gets saved, what stops the deploy, what is pruned.
    func testBackupScriptSavesChecksAndPrunes() throws {
        let home = root.appendingPathComponent("backups").path
        try "SECRET=1\n".write(toFile: project + "/.env", atomically: true, encoding: .utf8)
        try "services: {}\n".write(toFile: project + "/docker-compose.yml", atomically: true, encoding: .utf8)
        let head = commit("one", "First")
        let server = ServerConfig(name: "x", host: "h", directory: project)
        func run(_ command: String, shell: String = "/bin/bash") -> (status: Int32, log: String) {
            let log = root.appendingPathComponent("backup-\(UUID().uuidString).log")
            let script = DeployPipeline.remoteScript(server, body: DeployPipeline.backupScript(command: command, keep: 3), env: [:])
            let status = StepProcess().run(shell, ["-c", script], env: ["ORBIT_BACKUP_HOME": home, "ORBIT_PIDFILE": ""], log: log, timeout: 60)
            return (status, LogText.tail(log))
        }
        func backups() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: home + "/project")) ?? []).sorted() }

        // Older backups, to see the pruning; the newest three (with the new one) must stay.
        for (i, name) in ["20260101-000000-aaa", "20260102-000000-bbb", "20260103-000000-ccc", "20260104-000000-ddd"].enumerated() {
            let dir = home + "/project/" + name
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try "old".write(toFile: dir + "/db.sql.gz", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i - 10) * 3600)], ofItemAtPath: dir)
        }

        let ok = run("echo 'CREATE TABLE t' | gzip > \"$ORBIT_BACKUP_DIR/db.sql.gz\"")
        XCTAssertEqual(ok.status, 0, ok.log)
        let kept = backups()
        XCTAssertEqual(kept.count, 3, "only the newest three stay: \(kept)")
        XCTAssertEqual(Array(kept.prefix(2)), ["20260103-000000-ccc", "20260104-000000-ddd"])
        let fresh = home + "/project/" + kept[2]
        XCTAssertTrue(kept[2].hasSuffix("-" + head.prefix(7)), "named after the version it protects: \(kept[2])")
        XCTAssertEqual(try String(contentsOfFile: fresh + "/commit.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertEqual(try String(contentsOfFile: fresh + "/.env", encoding: .utf8), "SECRET=1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh + "/docker-compose.yml"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh + "/db.sql.gz"))
        let mode = try FileManager.default.attributesOfItem(atPath: fresh + "/.env")[.posixPermissions] as? Int
        XCTAssertEqual((mode ?? 0) & 0o077, 0, "settings with passwords are readable by the owner only")
        XCTAssertTrue(ok.log.contains("Резервная копия сохранена:"))

        let before = backups().count
        let empty = run(": > \"$ORBIT_BACKUP_DIR/db.sql\"")
        XCTAssertNotEqual(empty.status, 0, "an empty dump stops the deploy")
        XCTAssertTrue(empty.log.contains("Резервная копия пустая:"), empty.log)

        // The dump fails but gzip after it succeeds: the step must still fail (pipefail).
        let broken = run("sh -c 'echo partial; exit 3' | gzip > \"$ORBIT_BACKUP_DIR/db.sql.gz\"")
        XCTAssertNotEqual(broken.status, 0, "a failed dump is not hidden by the pipe: \(broken.log)")
        XCTAssertEqual(backups().count, before, "a failed backup leaves nothing half-made behind and deletes nothing older")
        XCTAssertTrue(broken.log.contains("на сервере ничего не изменено"), broken.log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh + "/db.sql.gz"), "the good backup from a moment ago is still there")

        let plain = run("")
        XCTAssertEqual(plain.status, 0, plain.log)
        XCTAssertTrue(plain.log.contains("Команды для базы данных нет"))
        XCTAssertEqual(try String(contentsOfFile: project + "/page.txt", encoding: .utf8), "one", "the project itself is untouched")
        XCTAssertEqual(git(project, "status", "--porcelain", "--untracked-files=no").stdout, "")
    }

    func testStoppingAStepKillsWhatItStarted() {
        let log = root.appendingPathComponent("slow.log")
        let marker = root.appendingPathComponent("finished").path
        let process = StepProcess()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { process.cancel() }
        let status = process.run("/bin/zsh", ["-c", "(sleep 20; touch \(Shell.quote(marker))) & wait"], log: log, timeout: 60)
        XCTAssertNotEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "stopped long before the command would have finished")
        XCTAssertTrue(process.cancelled)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(Shell.run("/usr/bin/pgrep", ["-f", marker]).ok, "the child of the shell is gone too")
        XCTAssertEqual(process.run("/bin/echo", ["again"], log: log, timeout: 5), -2, "a stopped deploy starts nothing more")
    }
}

final class HousekeepingTests: XCTestCase {
    func testOnlyStagingFoldersAreLeftovers() throws {
        let updates = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: updates) }
        for name in ["staging-1.1.1/Orbit.app", "staging-2.0.0/Orbit.app", "previous/Orbit.app"] {
            try FileManager.default.createDirectory(at: updates.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "log".write(to: updates.appendingPathComponent("update.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Updater.staleStaging(in: updates).map(\.lastPathComponent), ["staging-1.1.1", "staging-2.0.0"], "the backup copy and the log stay")
        XCTAssertEqual(Updater.staleStaging(in: updates, keeping: "2.0.0").map(\.lastPathComponent), ["staging-1.1.1"])
        XCTAssertTrue(Updater.staleStaging(in: updates.appendingPathComponent("missing")).isEmpty)
    }

    func testNothingIsPostedFromTests() {
        XCTAssertFalse(Notifier.enabled, "made-up data from tests and snapshot runs must never reach Notification Center")
    }
}

final class ServerSignalTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .ru }

    private let project = ProjectSnapshot(config: ProjectConfig(path: "/p/a", name: "a", colorIndex: 0), repo: RepoStatus(), sessions: [])
    private let server = ServerConfig(name: "Основной", host: "h", directory: "/d", url: "https://example.ru", runtime: .compose)

    private func signals(_ status: ServerStatus?, run: DeployRun? = nil, existing: [Signal] = [], server: ServerConfig? = nil) -> [Signal] {
        var config = OrbitConfig()
        config.rules = [.serverDown, .serverService, .serverDisk, .deployFailed].map { SignalRuleConfig(kind: $0) }
        let s = server ?? self.server
        return SignalEngine.evaluate(config: config, projects: [project], plans: [], existing: existing,
                                     servers: ["/p/a": [ServerSnapshot(config: s, status: status, lastRun: run)]])
    }

    func testNewRulesAreOnByDefault() {
        let config = OrbitConfig()
        for kind in [SignalRuleKind.serverDown, .serverService, .serverDisk, .deployFailed] {
            XCTAssertTrue(config.rule(kind).enabled, "\(kind)")
        }
    }

    func testSiteDownNeedsTwoChecksAndResolves() {
        let healthy = HostFacts(services: [ServiceState(name: "web", state: "running")])
        XCTAssertTrue(signals(ServerStatus(site: SiteCheck(code: nil, error: "нет ответа"), siteFailures: 1, host: healthy)).isEmpty, "one blip isn't an outage")
        let raised = signals(ServerStatus(site: SiteCheck(code: 502), siteFailures: 2, host: healthy))
        XCTAssertEqual(raised.map(\.kind), [.serverDown])
        XCTAssertEqual(raised[0].severity, .critical)
        XCTAssertEqual(raised[0].title, "Сервер «Основной» не отвечает")
        XCTAssertEqual(raised[0].serverId, server.id)
        XCTAssertEqual(raised[0].metrics.first?.value, "502")

        let after = signals(ServerStatus(site: SiteCheck(code: 200, ms: 20), host: healthy), existing: raised)
        XCTAssertEqual(after.first?.state, .resolved)
        XCTAssertEqual(after.first?.resolution, "сервер снова отвечает")
    }

    func testSSHProblems() {
        let closed = signals(ServerStatus(site: SiteCheck(code: 200, ms: 20), sshProblem: .auth, sshFailures: 2))
        XCTAssertEqual(closed.map(\.severity), [.warning], "the site works; only Orbit can't get in")
        XCTAssertEqual(closed[0].title, "Нет доступа по SSH к «Основной»")

        var noSite = server
        noSite.url = nil
        let gone = signals(ServerStatus(sshProblem: .timeout, sshFailures: 2), server: noSite)
        XCTAssertEqual(gone.map(\.severity), [.critical])
        XCTAssertTrue(signals(ServerStatus(sshProblem: .timeout, sshFailures: 1), server: noSite).isEmpty)

        var unwatched = server
        unwatched.monitor = false
        XCTAssertTrue(signals(ServerStatus(site: SiteCheck(code: nil), siteFailures: 9), server: unwatched).isEmpty, "watching is off")
    }

    func testServicesAndDisk() {
        let down = signals(ServerStatus(site: SiteCheck(code: 200), host: HostFacts(services: [ServiceState(name: "web", state: "running"), ServiceState(name: "db", state: "exited")])))
        XCTAssertEqual(down.map(\.kind), [.serverService])
        XCTAssertEqual(down[0].title, "На «Основной» не запущено: db")

        let unhealthy = signals(ServerStatus(site: SiteCheck(code: 200), host: HostFacts(services: [ServiceState(name: "web", state: "running", health: "unhealthy")])))
        XCTAssertEqual(unhealthy[0].title, "На «Основной» не проходит проверку здоровья: web")

        let stale = signals(ServerStatus(site: SiteCheck(code: 200), host: HostFacts(services: [ServiceState(name: "db", state: "exited")]), sshProblem: .timeout, sshFailures: 1))
        XCTAssertTrue(stale.isEmpty, "old container data isn't trusted while the server can't be reached")

        func disk(_ used: Int) -> [Signal] { signals(ServerStatus(site: SiteCheck(code: 200), host: HostFacts(diskTotalKB: 100_000_000, diskUsedKB: used))) }
        XCTAssertTrue(disk(80_000_000).isEmpty)
        XCTAssertEqual(disk(92_000_000).map(\.severity), [.warning])
        XCTAssertEqual(disk(92_000_000)[0].title, "Диск «Основной» заполнен на 92 %")
        XCTAssertEqual(disk(98_000_000).map(\.severity), [.critical])
    }

    func testFailedDeployUntilTheNextGoodOne() {
        let failed = DeployRun(projectId: "/p/a", serverId: server.id, trigger: .auto, startedAt: Date(), toCommit: "77aa88b000",
                               steps: [StepRun(name: "Тесты", place: .mac, state: .failed, note: "not ok 14 - geofence: ")], state: .failed)
        let raised = signals(ServerStatus(site: SiteCheck(code: 200)), run: failed)
        XCTAssertEqual(raised.map(\.kind), [.deployFailed])
        XCTAssertTrue(raised[0].detail.hasPrefix("Остановилась на шаге «Тесты»: not ok 14 - geofence. "), raised[0].detail)
        XCTAssertEqual(raised[0].metrics.first?.value, "77aa88b")

        var ok = failed
        ok.state = .success
        XCTAssertEqual(signals(ServerStatus(site: SiteCheck(code: 200)), run: ok, existing: raised).first?.state, .resolved)
        var stopped = failed
        stopped.state = .cancelled
        XCTAssertTrue(signals(ServerStatus(site: SiteCheck(code: 200)), run: stopped).isEmpty, "stopping a deploy by hand isn't a failure")
    }
}

/// The suggested database dump against a real Postgres. Needs Docker, so it only runs when asked:
/// `TEST_RUNNER_ORBIT_BACKUP_E2E=<folder with a running compose project> xcodebuild test -only-testing:OrbitTests/RealBackupTests`.
final class RealBackupTests: XCTestCase {
    func testSuggestedDumpAgainstARunningDatabase() throws {
        guard let project = ProcessInfo.processInfo.environment["ORBIT_BACKUP_E2E"], !project.isEmpty else {
            throw XCTSkip("set ORBIT_BACKUP_E2E to a folder with a running compose project")
        }
        L10n.current = .ru
        let home = (project as NSString).deletingLastPathComponent + "/backups"
        let step = try XCTUnwrap(DeployTemplate.detect(projectPath: project).steps.first { $0.kind == .backup })
        XCTAssertFalse(step.command.isEmpty, "the compose file has a database: a dump is suggested")
        let server = ServerConfig(name: "x", host: "h", directory: project)
        let script = DeployPipeline.remoteScript(server, body: DeployPipeline.backupScript(command: step.command), env: [:])
        let log = URL(fileURLWithPath: home + "/step.log")
        let path = CLILocator.searchPATH(for: "/bin/bash")
        let status = StepProcess().run("/bin/bash", ["-c", script], env: ["ORBIT_BACKUP_HOME": home, "ORBIT_PIDFILE": "", "PATH": path], log: log, timeout: 120)
        try LogText.tail(log).write(toFile: home + "/last-run.txt", atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ORBIT_BACKUP_EXPECT"] == "failure" {
            XCTAssertNotEqual(status, 0, "with the database down the backup must fail")
        } else {
            XCTAssertEqual(status, 0, LogText.tail(log))
        }
    }
}
