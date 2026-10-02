import Foundation

/// JSON persistence under ~/.orbit
enum Store {
    /// ~/.orbit, or `--data-dir <path>` (used for debugging with a throwaway state).
    static var root: URL = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".orbit", isDirectory: true)
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        do { return try decoder.decode(T.self, from: data) } catch {
            NSLog("Orbit: failed to decode \(name): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String, pretty: Bool = true) {
        do {
            let target = url(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try (pretty ? encoder : compactEncoder).encode(value)
            try data.write(to: target, options: .atomic)
        } catch {
            NSLog("Orbit: failed to save \(name): \(error)")
        }
    }
}
