import Foundation

/// Where the analysis runs.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case heuristics, claudeCode, anthropicAPI, codexCLI, ollama, openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristics: tr("Локальные эвристики", "Local heuristics")
        case .claudeCode: tr("Claude · подписка", "Claude · subscription")
        case .anthropicAPI: "Claude API"
        case .codexCLI: tr("Codex · подписка ChatGPT", "Codex · ChatGPT subscription")
        case .ollama: "Ollama"
        case .openAICompatible: tr("OpenAI-совместимый API", "OpenAI-compatible API")
        }
    }

    var subtitle: String {
        switch self {
        case .heuristics: tr("Правила по git и логам. Офлайн и мгновенно, без моделей.", "Rules over git and logs. Offline and instant, no models.")
        case .claudeCode: tr("Через установленный Claude Code — расходует лимиты вашей подписки Pro / Max, ключ не нужен.", "Through your installed Claude Code — uses your Pro / Max subscription limits, no key needed.")
        case .anthropicAPI: tr("Напрямую через API Anthropic с вашим ключом, оплата по токенам.", "Directly through the Anthropic API with your key, billed per token.")
        case .codexCLI: tr("Через установленный Codex CLI и вашу подписку ChatGPT.", "Through your installed Codex CLI and your ChatGPT subscription.")
        case .ollama: tr("Локальная модель на этом Mac. Полностью офлайн, выводы проще.", "A local model on this Mac. Fully offline, simpler conclusions.")
        case .openAICompatible: tr("OpenAI, OpenRouter, LM Studio и любые совместимые серверы.", "OpenAI, OpenRouter, LM Studio and any compatible server.")
        }
    }

    var symbol: String {
        switch self {
        case .heuristics: "function"
        case .claudeCode: "terminal"
        case .anthropicAPI: "key"
        case .codexCLI: "terminal"
        case .ollama: "desktopcomputer"
        case .openAICompatible: "network"
        }
    }

    var usesModel: Bool { self != .heuristics }

    /// Default model per provider; CLI providers take their own aliases.
    var defaultModel: String {
        switch self {
        case .heuristics: ""
        case .claudeCode: "opus"
        case .anthropicAPI: "claude-opus-5-5"
        case .codexCLI: ""
        case .ollama: "llama3.1"
        case .openAICompatible: "gpt-5"
        }
    }

    var modelSuggestions: [String] {
        switch self {
        case .claudeCode: ["opus", "sonnet", "haiku", "fable"]
        case .anthropicAPI: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-fable-5-1"]
        case .ollama: ["llama3.1", "qwen2.5", "mistral"]
        default: []
        }
    }

    var needsKey: Bool { self == .anthropicAPI || self == .openAICompatible }
}

struct AIConfig: Codable, Hashable {
    init() {}

    var provider: AIProviderKind = .heuristics
    /// Model per provider (rawValue → model); empty means the provider default.
    var models: [String: String] = [:]
    var effort = "medium"
    var ollamaURL = "http://localhost:11434"
    var openAIBaseURL = "https://api.openai.com/v1"
    /// Re-analyse projects automatically after a refresh when their facts changed.
    var autoAnalyze = true
    /// Minimum hours between automatic re-analyses of one project.
    var minHoursBetweenRuns = 6.0
    /// Send diff contents (not only file names) when generating commit messages.
    var sendDiffs = false

    func model(for kind: AIProviderKind) -> String {
        let m = models[kind.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? kind.defaultModel : m
    }

    var isEnabled: Bool { provider != .heuristics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIConfig()
        provider = (try? c.decodeIfPresent(AIProviderKind.self, forKey: .provider)) ?? d.provider
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? d.models
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        openAIBaseURL = try c.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? d.openAIBaseURL
        autoAnalyze = try c.decodeIfPresent(Bool.self, forKey: .autoAnalyze) ?? d.autoAnalyze
        minHoursBetweenRuns = try c.decodeIfPresent(Double.self, forKey: .minHoursBetweenRuns) ?? d.minHoursBetweenRuns
        sendDiffs = try c.decodeIfPresent(Bool.self, forKey: .sendDiffs) ?? d.sendDiffs
    }
}
