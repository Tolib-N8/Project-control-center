import AppKit
import CryptoKit
import Foundation

/// Semantic version, compared numerically: 0.4.0 < 0.5.0 < 0.10.0.
struct SemVer: Comparable, CustomStringConvertible {
    var parts: [Int]

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        parts = nums.map { $0! }
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

struct ReleaseInfo: Equatable, Identifiable {
    var id: String { version }
    var version: String
    var notes: String
    var pageURL: URL?
    var assetURL: URL
    var assetName: String
    var sha256: String
    var size: Int
}

enum UpdateError: LocalizedError {
    case badResponse(String)
    case noAsset
    case noChecksum
    case checksumMismatch
    case invalidBundle(String)
    case notWritable(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let m): "Не удалось проверить обновления: \(m)"
        case .noAsset: "В релизе нет архива приложения."
        case .noChecksum: "У архива в релизе нет контрольной суммы — установка отменена."
        case .checksumMismatch: "Архив повреждён: контрольная сумма не совпадает. Установка отменена."
        case .invalidBundle(let m): "Скачанное приложение не прошло проверку: \(m)"
        case .notWritable(let path): "Нет прав на запись в \(path). Переместите Orbit в «Программы»."
        case .blocked(let reason): reason
        }
    }
}

/// Self-update from GitHub Releases: no third-party framework, no keys.
enum Updater {
    static let repo = "Tolib-N8/Project-control-center"
    static let assetPattern = #"^Orbit-.+-macOS\.zip$"#

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Debug builds only update when pointed at a test feed with `--update-feed <url>`.
    static var feedURL: URL {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--update-feed"), i + 1 < args.count, let url = URL(string: args[i + 1]) { return url }
        #endif
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--update-feed")
        #else
        return true
        #endif
    }

    /// nil when the app can replace itself where it runs; otherwise the reason.
    static var installBlocker: String? {
        let bundle = Bundle.main.bundlePath
        if bundle.contains("/AppTranslocation/") { return "Orbit запущен из временной папки macOS — переместите его в «Программы»." }
        let parent = (bundle as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: bundle) else {
            return UpdateError.notWritable(parent.abbreviatingHome).errorDescription
        }
        return nil
    }

    // MARK: - Check

    static func fetchLatest() async throws -> ReleaseInfo {
        var req = URLRequest(url: feedURL)
        req.timeoutInterval = 20
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Orbit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.badResponse("GitHub ответил \(http.statusCode)")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.badResponse("неожиданный ответ")
        }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.range(of: assetPattern, options: .regularExpression) != nil }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString) else {
            throw UpdateError.noAsset
        }
        guard let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { throw UpdateError.noChecksum }
        return ReleaseInfo(
            version: SemVer(tag)?.description ?? tag,
            notes: obj["body"] as? String ?? "",
            pageURL: (obj["html_url"] as? String).flatMap(URL.init(string:)),
            assetURL: url,
            assetName: asset["name"] as? String ?? "",
            sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
            size: asset["size"] as? Int ?? 0
        )
    }

    static func isNewer(_ release: ReleaseInfo, than current: String = currentVersion) -> Bool {
        guard let r = SemVer(release.version), let c = SemVer(current) else { return false }
        return r > c
    }

    // MARK: - Install

    /// Downloads, verifies and stages the update, then hands over to a helper that swaps the
    /// bundle once Orbit has quit. Returns normally only if the hand-off started.
    static func install(_ release: ReleaseInfo, progress: @escaping @MainActor (Double) -> Void) async throws {
        if let blocker = installBlocker { throw UpdateError.blocked(blocker) }
        let dir = Store.root.appendingPathComponent("updates", isDirectory: true)
        let staging = dir.appendingPathComponent("staging-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let zip = try await download(release.assetURL, to: staging.appendingPathComponent(release.assetName), progress: progress)
        try verifyChecksum(of: zip, expected: release.sha256)

        let unzip = await Task.detached { Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) }.value
        guard unzip.ok else { throw UpdateError.invalidBundle("не удалось распаковать архив") }
        let newApp = staging.appendingPathComponent("Orbit.app")
        try validate(newApp, expectedVersion: release.version)

        try launchSwapHelper(newApp: newApp.path, target: Bundle.main.bundlePath,
                             backup: dir.appendingPathComponent("previous/Orbit.app").path,
                             log: dir.appendingPathComponent("update.log").path)
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    return cont.resume(throwing: UpdateError.badResponse("загрузка вернула \(http.statusCode)"))
                }
                guard let tmp else { return cont.resume(throwing: UpdateError.badResponse("пустой ответ")) }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    cont.resume(returning: destination)
                } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in progress(value) }
            }
            task.resume()
        }
    }

    static func verifyChecksum(of file: URL, expected: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }
    }

    static func validate(_ app: URL, expectedVersion: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("нет Info.plist")
        }
        let bundleId = info["CFBundleIdentifier"] as? String
        guard bundleId == (Bundle.main.bundleIdentifier ?? "dev.tolib.orbit") else {
            throw UpdateError.invalidBundle("чужой идентификатор \(bundleId ?? "—")")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else { throw UpdateError.invalidBundle("версия \(version) вместо \(expectedVersion)") }
        guard let v = SemVer(version), let c = SemVer(currentVersion), v > c else {
            throw UpdateError.invalidBundle("версия \(version) не новее текущей")
        }
        let sign = Shell.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        guard sign.ok else { throw UpdateError.invalidBundle("подпись не прошла проверку") }
    }

    /// A detached script waits for Orbit to quit, keeps the old copy as a backup, puts the new
    /// bundle in place (restoring the old one if anything fails) and relaunches.
    static func launchSwapHelper(newApp: String, target: String, backup: String, log: String) throws {
        let script = """
        #!/bin/zsh
        pid="$1"; new="$2"; target="$3"; backup="$4"
        for i in {1..150}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        echo "$(date) updating $target"
        rm -rf "$backup"; mkdir -p "$(dirname "$backup")"
        if mv "$target" "$backup" && ditto "$new" "$target"; then
          xattr -dr com.apple.quarantine "$target" 2>/dev/null
          echo "$(date) installed"
        else
          echo "$(date) failed, restoring previous version"
          rm -rf "$target"; mv "$backup" "$target"
        fi
        open "$target"
        """
        let scriptURL = URL(fileURLWithPath: log).deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp, target, backup]
        FileManager.default.createFile(atPath: log, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}
