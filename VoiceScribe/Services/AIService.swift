import Foundation

/// Sends raw transcription text to an LLM for refinement.
class AIService {
    static let shared = AIService()
    private init() {}

    nonisolated static let anthropicVersion = "2023-06-01"

    // MARK: - Fetch Models

    /// Lists the models behind `baseURL` so Settings can offer a picker. `baseURL` is the
    /// provider's endpoint root (see `endpointURL`).
    func fetchModels(provider: AIProvider, apiKey: String, baseURL: String) async throws -> [String] {
        if provider.requiresAPIKey && apiKey.isEmpty { throw AIError.missingAPIKey(provider.displayName) }

        let url = try Self.endpointURL(base: baseURL, path: "models", providerName: provider.displayName)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        authorize(&request, provider: provider, apiKey: apiKey)

        print("[AIService] Fetching models from \(provider.displayName)...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: provider.displayName, statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw AIError.parseError(provider.displayName)
        }

        var modelIds = models.compactMap { $0["id"] as? String }

        // OpenAI returns all models (embeddings, TTS, DALL-E, etc.) — filter to chat-capable ones
        if provider == .openai {
            modelIds = modelIds.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o1") || $0.hasPrefix("o3") || $0.hasPrefix("o4") }
        }

        modelIds.sort()
        print("[AIService] Loaded \(modelIds.count) models from \(provider.displayName)")
        return modelIds
    }

    // MARK: - Public API

    /// `baseURL` is the provider's endpoint root: `AIProvider.baseURL` for the built-in services
    /// or the user's Base URL for the OpenAI-compatible endpoint (`AppState.currentAIBaseURL`).
    func refine(
        text: String,
        systemPrompt: String,
        provider: AIProvider,
        apiKey: String,
        baseURL: String,
        model: String? = nil
    ) async throws -> String {
        let resolvedModel = model ?? provider.defaultModel
        guard !resolvedModel.isEmpty else { throw AIError.missingModel(provider.displayName) }

        switch provider {
        case .claude:
            return try await refineClaude(text: text, systemPrompt: systemPrompt,
                                          apiKey: apiKey, baseURL: baseURL, model: resolvedModel)
        case .openai, .xai, .openAICompatible:
            return try await refineOpenAICompatible(
                text: text, systemPrompt: systemPrompt, apiKey: apiKey,
                baseURL: baseURL, model: resolvedModel, provider: provider)
        }
    }

    // MARK: - Claude (Anthropic)

    private func refineClaude(text: String, systemPrompt: String, apiKey: String,
                              baseURL: String, model: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey("Claude") }

        let url = try Self.endpointURL(base: baseURL, path: "messages", providerName: "Claude")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, provider: .claude, apiKey: apiKey)
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            // Current models think before answering and thinking counts toward max_tokens,
            // so leave ample room; a cut-off answer is reported via stop_reason below.
            "max_tokens": 16000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[AIService] Sending refinement request to Claude (model: \(model))")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: "Claude", statusCode: code, message: errBody)
        }

        let resultText = try Self.parseClaudeResponse(data)
        print("[AIService] Claude refinement complete")
        return resultText
    }

    // MARK: - OpenAI-Compatible (OpenAI, xAI, self-hosted endpoints)

    private func refineOpenAICompatible(
        text: String, systemPrompt: String, apiKey: String,
        baseURL: String, model: String, provider: AIProvider
    ) async throws -> String {
        let providerName = provider.displayName
        if provider.requiresAPIKey && apiKey.isEmpty { throw AIError.missingAPIKey(providerName) }

        let url = try Self.endpointURL(base: baseURL, path: "chat/completions", providerName: providerName)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, provider: provider, apiKey: apiKey)
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        if Self.supportsTemperature(model: model) {
            body["temperature"] = 0.3
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[AIService] Sending refinement request to \(providerName) (model: \(model))")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: providerName, statusCode: code, message: errBody)
        }

        let resultText = try Self.parseChatCompletionResponse(data, provider: providerName)
        print("[AIService] \(providerName) refinement complete")
        return resultText
    }

    private func authorize(_ request: inout URLRequest, provider: AIProvider, apiKey: String) {
        for (field, value) in Self.authorizationHeaders(provider: provider, apiKey: apiKey) {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    /// Claude uses its own header pair; everything else is a Bearer token, which is left out
    /// when the OpenAI-compatible endpoint was configured without a key. Internal for the tests.
    nonisolated static func authorizationHeaders(provider: AIProvider, apiKey: String) -> [String: String] {
        switch provider {
        case .claude:
            return ["x-api-key": apiKey, "anthropic-version": anthropicVersion]
        case .openai, .xai, .openAICompatible:
            return apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        }
    }

    /// Joins an endpoint root and a path. The root is `AIProvider.baseURL` or, for the
    /// OpenAI-compatible endpoint, the user's Base URL, which must already include the version
    /// prefix the server expects (usually `/v1`, as in `http://192.168.10.7:8080/v1`). Whitespace
    /// and trailing slashes are dropped. Internal (not private) for the unit tests.
    nonisolated static func endpointURL(base: String, path: String, providerName: String) throws -> URL {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty,
              let url = URL(string: "\(root)/\(path)"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            print("[AIService] ERROR: Invalid base URL for \(providerName): \(base)")
            throw AIError.invalidBaseURL(providerName)
        }
        return url
    }

    /// OpenAI's reasoning models (o-series, GPT-5) reject any non-default `temperature` with a 400.
    /// `fetchModels()` deliberately lists them, so the request must adapt.
    nonisolated static func supportsTemperature(model: String) -> Bool {
        let reasoningPrefixes = ["o1", "o3", "o4", "gpt-5"]
        return !reasoningPrefixes.contains { model.hasPrefix($0) }
    }

    // MARK: - Response Parsing

    /// Parses a Messages API response. Internal (not private) so the unit tests can cover the
    /// thinking-block, refusal and truncation cases without a network call.
    nonisolated static func parseClaudeResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError.parseError("Claude")
        }

        // Safety classifiers answer with HTTP 200, stop_reason "refusal" and possibly empty content.
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            throw AIError.refused("Claude")
        }

        // Current models put a `thinking` block before the answer, so take the first `text` block.
        guard let resultText = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw AIError.parseError("Claude")
        }

        // Never hand back a cut-off answer as if it were complete; it would be auto-copied.
        if stopReason == "max_tokens" {
            throw AIError.truncated("Claude")
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a Chat Completions response (OpenAI, xAI and OpenAI-compatible servers).
    nonisolated static func parseChatCompletionResponse(_ data: Data, provider: String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let resultText = message["content"] as? String else {
            throw AIError.parseError(provider)
        }

        if first["finish_reason"] as? String == "length" {
            throw AIError.truncated(provider)
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum AIError: LocalizedError {
        case missingAPIKey(String)
        case invalidBaseURL(String)
        case missingModel(String)
        case apiError(provider: String, statusCode: Int, message: String)
        case parseError(String)
        case refused(String)
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p):
                return "\(p) API key is required. Set it in Settings \u{2192} API Keys."
            case .invalidBaseURL(let p):
                return "\(p) base URL is missing or invalid. Set it in Settings \u{2192} AI & General, for example http://192.168.10.7:8080/v1."
            case .missingModel(let p):
                return "\(p) model is not set. Enter a model id in Settings \u{2192} AI & General, or press Load Models."
            case .refused(let p):
                return "\(p) declined this request. Try another mode or model."
            case .truncated(let p):
                return "\(p) ran out of output tokens before finishing. Try a shorter recording or the Summarize mode."
            case .apiError(let p, let code, let msg):
                return "\(p) API error (\(code)): \(msg)"
            case .parseError(let p):
                return "Could not parse \(p) response."
            }
        }
    }
}
