import Foundation

/// Sends raw transcription text to an LLM for refinement.
class AIService {
    static let shared = AIService()
    private init() {}

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
