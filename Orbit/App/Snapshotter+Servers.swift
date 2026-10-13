import AppKit
import SwiftUI

#if DEBUG
/// Snapshot steps that talk to a real server (`--live-servers`): used to try the whole thing on a practice machine.
/// `live-check`, `live-servers`, `live-deploy`, `live-cancel:<seconds>`, `live-rollback`, `live-auto`, `live-log`, `live-signals`, `live-state`.
extension Snapshotter {
    static var liveServers: Bool { ProcessInfo.processInfo.arguments.contains("--live-servers") }

    /// Returns true when the step was one of the live ones (and has been handled).
    static func liveServerStep(_ name: String, app: AppState, dir: String) async -> Bool {
        guard name.hasPrefix("live-") else { return false }
        guard liveServers, let ref = app.allServers.first else { return true }
        let id = ref.id

        func waitForDeploy(_ limit: Double = 600) async {
            let deadline = Date().addingTimeInterval(limit)
            while app.isDeploying(id), Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1.5)) // the check that follows a deploy
            while app.serverChecking.contains(id) { try? await Task.sleep(for: .milliseconds(300)) }
        }
        func shot(_ file: String) async {
            try? await Task.sleep(for: .seconds(1.2))
            capture(to: "\(dir)/\(file).png")
        }
        func closeSheet() async {
            app.sheet = nil
            try? await Task.sleep(for: .seconds(0.7))
        }

        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "live-check":
            await app.checkServers(force: true)
        case "live-key":
            // What "Положить ключ на сервер" would run in Terminal (the password is typed there by the user).
            let server = ref.server
            if let key = await Task.detached(operation: { SSH.publicKey(create: true) }).value {
                try? SSH.installKeyCommand(server, publicKey: key).write(toFile: "\(dir)/install-key.txt", atomically: true, encoding: .utf8)
            }
        case "live-servers":
            app.screen = .week
            try? await Task.sleep(for: .seconds(0.4))
            app.screen = .servers
            try? await Task.sleep(for: .seconds(2))
            while !app.serverChecking.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            await shot(parts.count > 1 ? parts[1] : "live-servers")
        case "live-deploy", "live-cancel":
            app.screen = .servers
            let preview = await app.deployPreview(id)
            guard preview.problem == nil, let target = preview.target else {
                NSLog("live: preview problem: \(preview.problem ?? "no target")")
                app.sheet = .deploy(serverId: id)
                await shot("\(parts[0])-blocked")
                await closeSheet()
                return true
            }
            app.sheet = .deploy(serverId: id)
            try? await Task.sleep(for: .seconds(4))
            capture(to: "\(dir)/\(parts[0])-ready.png")
            await closeSheet()
            app.startDeploy(id, target: target, subject: preview.subject, trigger: .manual)
            app.sheet = .deploy(serverId: id)
            if parts[0] == "live-cancel" {
                try? await Task.sleep(for: .seconds(Double(parts.count > 1 ? parts[1] : "") ?? 6))
                capture(to: "\(dir)/live-cancel-before.png")
                app.cancelDeploy(id)
            } else {
                try? await Task.sleep(for: .seconds(5))
                capture(to: "\(dir)/live-deploy-running.png")
            }
            await waitForDeploy()
            await shot("\(parts[0])-done")
            await closeSheet()
        case "live-rollback":
            guard app.rollbackTarget(id) != nil else {
                NSLog("live: nothing to roll back to")
                return true
            }
            app.startRollback(id)
            try? await Task.sleep(for: .seconds(1))
            app.sheet = .deploy(serverId: id)
            await waitForDeploy()
            await shot("live-rollback-done")
            await closeSheet()
        case "live-auto":
            await app.checkServers(force: true)
            await app.checkAutoDeploys()
            let started = app.isDeploying(id)
            NSLog("live: auto deploy started: \(started)")
            if started {
                app.sheet = .deploy(serverId: id)
                await waitForDeploy()
                await shot("live-auto-done")
                await closeSheet()
            }
        case "live-log":
            app.sheet = .serverLog(serverId: id)
            try? await Task.sleep(for: .seconds(6))
            await shot("live-log")
            await closeSheet()
        case "live-signals":
            app.screen = .signals
            await shot(parts.count > 1 ? parts[1] : "live-signals")
        case "live-wait":
            try? await Task.sleep(for: .seconds(Double(parts.count > 1 ? parts[1] : "") ?? 5))
        case "live-state":
            // What Orbit believes right now, for checking against the server itself.
            struct Dump: Encodable {
                var status: [String: ServerStatus]
                var runs: [DeployRun]
                var signals: [Signal]
            }
            let dump = Dump(status: Dictionary(uniqueKeysWithValues: app.serverStatus.map { ($0.key.uuidString, $0.value) }),
                            runs: app.deployRuns, signals: app.signals.filter { $0.state == .active })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(dump).write(to: URL(fileURLWithPath: "\(dir)/\(parts.count > 1 ? parts[1] : "state").json"))
        default:
            break
        }
        return true
    }
}
#endif
