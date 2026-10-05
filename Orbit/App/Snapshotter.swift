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
        if args.contains("--splash-frames") {
            // Frames of the launch animation, then quit.
            var elapsed = 0.0
            for t in [0.15, 0.35, 0.6, 0.9, 1.3, 1.6, 2.0, 2.4, 2.8, 3.0, 3.2, 3.6] {
                try? await Task.sleep(for: .seconds(t - elapsed))
                elapsed = t
                capture(to: "\(dir)/splash-\(String(format: "%.2f", t)).png")
            }
            NSApp.terminate(nil)
            return
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
            case "wait": try? await Task.sleep(for: .seconds(30)); continue
            case _ where name.hasPrefix("frames:"):
                // frames:projects → three captures mid-transition to check that motion happens.
                let target = String(name.dropFirst("frames:".count))
                switch target {
                case "projects": app.screen = .projects
                case "project": if let p = app.activeSnapshots.first { app.screen = .project(p.config.id) }
                case "sessions": app.screen = .sessions
                default: app.screen = .week
                }
                for (i, delay) in [0.05, 0.12, 0.6].enumerated() {
                    try? await Task.sleep(for: .seconds(delay - (i == 0 ? 0 : [0.05, 0.12, 0.6][i - 1])))
                    capture(to: "\(dir)/frames-\(target)-\(i + 1).png")
                }
                continue
            case "plan": app.savePlan(app.makePlan(weekKey: app.displayWeekKey)); continue
            case _ where name.hasPrefix("lang:"):
                // Live switch without touching AppleLanguages (the real app shares the defaults domain).
                app.config.language = AppLanguage(rawValue: String(name.dropFirst(5))) ?? .system
                app.applyLanguage()
                try? await Task.sleep(for: .seconds(0.5))
                continue
            case "settings-general", "settings-ai":
                let root = Group {
                    if name == "settings-ai" { AISettingsView() } else { GeneralSettingsView() }
                }
                .environment(app).preferredColorScheme(.dark).frame(width: 680, height: 720)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: root)
                window.orderFront(nil)
                try? await Task.sleep(for: .seconds(1.5))
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                window.close()
                continue
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
