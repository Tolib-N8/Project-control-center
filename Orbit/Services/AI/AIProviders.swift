import Foundation
import Security

struct AIRequest {
    var system: String
    var prompt: String
    /// JSON Schema of the expected object (additionalProperties: false, every field required).
    var schema: [String: Any]
    var schemaName: String
}

enum AIError: LocalizedError {
    case notConfigured(String)
    case cliMissing(String)
    case provider(String)
    case badResponse(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): m
        case .cliMissing(let cli): "Не найден \(cli). Установите его и проверьте, что он запускается в терминале."
        case .provider(let m): m
        case .badResponse(let m): "Модель вернула неожиданный ответ: \(m)"
        case .refused(let m): "Модель отказалась отвечать: \(m)"
        }
    }
}

protocol AIProvider {
    var label: String { get }
    func complete(_ request: AIRequest) async throws -> [String: Any]
}

enum AIProviders {
    /// nil for the heuristics mode.
    static func make(_ config: AIConfig) throws -> AIProvider? {
        let model = config.model(for: config.provider)
        switch config.provider {
        case .heuristics:
            return nil
        case .claudeCode:
            return ClaudeCodeProvider(model: model, effort: config.effort)
        case .codexCLI:
            return CodexProvider(model: model)
        case .anthropicAPI:
            guard let key = Keychain.get(.anthropic), !key.isEmpty else {
                throw AIError.notConfigured("Добавьте ключ Anthropic API в настройках Orbit.")
            }
            return AnthropicProvider(apiKey: key, model: model, effort: config.effort)
        case .ollama:
            return OllamaProvider(baseURL: config.ollamaURL, model: model)
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: config.openAIBaseURL, apiKey: Keychain.get(.openAI), model: model)
        }
    }

    /// Cheap availability probe for onboarding / settings.
    static func availability(_ kind: AIProviderKind, config: AIConfig) async -> (ok: Bool, note: String) {
        switch kind {
        case .heuristics:
            return (true, "всегда доступно")
        case .claudeCode:
            let path = await Task.detached { Shell.which("claude") }.value
            return path.map { (true, "найден: \($0.abbreviatingHome)") } ?? (false, "claude не установлен")
        case .codexCLI:
            let path = await Task.detached { Shell.which("codex") }.value
            return path.map { (true, "найден: \($0.abbreviatingHome)") } ?? (false, "codex не установлен")
        case .anthropicAPI:
            return Keychain.get(.anthropic)?.isEmpty == false ? (true, "ключ сохранён") : (false, "нужен API-ключ")
        case .openAICompatible:
            return Keychain.get(.openAI)?.isEmpty == false ? (true, "ключ сохранён") : (false, "нужен API-ключ (для локальных серверов — не обязателен)")
        case .ollama:
            let models = await OllamaProvider.installedModels(baseURL: config.ollamaURL)
            if let models { return (true, models.isEmpty ? "запущена, моделей нет" : "моделей: \(models.count)") }
            return (false, "не запущена на \(config.ollamaURL)")
        }
    }

    static let testRequest = AIRequest(
        system: "Отвечай по-русски.",
        prompt: "Проверка связи. Ответь одним словом: готово.",
        schema: ["type": "object", "properties": ["reply": ["type": "string"]], "required": ["reply"], "additionalProperties": false],
        schemaName: "ping"
    )
}

// MARK: - Claude Code (subscription)

/// Runs `claude -p` headless. Uses whatever account Claude Code is logged into, so a Pro/Max
/// subscription works without an API key.
struct ClaudeCodeProvider: AIProvider {
    var model: String
    var effort: String
    var label: String { "Claude · \(model)" }

    func complete(_ request: AIRequest) async throws -> [String: Any] {
        var args = ["-p", "--output-format", "json",
                    "--tools", "",
                    "--no-session-persistence",
                    "--strict-mcp-config",
                    "--system-prompt", request.system,
                    "--json-schema", JSONText.encode(request.schema),
                    "--model", model]
        if !effort.isEmpty { args += ["--effort", effort] }
        // An empty working directory keeps project CLAUDE.md files out of the context.
        let sandbox = Store.root.appendingPathComponent("ai-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let prompt = request.prompt
        let result = await Task.detached { Shell.login("claude", args, cwd: sandbox.path, input: prompt, timeout: 300) }.value

        if result.status == 127 { throw AIError.cliMissing("claude") }
        guard let obj = JSONText.lastObject(in: result.stdout) else {
            let err = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if err.localizedCaseInsensitiveContains("login") || err.localizedCaseInsensitiveContains("auth") {
                throw AIError.provider("Claude Code не авторизован. Выполните `claude` в терминале и войдите в аккаунт с подпиской.")
            }
            throw AIError.provider("claude: \(err.prefix(300))")
        }
        if obj["is_error"] as? Bool == true {
            throw AIError.provider("Claude Code: \((obj["result"] as? String ?? "ошибка").prefix(300))")
        }
        if let structured = obj["structured_output"] as? [String: Any] { return structured }
        if let text = obj["result"] as? String, let parsed = JSONText.firstObject(in: text) { return parsed }
        throw AIError.badResponse(String(describing: obj["result"] ?? "").prefix(200).description)
    }
}

// MARK: - Codex CLI (ChatGPT subscription)

struct CodexProvider: AIProvider {
    var model: String
    var label: String { model.isEmpty ? "Codex" : "Codex · \(model)" }

    func complete(_ request: AIRequest) async throws -> [String: Any] {
        let dir = Store.root.appendingPathComponent("ai-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schemaURL = dir.appendingPathComponent("schema-\(UUID().uuidString).json")
        let outURL = dir.appendingPathComponent("out-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try JSONText.encode(request.schema).write(to: schemaURL, atomically: true, encoding: .utf8)
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never",
                    "--output-schema", schemaURL.path, "-o", outURL.path]
        if !model.isEmpty { args += ["-m", model] }
        args.append("-")
        let input = request.system + "\n\n" + request.prompt
        let result = await Task.detached { Shell.login("codex", args, cwd: dir.path, input: input, timeout: 600) }.value
        if result.status == 127 { throw AIError.cliMissing("codex") }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if let obj = JSONText.firstObject(in: text) { return obj }
        let err = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AIError.provider("codex: \(err.suffix(300))")
    }
}

// MARK: - Anthropic Messages API

struct AnthropicProvider: AIProvider {
    var apiKey: String
    var model: String
    var effort: String
    var label: String { "Claude API · \(model)" }

    /// Models that accept `fallbacks: "default"` (server-side refusal fallback).
    private var supportsFallback: Bool {
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1"].contains(model)
    }

    func complete(_ request: AIRequest) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": request.system,
            "messages": [["role": "user", "content": request.prompt]],
        ]
        var output: [String: Any] = ["format": ["type": "json_schema", "schema": request.schema]]
        // Haiku 4.5 rejects the effort parameter.
        if !model.contains("haiku") && !effort.isEmpty { output["effort"] = effort }
        body["output_config"] = output
        if supportsFallback { body["fallbacks"] = "default" }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if supportsFallback { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.provider("Anthropic API \(status): \(message)")
        }
        if obj["stop_reason"] as? String == "refusal" {
            let details = obj["stop_details"] as? [String: Any]
            throw AIError.refused(details?["explanation"] as? String ?? details?["category"] as? String ?? "без объяснения")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard let parsed = JSONText.firstObject(in: text) else { throw AIError.badResponse(String(text.prefix(200))) }
        return parsed
    }
}

// MARK: - Ollama

struct OllamaProvider: AIProvider {
    var baseURL: String
    var model: String
    var label: String { "Ollama · \(model)" }

    func complete(_ request: AIRequest) async throws -> [String: Any] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat") else {
            throw AIError.notConfigured("Неверный адрес Ollama: \(baseURL)")
        }
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": request.schema,
            "options": ["temperature": 0.2],
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.prompt]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch {
            throw AIError.provider("Ollama недоступна на \(baseURL). Запустите `ollama serve`.")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.provider("Ollama: \(obj["error"] as? String ?? "ошибка запроса")")
        }
        let text = (obj["message"] as? [String: Any])?["content"] as? String ?? ""
        guard let parsed = JSONText.firstObject(in: text) else { throw AIError.badResponse(String(text.prefix(200))) }
        return parsed
    }

    static func installedModels(baseURL: String) async -> [String]? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}

// MARK: - OpenAI-compatible

struct OpenAICompatibleProvider: AIProvider {
    var baseURL: String
    var apiKey: String?
    var model: String
    var label: String { model }

    func complete(_ request: AIRequest) async throws -> [String: Any] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw AIError.notConfigured("Неверный адрес API: \(baseURL)")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.prompt]],
            "response_format": ["type": "json_schema",
                                "json_schema": ["name": request.schemaName, "strict": true, "schema": request.schema]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.provider("API \(status): \(message)")
        }
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard let parsed = JSONText.firstObject(in: text) else { throw AIError.badResponse(String(text.prefix(200))) }
        return parsed
    }
}

// MARK: - Helpers

enum JSONText {
    static func encode(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first top-level JSON object in a text (tolerates code fences and prose around it).
    static func firstObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// The last line of output that parses as a JSON object (login shells may print noise first).
    static func lastObject(in output: String) -> [String: Any]? {
        for line in output.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { return obj }
        }
        return firstObject(in: output)
    }
}

/// API keys live in the login keychain, never in ~/.orbit.
enum Keychain {
    enum Account: String {
        case anthropic = "anthropic-api-key"
        case openAI = "openai-api-key"
    }

    private static let service = "dev.tolib.orbit"

    static func get(_ account: Account) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: Account) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
