import Foundation

/// Sends raw transcription text to an LLM for refinement.
class AIService {
    static let shared = AIService()
    private init() {}

    // MARK: - Fetch Models

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey(provider.rawValue) }

        let url = URL(string: "\(provider.baseURL)/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        if provider == .claude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        print("[AIService] Fetching models from \(provider.rawValue)...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: provider.rawValue, statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw AIError.parseError(provider.rawValue)
        }

        var modelIds = models.compactMap { $0["id"] as? String }

        // OpenAI returns all models (embeddings, TTS, DALL-E, etc.) — filter to chat-capable ones
        if provider == .openai {
            modelIds = modelIds.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o1") || $0.hasPrefix("o3") || $0.hasPrefix("o4") }
        }

        modelIds.sort()
        print("[AIService] Loaded \(modelIds.count) models from \(provider.rawValue)")
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

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: "Claude", statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let resultText = first["text"] as? String else {
            throw AIError.parseError("Claude")
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI-Compatible (OpenAI, xAI)

    private func refineOpenAICompatible(
        text: String, systemPrompt: String, apiKey: String,
        model: String, provider: AIProvider
    ) async throws -> String {
        let providerName = provider.rawValue
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey(providerName) }

        let url = URL(string: "\(provider.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[AIService] Sending refinement request to \(providerName) (model: \(model))")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: providerName, statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let resultText = message["content"] as? String else {
            throw AIError.parseError(providerName)
        }

        print("[AIService] \(providerName) refinement complete")
        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum AIError: LocalizedError {
        case missingAPIKey(String)
        case apiError(provider: String, statusCode: Int, message: String)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let p):
                return "\(p) API key is required. Set it in Settings → API Keys."
            case .apiError(let p, let code, let msg):
                return "\(p) API error (\(code)): \(msg)"
            case .parseError(let p):
                return "Could not parse \(p) response."
            }
        }
    }
}
