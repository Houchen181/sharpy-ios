import Foundation

enum Effort: String {
    case low, medium, high
}

/// A failure whose message is fit to show the learner.
enum LLMError: LocalizedError {
    case noProvider
    case badKey(String)
    case noCredit
    case modelUnavailable(String)
    case badRequest(String)
    case rateLimited
    case overloaded
    case refused
    case truncated
    case unreadable
    case dailyLimit
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noProvider: "Connect an AI provider first, under You → AI provider."
        case .badKey(let provider): "\(provider) didn't accept your API key. Check it under You → AI provider."
        case .noCredit: "Your AI account is out of credit. Add credit with your provider, then try again."
        case .modelUnavailable(let model): "The model “\(model)” isn't available with this key. Pick another under You → AI provider."
        case .badRequest(let message): "The AI provider rejected the request: \(message)"
        case .rateLimited: "Your provider is rate-limiting requests. Wait a minute and try again."
        case .overloaded: "The AI service is busy right now. Try again shortly."
        case .refused: "The model declined to write about this. Try a different topic."
        case .truncated: "The model ran out of room before finishing. Try again."
        case .unreadable: "The model's reply wasn't in the expected format. Try again, or pick a more capable model."
        case .dailyLimit:
            "Sharpy has made \(UsageStore.dailyBatchCap) question sets today, its daily limit to protect your API bill. More tomorrow."
        case .other(let message): message
        }
    }
}

/// Talks to the learner's AI provider with their own key, straight from the phone.
/// Two wire formats: the Anthropic Messages API (which adds Claude's web search)
/// and OpenAI-style chat completions for OpenRouter, OpenCode Zen and the rest.
struct LLMClient {
    let config: ProviderConfig

    static let anthropicVersion = "2026-10-21"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Replies aren't streamed, so nothing arrives until the model has finished.
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    // MARK: Calls

    /// One request whose reply is JSON matching `schema`, decoded with snake_case keys.
    func json<T: Decodable>(_ type: T.Type, schemaName: String, system: String, user: String,
                            schema: [String: Any], effort: Effort) async throws -> T {
        let text: String
        switch config.wire {
        case .anthropic:
            let reply = try await messages([
                "system": system,
                "output_config": ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": schema]],
                "messages": [["role": "user", "content": user]],
            ])
            if (reply["stop_reason"] as? String) == "max_tokens" { throw LLMError.truncated }
            text = Self.text(of: reply)
        case .openAI:
            text = try await chatJSON(schemaName: schemaName, system: system, user: user, schema: schema)
        }
        return try Self.decode(T.self, from: text)
    }

    /// Claude researches with web search restricted to trusted domains. Returns every
    /// content block of the reply; the text blocks carry the citations.
    func webResearch(system: String, user: String, maxSearches: Int) async throws -> [[String: Any]] {
        var conversation: [[String: Any]] = [["role": "user", "content": user]]
        var blocks: [[String: Any]] = []
        for _ in 0..<4 {
            let reply = try await messages([
                "system": system,
                "output_config": ["effort": "medium"],
                "tools": [[
                    "type": config.webSearchTool,
                    "name": "web_search",
                    "max_uses": maxSearches,
                    "allowed_domains": TrustedSources.domains,
                ]],
                "messages": conversation,
            ])
            let content = reply["content"] as? [[String: Any]] ?? []
            blocks += content
            // A long server-tool turn can pause; sending it back lets Claude carry on.
            guard (reply["stop_reason"] as? String) == "pause_turn" else { break }
            conversation.append(["role": "assistant", "content": content])
        }
        return blocks
    }

    /// A cheap request proving that the key (and, where it costs nothing extra, the model) works.
    func validate() async throws {
        switch config.wire {
        case .anthropic where config.kind == .anthropic:
            // Listing models is free and checks the key; the model ids are Sharpy's own list.
            var request = URLRequest(url: config.baseURL.appending(path: "models")
                .appending(queryItems: [URLQueryItem(name: "limit", value: "1")]))
            request.setValue(config.key, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            _ = try await send(request)
        case .anthropic:
            _ = try await messages(["messages": [["role": "user", "content": "Reply with the word OK."]]], maxTokens: 64)
        case .openAI:
            _ = try await chat(system: "This is a connection test.", user: "Reply with the word OK.",
                               responseFormat: nil, maxTokens: 64)
        }
    }

    /// Model ids an OpenAI-style provider offers (GET /models).
    func listModels() async throws -> [String] {
        var request = URLRequest(url: config.baseURL.appending(path: "models"))
        if !config.key.isEmpty { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        let reply = try await send(request)
        let rows = reply["data"] as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Anthropic Messages

    private func messages(_ body: [String: Any], maxTokens: Int = 16000) async throws -> [String: Any] {
        var body = body
        body["model"] = config.model
        body["max_tokens"] = maxTokens
        if config.serverFallback { body["fallbacks"] = "default" }
        var request = URLRequest(url: config.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if config.kind != .anthropic { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "authorization") }
        if config.serverFallback { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let reply = try await send(request)
        let usage = reply["usage"] as? [String: Any] ?? [:]
        let input = Self.int(usage["input_tokens"]) + Self.int(usage["cache_creation_input_tokens"])
            + Self.int(usage["cache_read_input_tokens"])
        let output = Self.int(usage["output_tokens"])
        let searches = Self.int((usage["server_tool_use"] as? [String: Any])?["web_search_requests"])
        var dollars: Double?
        if config.kind == .anthropic, let model = ClaudeModel.find(config.model) {
            // Web search is billed at $10 per 1,000 searches.
            dollars = (Double(input) * model.inputPrice + Double(output) * model.outputPrice) / 1_000_000
                + Double(searches) * 0.01
        }
        UsageStore.record(input: input, output: output, searches: searches, dollars: dollars)
        if (reply["stop_reason"] as? String) == "refusal" { throw LLMError.refused }
        return reply
    }

    static func text(of reply: [String: Any]) -> String {
        let blocks = reply["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { (($0["type"] as? String) == "text") ? $0["text"] as? String : nil }.joined()
    }

    // MARK: OpenAI-style chat completions

    /// Asks for schema-enforced JSON; providers or models that don't support it get
    /// plain JSON mode, then a prompt that spells the schema out.
    private func chatJSON(schemaName: String, system: String, user: String, schema: [String: Any]) async throws -> String {
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let formats: [[String: Any]?] = [
            ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]],
            ["type": "json_object"],
            nil,
        ]
        var lastError: Error = LLMError.unreadable
        for (i, format) in formats.enumerated() {
            let prompt = i == 0 ? user : user + "\n\nReply with only a JSON object that follows this JSON Schema:\n" + schemaText
            do {
                let (text, finish) = try await chat(system: system, user: prompt, responseFormat: format)
                if finish == "length" { throw LLMError.truncated }
                return text
            } catch LLMError.badRequest(let message) {
                lastError = LLMError.badRequest(message)
            }
        }
        throw lastError
    }

    private func chat(system: String, user: String, responseFormat: [String: Any]?,
                      maxTokens: Int = 8192) async throws -> (String, String?) {
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if let responseFormat { body["response_format"] = responseFormat }
        if config.kind == .openRouter { body["usage"] = ["include": true] }
        var request = URLRequest(url: config.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        if config.kind == .openRouter {
            request.setValue("https://github.com/Houchen181/sharpy-ios", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Sharpy", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let reply = try await send(request)
        let usage = reply["usage"] as? [String: Any] ?? [:]
        UsageStore.record(input: Self.int(usage["prompt_tokens"]), output: Self.int(usage["completion_tokens"]),
                          searches: 0, dollars: Self.double(usage["cost"]))
        let choice = (reply["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        if text.isEmpty, message["refusal"] is String { throw LLMError.refused }
        return (text, choice["finish_reason"] as? String)
    }

    // MARK: Plumbing

    /// Sends with up to two retries for rate limits, overloads and dropped connections.
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await Self.session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(status), let object, object["error"] == nil { return object }
                // OpenRouter sometimes reports errors inside a 200 response.
                let code = (200..<300).contains(status) ? Self.errorCode(object) : status
                if [429, 500, 502, 503, 504, 529].contains(code), attempt < 2 {
                    attempt += 1
                    let hinted = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                    try await Task.sleep(for: .seconds(min(hinted ?? Double(3 * attempt * attempt), 20)))
                    continue
                }
                let message = Self.errorMessage(object) ?? String(decoding: data.prefix(300), as: UTF8.self)
                throw classify(code, message)
            } catch let error as URLError
                where attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                attempt += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func classify(_ status: Int, _ message: String) -> LLMError {
        switch status {
        case 401: return .badKey(config.kind.title)
        case 402: return .noCredit
        case 400 where message.lowercased().contains("credit balance"): return .noCredit
        case 400: return .badRequest(message)
        case 404: return .modelUnavailable(config.model)
        case 403: return .other("\(config.kind.title) refused the request: \(message)")
        case 429: return .rateLimited
        case 500...599: return .overloaded
        default: return .other("\(config.kind.title) returned an error (\(status)): \(message)")
        }
    }

    private static func errorMessage(_ object: [String: Any]?) -> String? {
        if let error = object?["error"] as? [String: Any] { return error["message"] as? String }
        return object?["error"] as? String
    }

    private static func errorCode(_ object: [String: Any]?) -> Int {
        let code = int((object?["error"] as? [String: Any])?["code"])
        return code == 0 ? 500 : code
    }

    static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Decodes the JSON object in a reply, ignoring any code fence or chatter around it.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            s = String(s[open...close])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(T.self, from: Data(s.utf8)) else { throw LLMError.unreadable }
        return value
    }
}
