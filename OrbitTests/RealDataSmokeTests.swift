import XCTest
@testable import Orbit

/// Runs against the developer's real ~/Documents/Projects. Opt-in: ORBIT_SMOKE=1.
final class RealDataSmokeTests: XCTestCase {
    func testIndexRealProjects() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORBIT_SMOKE"] == "1", "set ORBIT_SMOKE=1")
        let root = "~/Documents/Projects".expandingTilde
        let repos = RepoScanner.scan(roots: [root])
        try XCTSkipIf(repos.isEmpty, "no local repos")
        let projects = repos.enumerated().map { ProjectConfig(path: $1.path, name: $1.name, colorIndex: $0) }
        let config = OrbitConfig()
        let t0 = Date()
        let sessions = SessionIndexer.index(projects: projects, config: config)
        var statuses: [String: RepoStatus] = [:]
        for p in projects { statuses[p.path] = GitService.status(p.path) }
        let analyzed = SessionAnalyzer.analyze(sessions, repos: statuses)
        print("SMOKE: \(repos.count) repos, \(sessions.count) sessions in \(Date().timeIntervalSince(t0))s")
        for p in projects {
            let st = analyzed.repos[p.path]!
            let ss = analyzed.sessions.filter { $0.projectId == p.path }
            print("SMOKE: \(p.name) branch=\(st.branch) changes=\(st.changes.count) +\(st.linesAdded)/-\(st.linesRemoved) commits=\(st.commits.count) stack=\(st.stack) sessions=\(ss.count)")
            for s in ss.prefix(3) {
                print("SMOKE:   [\(s.agent.title)] \(s.title) | \(s.durationMinutes)m files=\(s.filesTouched.count) +\(s.linesAdded)/-\(s.linesRemoved) tok=\(s.tokens) tests=\(String(describing: s.testsPassed))/\(String(describing: s.testsFailed)) rev=\(s.reverts) status=\(s.status) events=\(s.events.count)")
            }
        }
    }
}
