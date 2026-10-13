import Foundation

/// Runs commands on a server through the system `ssh`. Never asks for a password: with `BatchMode`
/// a server that wants one fails at once, and Orbit explains how to install a key instead.
enum SSH {
    static let executable = "/usr/bin/ssh"

    /// Orbit's own key (~/.orbit/ssh/orbit_ed25519), created when a server doesn't let it in.
    /// It has no passphrase on purpose: checks and deploys run unattended, and nobody is there to type one.
    static var ownKey: String { Store.root.appendingPathComponent("ssh/orbit_ed25519").path }

    /// Shared connections live here, so a check every few minutes doesn't log in from scratch.
    static var controlDirectory: String { NSHomeDirectory() + "/.orbit/ssh" }

    static func arguments(_ server: ServerConfig, connectTimeout: Int = 8) -> [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "LogLevel=ERROR"]
        // A unix socket path can't be longer than ~104 bytes; %C adds 40.
        let control = controlDirectory + "/cm-%C"
        if control.utf8.count + 40 < 100 {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPath=\(control)", "-o", "ControlPersist=180"]
        }
        if FileManager.default.fileExists(atPath: ownKey) { args += ["-i", ownKey] }
        if let port = server.port, port > 0, port != 22 { args += ["-p", "\(port)"] }
        return args
    }

    /// The full argument list for running `script` with bash on the server (sh where there is no bash).
    /// The script travels as one quoted argument and stdin stays empty, so a command inside can't swallow the rest of it.
    static func command(_ server: ServerConfig, script: String, connectTimeout: Int = 8) -> [String] {
        let q = Shell.quote(script)
        let remote = "if command -v bash >/dev/null 2>&1; then exec bash -lc \(q); else exec sh -c \(q); fi"
        return arguments(server, connectTimeout: connectTimeout) + ["--", server.host.trimmingCharacters(in: .whitespaces), remote]
    }

    /// The folder for shared connections has to exist before ssh is started.
    static func prepare() {
        try? FileManager.default.createDirectory(atPath: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Runs a short script and waits for it. Call off the main thread.
    static func run(_ server: ServerConfig, script: String, timeout: TimeInterval = 30) -> ShellResult {
        prepare()
        return Shell.run(executable, command(server, script: script), timeout: timeout)
    }

    /// What went wrong, from ssh's own exit status (255) and message; nil when ssh itself worked.
    static func problem(_ result: ShellResult) -> (kind: SSHProblem, message: String)? {
        guard result.status == 255 || result.status == -1 else { return nil }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let line = text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let kind: SSHProblem
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            kind = .hostKey
        } else if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            kind = .auth
        } else if lower.contains("could not resolve hostname") || lower.contains("name or service not known") {
            kind = .unknownHost
        } else if lower.contains("connection refused") {
            kind = .refused
        } else if lower.contains("timed out") || lower.contains("no route to host") || lower.contains("network is unreachable")
                    || lower.contains("host is down") || result.status == -1 {
            kind = .timeout
        } else {
            kind = .other
        }
        return (kind, line)
    }

    /// How the server is written in ~/.ssh/known_hosts: "host", or "[host]:port" for a non-standard port.
    static func knownHostsName(_ server: ServerConfig) -> String {
        let host = server.host.trimmingCharacters(in: .whitespaces).split(separator: "@").last.map(String.init) ?? server.host
        if let port = server.port, port > 0, port != 22 { return "[\(host)]:\(port)" }
        return host
    }

    /// The command that forgets a server's old key, for when the server was reinstalled.
    static func forgetHostCommand(_ server: ServerConfig) -> String { "ssh-keygen -R \(Shell.quote(knownHostsName(server)))" }

    /// A hint for a step that failed because `sudo` wanted a password.
    static func sudoHint(_ output: String) -> String? {
        let lower = output.lowercased()
        guard lower.contains("sudo: a terminal is required") || lower.contains("sudo: a password is required")
                || lower.contains("sudo: no tty present") else { return nil }
        return tr("sudo просит пароль. Нужен вход под root или sudo без пароля для этой команды.",
                  "sudo asks for a password. Log in as root, or allow this command in sudo without one.")
    }

    // MARK: - Keys

    /// The public half of Orbit's own key, created on demand. The user's keys are tried first on every
    /// connection anyway (through ssh-agent); this one is for when they need a passphrase or don't exist.
    static func publicKey(create: Bool) -> String? {
        if FileManager.default.fileExists(atPath: ownKey), FileManager.default.fileExists(atPath: ownKey + ".pub") { return ownKey + ".pub" }
        guard create else { return nil }
        let dir = (ownKey as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(atPath: ownKey)
        try? FileManager.default.removeItem(atPath: ownKey + ".pub")
        let r = Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "orbit@\(Host.current().localizedName ?? "mac")", "-f", ownKey], timeout: 20)
        return r.ok ? ownKey + ".pub" : nil
    }

    /// A Terminal command that installs the key; the user types the server password there, Orbit never sees it.
    static func installKeyCommand(_ server: ServerConfig, publicKey: String) -> String {
        // -f: the key's private half sits next to it, so ssh-copy-id must not "test" it and skip the install.
        var parts = ["ssh-copy-id", "-f", "-i", Shell.quote(publicKey)]
        if let port = server.port, port > 0, port != 22 { parts += ["-p", "\(port)"] }
        parts.append(Shell.quote(server.host.trimmingCharacters(in: .whitespaces)))
        return parts.joined(separator: " ")
    }

    /// `ssh user@host` for "open in Terminal", landing in the project folder.
    static func terminalCommand(_ server: ServerConfig) -> String {
        var parts = ["ssh", "-t"]
        if let port = server.port, port > 0, port != 22 { parts += ["-p", "\(port)"] }
        parts.append(Shell.quote(server.host.trimmingCharacters(in: .whitespaces)))
        parts.append(Shell.quote("cd \(Shell.quote(server.directory)) 2>/dev/null; exec $SHELL -l"))
        return parts.joined(separator: " ")
    }
}
