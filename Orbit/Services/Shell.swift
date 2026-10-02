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
    static func run(_ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 60) -> ShellResult {
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
        process.standardInput = FileHandle.nullDevice

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
