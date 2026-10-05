import XCTest
@testable import Orbit

final class TestOutputTests: XCTestCase {
    func testJest() {
        let r = TestOutput.parse("FAIL src/auth/session.spec.ts\nTests:       2 failed, 212 passed, 214 total")
        XCTAssertEqual(r.passed, 212)
        XCTAssertEqual(r.failed, 2)
        XCTAssertEqual(r.failingName, "src/auth/session.spec.ts")
    }

    func testPytest() {
        let r = TestOutput.parse("===== 3 failed, 40 passed in 2.31s =====")
        XCTAssertEqual(r.passed, 40)
        XCTAssertEqual(r.failed, 3)
    }

    func testXCTest() {
        let r = TestOutput.parse("Executed 12 tests, with 1 failure (0 unexpected) in 0.5 seconds")
        XCTAssertEqual(r.passed, 11)
        XCTAssertEqual(r.failed, 1)
    }

    func testGoVerbose() {
        let r = TestOutput.parse("--- PASS: TestA\n--- PASS: TestB\n--- FAIL: TestC\nFAIL")
        XCTAssertEqual(r.passed, 2)
        XCTAssertEqual(r.failed, 1)
    }

    func testPassedOnlyMeansZeroFailed() {
        XCTAssertEqual(TestOutput.parse("Tests: 30 passed, 30 total").failed, 0)
    }
}

final class SessionBuilderTests: XCTestCase {
    /// Expectations below are written for the Russian interface.
    override func setUp() { super.setUp(); L10n.current = .ru }

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testSplitsOnLongPause() {
        let b = SessionBuilder(agent: .claude, logPath: "/x.jsonl", resumeId: "abc", cwd: "/repo")
        b.prompt(t0, "Сделай миграцию авторизации")
        b.edit(t0.addingTimeInterval(60), file: "/repo/a.swift", old: "a", new: "a\nb")
        b.prompt(t0.addingTimeInterval(5 * 3600), "Продолжи работу над тестами авторизации")
        b.edit(t0.addingTimeInterval(5 * 3600 + 60), file: "/repo/b.swift", old: "", new: "x")
        let sessions = b.finish()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].filesTouched, ["/repo/a.swift"])
        XCTAssertEqual(sessions[0].linesAdded, 1)
        XCTAssertEqual(sessions[1].title, "Продолжи работу над тестами авторизации")
    }

    func testShortResumePromptKeepsGlobalTitle() {
        let b = SessionBuilder(agent: .claude, logPath: "/x.jsonl", resumeId: "abc", cwd: "/repo")
        b.setTitle("Миграция OAuth")
        b.prompt(t0, "начни")
        b.prompt(t0.addingTimeInterval(5 * 3600), "Continue")
        let sessions = b.finish()
        XCTAssertEqual(sessions.map(\.title), ["Миграция OAuth", "Миграция OAuth"])
    }

    func testDetectsRevertedEdit() {
        let b = SessionBuilder(agent: .claude, logPath: "/x.jsonl", resumeId: nil, cwd: "/repo")
        b.prompt(t0, "fix")
        b.edit(t0.addingTimeInterval(10), file: "/repo/m.ts", old: "foo()", new: "bar()")
        b.edit(t0.addingTimeInterval(20), file: "/repo/m.ts", old: "bar()", new: "foo()")
        b.command(t0.addingTimeInterval(30), "git restore src/m.ts")
        let s = b.finish()[0]
        XCTAssertEqual(s.reverts, 2)
        XCTAssertEqual(s.editsPerFile["/repo/m.ts"], 2)
    }

    func testTestCommandResult() {
        let b = SessionBuilder(agent: .claude, logPath: "/x.jsonl", resumeId: nil, cwd: "/repo")
        b.prompt(t0, "run tests")
        b.command(t0.addingTimeInterval(5), "npm test")
        b.commandResult(t0.addingTimeInterval(9), command: "npm test", output: "Tests: 1 failed, 9 passed", isError: true)
        let s = b.finish()[0]
        XCTAssertEqual(s.testsPassed, 9)
        XCTAssertEqual(s.testsFailed, 1)
    }

    func testTitleDropsAttachmentMarkers() {
        XCTAssertEqual(SessionBuilder.titleFromPrompt("[Image #1] что за белая фигня ?"), "что за белая фигня ?")
    }
}

final class ParserFixtureTests: XCTestCase {
    /// Expectations below are written for the Russian interface.
    override func setUp() { super.setUp(); L10n.current = .ru }

    private func write(_ lines: [[String: Any]], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testClaudeCodeTranscript() throws {
        let cwd = "/Users/me/code/atlas-api"
        let url = try write([
            ["type": "user", "timestamp": "2026-10-01T10:00:00.000Z", "cwd": cwd, "sessionId": "s1",
             "message": ["role": "user", "content": "Перенеси refresh-токены в Redis"]],
            ["type": "assistant", "timestamp": "2026-10-01T10:01:00.000Z", "cwd": cwd,
             "message": ["id": "m1", "role": "assistant", "model": "claude-opus-5-5",
                         "usage": ["input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 10],
                         "content": [["type": "tool_use", "id": "t1", "name": "Edit",
                                      "input": ["file_path": "\(cwd)/src/auth/session.ts", "old_string": "a", "new_string": "a\nb\nc"]],
                                     ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "npx jest"]]]]],
            ["type": "user", "timestamp": "2026-10-01T10:02:00.000Z", "cwd": cwd,
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2", "is_error": true,
                                                       "content": "Tests: 2 failed, 12 passed, 14 total"]]]],
            ["type": "assistant", "timestamp": "2026-10-01T10:03:00.000Z", "cwd": cwd,
             "message": ["id": "m2", "role": "assistant", "content": [["type": "text", "text": "Перенёс хранение токенов, добавил тесты. Два теста падают в middleware."]]]],
            ["type": "ai-title", "aiTitle": "Refresh-токены → Redis", "sessionId": "s1"],
        ], name: "orbit-fixture-claude.jsonl")
        let sessions = ClaudeCodeParser.parse(url)
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.title, "Refresh-токены → Redis")
        XCTAssertEqual(s.cwd, cwd)
        XCTAssertEqual(s.linesAdded, 2)
        XCTAssertEqual(s.tokens, 160)
        XCTAssertEqual(s.model, "claude-opus-5-5")
        XCTAssertEqual(s.testsFailed, 2)
        XCTAssertEqual(s.testsPassed, 12)
        XCTAssertTrue(s.finalMessage?.contains("Два теста падают") ?? false)
        XCTAssertEqual(s.resumeId, "orbit-fixture-claude")
    }

    func testClaudeDirectoryEscaping() {
        XCTAssertEqual(ClaudeCodeParser.escape("/Users/me/Documents/Projects/beta_web"), "-Users-me-Documents-Projects-beta-web")
    }

    func testCodexRollout() throws {
        let cwd = "/Users/me/code/ml-pipeline"
        let patch = "*** Begin Patch\n*** Update File: src/train.py\n@@\n-old\n+new\n+more\n*** End Patch"
        let url = try write([
            ["timestamp": "2026-10-01T09:00:00.000Z", "type": "session_meta", "payload": ["id": "th-1", "cwd": cwd]],
            ["timestamp": "2026-10-01T09:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Сделай отчёт по LoRA"]]]],
            ["timestamp": "2026-10-01T09:01:00.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c1", "input": patch]],
            ["timestamp": "2026-10-01T09:02:00.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call", "name": "exec", "call_id": "c2", "input": "await tools.exec_command({cmd:\"pytest -q\"})"]],
            ["timestamp": "2026-10-01T09:03:00.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call_output", "call_id": "c2", "output": "5 passed in 0.2s"]],
            ["timestamp": "2026-10-01T09:04:00.000Z", "type": "event_msg",
             "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 100]]]],
        ], name: "orbit-fixture-codex.jsonl")
        let s = try XCTUnwrap(CodexParser.parse(url, names: ["th-1": "LoRA-отчёт"]).first)
        XCTAssertEqual(s.title, "LoRA-отчёт")
        XCTAssertEqual(s.resumeId, "th-1")
        XCTAssertEqual(s.filesTouched, ["src/train.py"])
        XCTAssertEqual(s.linesAdded, 2)
        XCTAssertEqual(s.linesRemoved, 1)
        XCTAssertEqual(s.testsPassed, 5)
        XCTAssertEqual(s.tokens, 700)
        XCTAssertEqual(CodexParser.headerCwd(url), cwd)
    }
}

final class GitServiceTests: XCTestCase {
    var repo: String!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "Test")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "first")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    @discardableResult
    private func git(_ args: String...) -> ShellResult {
        let r = Shell.git(repo, args)
        XCTAssertTrue(r.ok, "git \(args.joined(separator: " ")): \(r.stderr)")
        return r
    }

    func testStatusBranchAndChanges() throws {
        git("switch", "-q", "-c", "feat/x")
        try "two\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "feat: b", "-m", "Co-Authored-By: Claude <noreply@anthropic.com>")
        git("switch", "-q", "main")
        for i in 0..<3 {
            try "\(i)\n".write(toFile: repo + "/main\(i).txt", atomically: true, encoding: .utf8)
            git("add", ".")
            git("commit", "-q", "-m", "main \(i)")
        }
        git("switch", "-q", "feat/x")
        try "one\nchanged\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)

        let s = GitService.status(repo)
        XCTAssertEqual(s.branch, "feat/x")
        XCTAssertEqual(s.mainBranch, "main")
        XCTAssertEqual(s.behindMain, 3)
        XCTAssertEqual(s.aheadMain, 1)
        XCTAssertEqual(Set(s.changes.map(\.path)), ["a.txt", "new.txt"])
        XCTAssertEqual(s.changes.first { $0.path == "a.txt" }?.added, 1)
        XCTAssertEqual(s.changes.first { $0.path == "new.txt" }?.status, "?", "untracked")
        XCTAssertEqual(s.lastCommit?.agent, .claude)
        XCTAssertEqual(s.commits.count, 2, "history of the current branch only")
    }

    func testCommitSelectedFiles() throws {
        try "x\n".write(toFile: repo + "/c.txt", atomically: true, encoding: .utf8)
        try "y\n".write(toFile: repo + "/d.txt", atomically: true, encoding: .utf8)
        let r = GitService.commit(repo, files: ["c.txt"], message: "feat: c", push: false)
        XCTAssertTrue(r.ok, r.stderr)
        let s = GitService.status(repo)
        XCTAssertEqual(s.changes.map(\.path), ["d.txt"])
        XCTAssertEqual(s.lastCommit?.subject, "feat: c")
    }

    func testDeleteMergedBranch() {
        git("branch", "old")
        XCTAssertTrue(GitService.deleteBranch(repo, "old").ok)
        XCTAssertFalse(GitService.status(repo).branches.contains { $0.name == "old" })
    }
}

final class PlannerAndSignalsTests: XCTestCase {
    /// Expectations below are written for the Russian interface.
    override func setUp() { super.setUp(); L10n.current = .ru }

    private func snapshot(_ name: String, colorIndex: Int = 0, repo: RepoStatus = RepoStatus(), sessions: [AgentSession] = []) -> ProjectSnapshot {
        ProjectSnapshot(config: ProjectConfig(path: "/p/\(name)", name: name, colorIndex: colorIndex), repo: repo, sessions: sessions)
    }

    private func recentCommit() -> Commit {
        Commit(hash: UUID().uuidString, subject: "x", author: "me", date: Date().addingTimeInterval(-3600), body: "", added: 1, removed: 0)
    }

    func testPlannerRespectsCapacityAndLimits() {
        var healthy = RepoStatus()
        healthy.commits = [recentCommit()]
        let projects = (0..<4).map { snapshot("p\($0)", colorIndex: $0, repo: healthy) }
        var rhythm = Rhythm()
        rhythm.maxProjectsPerDay = 2
        let plan = Planner.makePlan(weekKey: "2026-10-05", projects: projects, signals: [], rhythm: rhythm)
        for d in 0..<7 {
            XCTAssertLessThanOrEqual(plan.hours(on: d), Double(rhythm.hours[d]), "day \(d) over capacity")
            XCTAssertLessThanOrEqual(Set(plan.blocks(on: d).map(\.projectId)).count, 2)
        }
        XCTAssertTrue(plan.blocks.allSatisfy { $0.day < 5 }, "weekend should stay free")
        XCTAssertGreaterThan(plan.totalHours, 20)
    }

    func testUrgentProjectGoesFirst() {
        var healthy = RepoStatus()
        healthy.commits = [recentCommit()]
        let projects = [snapshot("calm", repo: healthy), snapshot("urgent", colorIndex: 1, repo: healthy)]
        let signal = Signal(id: "behindMain:/p/urgent", kind: .behindMain, projectId: "/p/urgent", severity: .critical,
                            title: "", detail: "", metrics: [], detectedAt: Date())
        let plan = Planner.makePlan(weekKey: "2026-10-05", projects: projects, signals: [signal], rhythm: Rhythm())
        XCTAssertTrue(plan.blocks(on: 0).contains { $0.projectId == "/p/urgent" })
    }

    func testPlannerSkipsPastDays() {
        let projects = [snapshot("a")]
        let plan = Planner.makePlan(weekKey: "2026-10-05", projects: projects, signals: [], rhythm: Rhythm(), startDay: 3)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.day >= 3 })
    }

    func testUncommittedSignalRaisesAndResolves() {
        var repo = RepoStatus()
        repo.changes = [FileChange(path: "a.txt", status: "M", added: 30, removed: 30)]
        repo.changesSince = Date().addingTimeInterval(-30 * 3600)
        repo.commits = [recentCommit()]
        let config = OrbitConfig()
        let raised = SignalEngine.evaluate(config: config, projects: [snapshot("a", repo: repo)], plans: [], existing: [])
        let uncommitted = raised.first { $0.kind == .uncommitted }
        XCTAssertEqual(uncommitted?.state, .active)
        XCTAssertEqual(uncommitted?.severity, .warning)

        var clean = repo
        clean.changes = []
        let after = SignalEngine.evaluate(config: config, projects: [snapshot("a", repo: clean)], plans: [], existing: raised)
        XCTAssertEqual(after.first { $0.kind == .uncommitted }?.state, .resolved)
    }

    func testIdleProjectLosesHealth() {
        var active = RepoStatus()
        active.commits = [recentCommit()]
        var idle = RepoStatus()
        idle.lastCommit = Commit(hash: "h", subject: "x", author: "me", date: Date().addingTimeInterval(-20 * 86400), body: "", added: 0, removed: 0)
        XCTAssertGreaterThan(HealthEngine.score(snapshot("a", repo: active)), HealthEngine.score(snapshot("b", repo: idle)) + 20)
    }

    func testRussianPlurals() {
        XCTAssertEqual(Plural.files(1), "1 файл")
        XCTAssertEqual(Plural.files(3), "3 файла")
        XCTAssertEqual(Plural.files(11), "11 файлов")
        XCTAssertEqual(Plural.files(22), "22 файла")
    }
}

final class AITests: XCTestCase {
    /// Expectations below are written for the Russian interface.
    override func setUp() { super.setUp(); L10n.current = .ru }

    func testJSONExtractionToleratesNoise() {
        XCTAssertEqual(JSONText.firstObject(in: "```json\n{\"a\": 1}\n```")?["a"] as? Int, 1)
        XCTAssertEqual(JSONText.lastObject(in: "login banner\n{\"type\":\"result\",\"x\":2}\n")?["x"] as? Int, 2)
    }

    func testProjectAnswerParsing() throws {
        let obj: [String: Any] = ["headline": " Стабильно ", "summary": "Ок.", "digest": "", "goal": "Цель",
                                  "next_steps": ["Шаг 1", "", "Шаг 2", "Шаг 3", "Шаг 4"]]
        let p = try AnalysisService.parseProject(obj, source: "test", hash: "h")
        XCTAssertEqual(p.headline, "Стабильно")
        XCTAssertEqual(p.nextSteps, ["Шаг 1", "Шаг 2", "Шаг 3"])
    }

    func testSchemaRequiresEveryField() {
        let required = AnalysisService.projectSchema["required"] as? [String]
        XCTAssertEqual(Set(required ?? []), ["headline", "summary", "digest", "next_steps", "goal"])
        XCTAssertEqual(AnalysisService.projectSchema["additionalProperties"] as? Bool, false)
    }

    func testFactsHashIgnoresHourlyNoise() {
        var repo = RepoStatus()
        repo.changes = [FileChange(path: "a", status: "?", added: 0, removed: 0)]
        repo.changesSince = Date().addingTimeInterval(-30 * 3600)
        let snap = ProjectSnapshot(config: ProjectConfig(path: "/p/a", name: "a", colorIndex: 0), repo: repo, sessions: [])
        let (r1, h1) = AnalysisService.projectRequest(snap, health: 80, signals: [])
        repo.changesSince = Date().addingTimeInterval(-31 * 3600)
        let snap2 = ProjectSnapshot(config: snap.config, repo: repo, sessions: [])
        let (_, h2) = AnalysisService.projectRequest(snap2, health: 80, signals: [])
        XCTAssertEqual(h1, h2, "an hour of ageing must not trigger re-analysis")
        XCTAssertTrue(r1.prompt.contains("untracked a"))
    }

    func testHeredocCommitMessage() {
        XCTAssertEqual(SessionBuilder.commitMessage("git commit -m \"$(cat <<'EOF'\nfeat: x\n\nbody\nEOF\n)\""), "feat: x")
        XCTAssertEqual(SessionBuilder.commitMessage("git commit -m \"fix: y\""), "fix: y")
    }

    func testOldConfigWithoutAIDecodes() throws {
        let json = #"{"onboarded": true, "projects": [], "scanRoots": ["~/x"]}"#
        let c = try JSONDecoder().decode(OrbitConfig.self, from: Data(json.utf8))
        XCTAssertTrue(c.onboarded)
        XCTAssertEqual(c.ai.provider, .heuristics)
        XCTAssertEqual(c.rhythm.weeklyHours, 35)
    }
}

final class UpdaterTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-release-latest", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testSemVerOrdering() throws {
        let v = { (s: String) in try XCTUnwrap(SemVer(s)) }
        XCTAssertLessThan(try v("0.4.0"), try v("0.5.0"))
        XCTAssertLessThan(try v("0.9.0"), try v("0.10.0"))
        XCTAssertLessThan(try v("0.4"), try v("0.4.1"))
        XCTAssertEqual(try v("v1.2.0"), try v("1.2"))
        XCTAssertNil(SemVer("latest"))
    }

    func testParsesRealGitHubRelease() throws {
        let release = try Updater.parse(try fixture())
        XCTAssertEqual(release.version, "0.4.0")
        XCTAssertEqual(release.assetName, "Orbit-0.4.0-macOS.zip")
        XCTAssertEqual(release.sha256.count, 64)
        XCTAssertTrue(release.assetURL.absoluteString.hasPrefix("https://github.com/Tolib-N8/"))
        XCTAssertFalse(release.notes.isEmpty)
    }

    func testOnlyNewerVersionsAreOffered() throws {
        let release = try Updater.parse(try fixture())
        XCTAssertTrue(Updater.isNewer(release, than: "0.3.0"))
        XCTAssertFalse(Updater.isNewer(release, than: "0.4.0"))
        XCTAssertFalse(Updater.isNewer(release, than: "0.5.0"))
    }

    func testReleaseWithoutChecksumIsRejected() throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        var assets = try XCTUnwrap(obj["assets"] as? [[String: Any]])
        assets[0]["digest"] = nil
        obj["assets"] = assets
        XCTAssertThrowsError(try Updater.parse(try JSONSerialization.data(withJSONObject: obj)))
        obj["assets"] = [["name": "notes.txt", "browser_download_url": "https://x", "digest": "sha256:00"]]
        XCTAssertThrowsError(try Updater.parse(try JSONSerialization.data(withJSONObject: obj)), "no app archive")
    }

    func testPicksUpdaterZipWhenReleaseAlsoHasDMG() throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        var assets = try XCTUnwrap(obj["assets"] as? [[String: Any]])
        assets.insert(["name": "Orbit-0.4.0.dmg", "size": 5_000_000, "digest": "sha256:" + String(repeating: "a", count: 64),
                       "browser_download_url": "https://github.com/Tolib-N8/Project-control-center/releases/download/v0.4.0/Orbit-0.4.0.dmg"], at: 0)
        obj["assets"] = assets
        let release = try Updater.parse(try JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(release.assetName, "Orbit-0.4.0-macOS.zip")
    }

    func testChecksumVerification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-sha-\(UUID().uuidString)")
        try Data("orbit".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // Reference value from the system shasum, independent of CryptoKit.
        let actual = String(Shell.run("/usr/bin/shasum", ["-a", "256", file.path]).stdout.prefix(64))
        let tampered = String(repeating: "0", count: 64)
        XCTAssertNoThrow(try Updater.verifyChecksum(of: file, expected: actual))
        XCTAssertNoThrow(try Updater.verifyChecksum(of: file, expected: actual.uppercased()))
        XCTAssertThrowsError(try Updater.verifyChecksum(of: file, expected: tampered))
    }
}

final class CLILocatorTests: XCTestCase {
    func testLooksInUserBinFolders() {
        XCTAssertTrue(CLILocator.candidateDirs.contains(NSHomeDirectory() + "/.local/bin"))
        XCTAssertTrue(CLILocator.candidateDirs.contains("/opt/homebrew/bin"))
    }

    func testUnknownCLIIsNil() {
        XCTAssertNil(CLILocator.path(for: "orbit-no-such-cli-\(UUID().uuidString.prefix(6))"))
    }

    func testSearchPATHStartsWithTheCLIFolderWithoutDuplicates() {
        let path = CLILocator.searchPATH(for: "/opt/homebrew/bin/claude")
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/opt/homebrew/bin")
        XCTAssertEqual(parts.count, Set(parts).count)
        XCTAssertTrue(parts.contains("/usr/bin"))
    }
}

final class LocalizationTests: XCTestCase {
    private var saved = L10n.current
    override func setUp() { super.setUp(); saved = L10n.current }
    override func tearDown() { L10n.current = saved; super.tearDown() }

    func testPluralsInBothLanguages() {
        L10n.current = .ru
        XCTAssertEqual(Plural.files(1), "1 файл")
        XCTAssertEqual(Plural.files(3), "3 файла")
        XCTAssertEqual(Plural.files(11), "11 файлов")
        XCTAssertEqual(Plural.commits(21), "21 коммит")
        L10n.current = .en
        XCTAssertEqual(Plural.files(1), "1 file")
        XCTAssertEqual(Plural.files(3), "3 files")
        XCTAssertEqual(Plural.repos(0), "0 repositories")
        XCTAssertEqual(pluralWord(1, ru: ("день", "дня", "дней"), en: ("day", "days")), "day")
    }

    func testDatesAndNumbers() {
        let date = DateFormat.isoDay.date(from: "2026-09-28")!
        let now = date.addingTimeInterval(3 * 3600)
        L10n.current = .ru
        XCTAssertEqual(DateFormat.short(date), "28 сен")
        XCTAssertEqual(DateFormat.dayMonthFull.string(from: date), "28 сентября")
        XCTAssertEqual(DateFormat.ago(date, now: now), "3 ч назад")
        XCTAssertEqual(Duration.hours(1.5), "1,5")
        XCTAssertEqual(Duration.text(minutes: 72), "1 ч 12 мин")
        XCTAssertEqual(NumberText.grouped(12500), "12 500")
        L10n.current = .en
        XCTAssertEqual(DateFormat.short(date), "Sep 28")
        XCTAssertEqual(DateFormat.dayMonthFull.string(from: date), "September 28")
        XCTAssertEqual(DateFormat.weekdayFull.string(from: date), "Monday")
        XCTAssertEqual(DateFormat.ago(date, now: now), "3 h ago")
        XCTAssertEqual(Duration.hours(1.5), "1.5")
        XCTAssertEqual(Duration.text(minutes: 72), "1 h 12 min")
        XCTAssertEqual(NumberText.grouped(12500), "12,500")
        XCTAssertEqual(Week.shortNames.first, "Mon")
    }

    func testLanguageSetting() throws {
        XCTAssertEqual(AppLanguage.ru.resolved, .ru)
        XCTAssertEqual(AppLanguage.en.resolved, .en)
        // Configs written before 0.7 belong to Russian-speaking users and stay Russian.
        let old = try JSONDecoder().decode(OrbitConfig.self, from: Data(#"{"onboarded":true}"#.utf8))
        XCTAssertEqual(old.language, .ru)
        let fresh = try JSONDecoder().decode(OrbitConfig.self, from: Data(#"{"onboarded":false}"#.utf8))
        XCTAssertEqual(fresh.language, .system)
    }

    func testAICacheIsPerLanguage() {
        // Russian keeps the pre-0.7 hashes, so existing caches stay valid.
        L10n.current = .ru
        XCTAssertEqual(AnalysisService.languageSalt, "")
        L10n.current = .en
        XCTAssertEqual(AnalysisService.languageSalt, "|lang:en")
    }
}

final class TaskTests: XCTestCase {
    private var saved = L10n.current
    override func setUp() { super.setUp(); saved = L10n.current }
    override func tearDown() { L10n.current = saved; super.tearDown() }

    private func day(_ key: String) -> Date { DateFormat.isoDay.date(from: key)! }

    func testOpenOrderingUrgentThenDueThenAge() {
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 100)
        let tasks = [
            ProjectTask(projectId: "p", title: "no due, newer", createdAt: new),
            ProjectTask(projectId: "p", title: "no due, older", createdAt: old),
            ProjectTask(projectId: "p", title: "friday", due: "2026-10-09"),
            ProjectTask(projectId: "p", title: "urgent, no due", urgent: true),
            ProjectTask(projectId: "p", title: "today", due: "2026-10-05"),
            ProjectTask(projectId: "p", title: "done", due: "2026-10-01", completedAt: new),
        ]
        XCTAssertEqual(TaskOrdering.open(tasks).map(\.title),
                       ["urgent, no due", "today", "friday", "no due, older", "no due, newer"])
        XCTAssertEqual(TaskOrdering.done(tasks).map(\.title), ["done"])
    }

    func testDueLabels() {
        let now = day("2026-10-05").addingTimeInterval(10 * 3600) // Monday
        L10n.current = .ru
        XCTAssertEqual(TaskDue.label("2026-10-05", now: now).text, "Сегодня")
        XCTAssertEqual(TaskDue.label("2026-10-05", now: now).tone, .today)
        XCTAssertEqual(TaskDue.label("2026-10-06", now: now).text, "Завтра")
        XCTAssertEqual(TaskDue.label("2026-10-07", now: now).text, "Ср")
        XCTAssertEqual(TaskDue.label("2026-10-14", now: now).text, "14 окт")
        XCTAssertEqual(TaskDue.label("2026-10-02", now: now).tone, .overdue)
        XCTAssertEqual(TaskDue.label(nil, now: now).text, "—")
        L10n.current = .en
        XCTAssertEqual(TaskDue.label("2026-10-05", now: now).text, "Today")
        XCTAssertEqual(TaskDue.label("2026-10-09", now: now).text, "Fri")
        XCTAssertEqual(TaskDue.label("2026-10-02", now: now).text, "Oct 2")
        // Today through Friday, at least three days ahead.
        XCTAssertEqual(TaskDue.choices(now: now).map(\.key).first, "2026-10-05")
        XCTAssertEqual(TaskDue.choices(now: now).count, 6)
        XCTAssertEqual(TaskDue.choices(now: day("2026-10-10")).count, 4)
    }

    func testAreaDetection() {
        let folders = ["api", "api-docs", "auth", "frontend"]
        XCTAssertEqual(TaskArea.detect(title: "Починить тесты в auth", folders: folders), "auth")
        XCTAssertEqual(TaskArea.detect(title: "Update api-docs for /token", folders: folders), "api-docs")
        XCTAssertEqual(TaskArea.detect(title: "Frontend: dark theme", folders: folders), "frontend")
        XCTAssertNil(TaskArea.detect(title: "authorization flow", folders: folders))
    }

    func testFoldersSkipHiddenAndBuildOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["src", ".git", "node_modules", "docs"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: dir.appendingPathComponent("README.md"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(TaskArea.folders(in: dir.path), ["docs", "src"])
    }

    func testCodableRoundTrip() throws {
        let task = ProjectTask(projectId: "/p", title: "Ship", urgent: true, area: "api", due: "2026-10-07", completedAt: Date(timeIntervalSince1970: 5))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode([ProjectTask].self, from: e.encode([task]))
        XCTAssertEqual(back.first?.id, task.id)
        XCTAssertEqual(back.first?.area, "api")
        XCTAssertEqual(back.first?.done, true)
    }
}
