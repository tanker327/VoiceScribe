import Foundation

/// Sends raw transcription text to an LLM for refinement.
class AIService {
    static let shared = AIService()
    private init() {}

    // MARK: - Fetch Models

    func fetchModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey(provider.rawValue) }

        let url: URL
        var request: URLRequest

        switch provider {
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/models")!
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            url = URL(string: "https://api.openai.com/v1/models")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xai:
            url = URL(string: "https://api.x.ai/v1/models")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpMethod = "GET"
        request.timeoutInterval = 15

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

        let modelIds = models.compactMap { $0["id"] as? String }.sorted()
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
        switch provider {
        case .claude:
            return try await refineClaude(text: text, systemPrompt: systemPrompt,
                                          apiKey: apiKey, model: model ?? provider.defaultModel)
        case .openai:
            return try await refineOpenAI(text: text, systemPrompt: systemPrompt,
                                          apiKey: apiKey, model: model ?? provider.defaultModel)
        case .xai:
            return try await refineXAI(text: text, systemPrompt: systemPrompt,
                                       apiKey: apiKey, model: model ?? provider.defaultModel)
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

    // MARK: - OpenAI

    private func refineOpenAI(text: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey("OpenAI") }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(provider: "OpenAI", statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let resultText = message["content"] as? String else {
            throw AIError.parseError("OpenAI")
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - xAI (Grok)

    private func refineXAI(text: String, systemPrompt: String, apiKey: String, model: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey("xAI") }

        let url = URL(string: "https://api.x.ai/v1/chat/completions")!
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

        print("[AIService] Sending refinement request to xAI (model: \(model))")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "Unknown"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[AIService] xAI API error (\(code)): \(errBody)")
            throw AIError.apiError(provider: "xAI", statusCode: code, message: errBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let resultText = message["content"] as? String else {
            throw AIError.parseError("xAI")
        }

        print("[AIService] xAI refinement complete")
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
