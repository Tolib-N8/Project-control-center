import AppKit
import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Runs an executable synchronously. Call off the main thread.
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:],
                    input: String? = nil, timeout: TimeInterval = 60) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        // Output goes to temp files rather than pipes: with concurrent launches a sibling child can
        // inherit a pipe's write end and the reader would never see EOF.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("orbit-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("orbit-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ShellResult(status: -1, stdout: "", stderr: "temp files unavailable")
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        let inURL = tmp.appendingPathComponent("orbit-\(UUID().uuidString).in")
        if let input {
            try? input.write(to: inURL, atomically: true, encoding: .utf8)
            process.standardInput = (try? FileHandle(forReadingFrom: inURL)) ?? FileHandle.nullDevice
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? FileManager.default.removeItem(at: inURL) }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            try? outHandle.close()
            try? errHandle.close()
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        try? outHandle.close()
        try? errHandle.close()
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return ShellResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    @discardableResult
    static func git(_ repo: String, _ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        run("/usr/bin/git", ["-C", repo] + args, timeout: timeout)
    }

    /// Opens a terminal window in `directory` and runs `command` (if any) there.
    /// Uses a temporary .command file so no Automation permission is needed.
    static func openTerminal(at directory: String, command: String? = nil, app: String = "Terminal") {
        let dir = Store.root.appendingPathComponent("launch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("orbit-\(UUID().uuidString.prefix(8)).command")
        var script = "#!/bin/zsh -l\ncd \(quote(directory)) || exit 1\nclear\n"
        if let command { script += command + "\n" }
        script += "exec $SHELL -l\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        run("/usr/bin/open", ["-a", app, file.path])
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Finds agent CLIs (claude, codex) no matter how Orbit was started. Launched from the Dock or
/// relaunched by the updater, Orbit gets launchd's minimal PATH, and a non-interactive shell does
/// not read ~/.zshrc — where installers usually add ~/.local/bin.
enum CLILocator {
    private static let lock = NSLock()
    private static var found: [String: String] = [:]
    private static var cachedShellPATH: String?

    /// Where agent CLIs usually live, checked before asking the shell.
    static var candidateDirs: [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    /// Absolute path of a CLI, or nil. Successful lookups are cached for the session.
    static func path(for name: String) -> String? {
        lock.lock()
        if let hit = found[name] { lock.unlock(); return hit }
        lock.unlock()
        let fm = FileManager.default
        var result = candidateDirs.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
        if result == nil {
            // Ask the user's own shell the way their terminal would (interactive + login).
            let r = Shell.run(userShell, ["-ilc", "command -v \(name)"], timeout: 10)
            result = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
        }
        if let result {
            lock.lock(); found[name] = result; lock.unlock()
        }
        return result
    }

    /// PATH for running a CLI: its own folder, the user's interactive shell PATH and the defaults,
    /// so CLIs that call node, git and friends work the same as in the terminal.
    static func searchPATH(for executable: String) -> String {
        var parts = [(executable as NSString).deletingLastPathComponent]
        parts += shellPATH.split(separator: ":").map(String.init)
        parts += candidateDirs
        parts += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static var shellPATH: String {
        lock.lock()
        if let cached = cachedShellPATH { lock.unlock(); return cached }
        lock.unlock()
        let r = Shell.run(userShell, ["-ilc", "printf '%s' \"$PATH\""], timeout: 10)
        let value = r.stdout.split(separator: "\n").last.map(String.init) ?? ""
        lock.lock(); cachedShellPATH = value; lock.unlock()
        return value
    }

    private static var userShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// Runs a CLI by name with a PATH that matches the user's terminal.
    static func run(_ name: String, _ args: [String], cwd: String? = nil, input: String? = nil, timeout: TimeInterval) -> ShellResult? {
        guard let exe = path(for: name) else { return nil }
        return Shell.run(exe, args, cwd: cwd, env: ["PATH": searchPATH(for: exe)], input: input, timeout: timeout)
    }
}
