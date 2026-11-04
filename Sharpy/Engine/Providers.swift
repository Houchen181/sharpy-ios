import Foundation

/// Where the learner's own API key sends Sharpy's AI requests. Nothing goes
/// through a Sharpy server: the phone talks to the provider directly.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case anthropic, openRouter, openCode, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode Zen"
        case .custom: "Other (OpenAI-compatible)"
        }
    }

    var blurb: String {
        switch self {
        case .anthropic:
            "Best fact-checking: Claude searches trusted sites itself and cites the exact lines it used."
        case .openRouter:
            "One key for hundreds of models from many labs. Sharpy fetches the sources itself."
        case .openCode:
            "OpenCode's curated model gateway. Sharpy fetches the sources itself."
        case .custom:
            "Any service that speaks the OpenAI chat API, including a model on your own computer."
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openCode: "https://opencode.ai/zen/v1"
        case .custom: ""
        }
    }

    /// Where to create a key.
    var keyPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .openCode: URL(string: "https://opencode.ai/zen")
        case .custom: nil
        }
    }

    /// Local servers often run without a key.
    var requiresKey: Bool { self != .custom }

    var keychainAccount: String { "apiKey.\(rawValue)" }

    var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "" }
}

/// Claude models offered for the Anthropic provider, with list prices in USD per
/// million tokens. Other providers list their own models.
struct ClaudeModel: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let inputPrice: Double
    let outputPrice: Double

    static let all = [
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "Most careful", inputPrice: 4, outputPrice: 20),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "Balanced", inputPrice: 2, outputPrice: 10),
        ClaudeModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "Cheapest", inputPrice: 0.1, outputPrice: 0.5),
    ]

    var priceLabel: String {
        func usd(_ x: Double) -> String { x < 1 ? String(format: "$%.2f", x) : String(format: "$%.0f", x) }
        return "\(usd(inputPrice)) in / \(usd(outputPrice)) out per million tokens"
    }

    static func find(_ id: String) -> ClaudeModel? { all.first { $0.id == id } }
}

/// How a request is shaped on the wire.
enum WireFormat {
    /// Anthropic Messages API (POST /messages).
    case anthropic
    /// OpenAI Chat Completions (POST /chat/completions), spoken by OpenRouter,
    /// OpenCode Zen and most gateways and local servers.
    case openAI
}

/// Everything needed to make one request: provider, endpoint, model and key.
struct ProviderConfig: Hashable {
    let kind: ProviderKind
    let baseURL: URL
    let model: String
    let key: String

    var wire: WireFormat {
        switch kind {
        case .anthropic: .anthropic
        // OpenCode Zen serves Claude models through its Anthropic-style /messages route.
        case .openCode: model.lowercased().hasPrefix("claude") ? .anthropic : .openAI
        case .openRouter, .custom: .openAI
        }
    }

    /// Claude's server-side web search with citations. Elsewhere Sharpy gathers
    /// source text itself and verifies every quote against it.
    var nativeWebSearch: Bool { kind == .anthropic }

    /// `fallbacks: "default"` reruns a request that a safety classifier declined by
    /// mistake on another Claude model. Not offered for Haiku.
    var serverFallback: Bool { kind == .anthropic && !model.contains("haiku") }

    var webSearchTool: String { model.contains("haiku") ? "web_search_20250305" : "web_search_20260209" }

    var displayName: String {
        let name = kind == .anthropic ? (ClaudeModel.find(model)?.name ?? model) : model
        return "\(name) via \(kind.title)"
    }
}
