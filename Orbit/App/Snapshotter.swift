import AppKit
import SwiftUI

#if DEBUG
/// Debug helper: `Orbit --snapshot <dir> [--screens week,projects,…]` renders each screen to PNG.
/// Used to compare the UI against design/exports/png without screen-recording permission.
@MainActor
enum Snapshotter {
    static var directory: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ app: AppState) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let args = ProcessInfo.processInfo.arguments
        var names = ["first-launch", "week", "projects", "project", "sessions", "git", "signals", "planner"]
        if let i = args.firstIndex(of: "--screens"), i + 1 < args.count {
            names = args[i + 1].split(separator: ",").map(String.init)
        }
        try? await Task.sleep(for: .seconds(2))
        if !app.config.onboarded {
            guard args.contains("--auto-onboard") else {
                try? await Task.sleep(for: .seconds(4))
                capture(to: "\(dir)/onboarding.png")
                return
            }
            let roots = app.config.scanRoots
            let repos = await Task.detached { RepoScanner.enrich(RepoScanner.scan(roots: roots)) }.value
            app.finishOnboarding(repos: repos, rhythm: Rhythm())
            try? await Task.sleep(for: .seconds(1))
            capture(to: "\(dir)/first-launch.png")
        }
        // Wait for the first refresh.
        for _ in 0..<120 where app.lastSync == nil { try? await Task.sleep(for: .milliseconds(500)) }
        for name in names {
            switch name {
            case "first-launch": continue
            case "plan": app.savePlan(app.makePlan(weekKey: app.displayWeekKey)); continue
            case "week", "week-empty": app.screen = .week
            case "projects": app.screen = .projects
            case "project": if let p = app.activeSnapshots.max(by: { $0.sessions.count < $1.sessions.count }) { app.screen = .project(p.config.id) }
            case "sessions": app.screen = .sessions
            case "git": app.screen = .git
            case "signals": app.screen = .signals
            case "planner":
                app.screen = .week
                app.sheet = .planner(weekKey: app.displayWeekKey)
            default: continue
            }
            try? await Task.sleep(for: .seconds(1.5))
            capture(to: "\(dir)/\(name).png")
            app.sheet = nil
        }
        NSApp.terminate(nil)
    }

    static func capture(to path: String) {
        // Sheets are separate windows; capture the frontmost visible one.
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
        guard let window = windows.first(where: { $0.isSheet }) ?? windows.first(where: { $0.title == "Orbit" }) ?? windows.first,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
