import Foundation

/// Sends raw transcription text to an LLM for refinement.
class AIService {
    static let shared = AIService()
    private init() {}

    private let anthropicVersion = "2023-06-01"

    // MARK: - Fetch Models

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey(provider.displayName) }

        guard let url = URL(string: "\(provider.baseURL)/v1/models") else {
            throw AIError.apiError(provider: provider.displayName, statusCode: 0, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        if provider == .claude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

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

    func refine(
        text: String,
        systemPrompt: String,
        provider: AIProvider,
        apiKey: String,
        model: String? = nil
    ) async throws -> String {
        let resolvedModel = model ?? provider.defaultModel
        switch provider {
        case .claude:
            return try await refineClaude(text: text, systemPrompt: systemPrompt,
                                          apiKey: apiKey, model: resolvedModel)
        case .openai, .xai:
            return try await refineOpenAICompatible(
                text: text, systemPrompt: systemPrompt, apiKey: apiKey,
                model: resolvedModel, provider: provider)
        }
    }

    // MARK: - Claude (Anthropic)

    private func refineClaude(text: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey("Claude") }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIError.apiError(provider: "Claude", statusCode: 0, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
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

    // MARK: - OpenAI-Compatible (OpenAI, xAI)

    private func refineOpenAICompatible(
        text: String, systemPrompt: String, apiKey: String,
        model: String, provider: AIProvider
    ) async throws -> String {
        let providerName = provider.displayName
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey(providerName) }

        guard let url = URL(string: "\(provider.baseURL)/v1/chat/completions") else {
            throw AIError.apiError(provider: providerName, statusCode: 0, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    /// Parses a Chat Completions response (OpenAI and xAI).
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
        case apiError(provider: String, statusCode: Int, message: String)
        case parseError(String)
        case refused(String)
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p):
                return "\(p) API key is required. Set it in Settings \u{2192} API Keys."
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
