import Foundation

/// Uploads recorded audio to the local Whisper server and returns the text. (Deepgram streams
/// instead: `DeepgramStream`.)
class LocalWhisperService {
    static let shared = LocalWhisperService()
    private init() {}

    // MARK: - Public API

    /// Transcribe an audio file on the local endpoint. No auth header is sent.
    func transcribe(
        fileURL: URL,
        endpoint: String,
        model: String,
        language: String = "en",
        timeout: TimeInterval = 120
    ) async throws -> String {

        print("[STT] Endpoint URL: \(endpoint)")
        print("[STT] Model: \(model)")
        print("[STT] Language: \(language)")
        print("[STT] Audio file: \(fileURL.path)")

        let url = try Self.requestURL(endpoint: endpoint, language: language)

        // Build multipart form request
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        // Read audio data
        let audioData = try Data(contentsOf: fileURL)
        guard audioData.count > 1000 else {
            throw STTError.audioTooShort
        }

        // Assemble multipart body
        var body = Data()

        // -- file field (Whisperapy names it "video")
        body.appendMultipart(boundary: boundary, name: "video",
                             filename: fileURL.lastPathComponent,
                             mimeType: "audio/wav", data: audioData)

        // -- model field
        body.appendMultipart(boundary: boundary, name: "model", value: model)

        // -- language (optional, helps accuracy)
        if !language.isEmpty {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }

        // -- response format
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")

        // Close boundary
        body.append(Data("--\(boundary)--\r\n".utf8))

        request.httpBody = body

        // Send request
        print("[STT] Sending request to \(url.absoluteString) (\(body.count) bytes)")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[STT] ERROR: Invalid response (not HTTP)")
            throw STTError.invalidResponse
        }

        print("[STT] Response status: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[STT] ERROR: API returned \(httpResponse.statusCode): \(errorBody)")
            throw STTError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse response
        let result = try parseTranscriptionResponse(data: data)
        print("[STT] Transcription successful (\(result.count) chars)")
        return result
    }

    /// GETs the local server's health endpoint; throws unless it answers 2xx within 5 seconds.
    func checkHealth(url urlString: String) async throws {
        guard let url = URL(string: urlString), !(url.host ?? "").isEmpty else {
            print("[STT] ERROR: Invalid health URL: \(urlString)")
            throw STTError.invalidEndpoint(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        print("[STT] Health check: \(urlString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[STT] Health check failed (\(httpResponse.statusCode)): \(body)")
            throw STTError.apiError(statusCode: httpResponse.statusCode, message: body)
        }
        print("[STT] Health check OK")
    }

    /// Sends one second of silence to a local endpoint so Settings can check the host, port and
    /// path. Returns the transcribed text (usually empty for silence); throws the same errors
    /// as a real transcription.
    func testLocalEndpoint(endpoint: String, model: String, language: String) async throws -> String {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicescribe-test-\(UUID().uuidString).wav")
        try Self.silentWAV(seconds: 1).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        print("[STT] Testing local endpoint: \(endpoint)")
        return try await transcribe(fileURL: fileURL, endpoint: endpoint, model: model,
                                    language: language, timeout: 15)
    }

    /// A 16kHz mono 16-bit PCM WAV of silence, the same format the recorder writes.
    nonisolated static func silentWAV(seconds: Double) -> Data {
        let sampleRate: UInt32 = 16_000
        let dataSize = UInt32(Double(sampleRate) * seconds) * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(Data("RIFF".utf8)); append(UInt32(36 + dataSize))
        wav.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                  // PCM, mono
        append(sampleRate); append(sampleRate * 2)            // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))                 // block align, bits per sample
        wav.append(Data("data".utf8)); append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }

    // MARK: - Request URL

    /// Builds the request URL. Whisperapy reads `language` from the query string and ignores the
    /// form field, while other Whisper servers read the form field, so both are sent. Internal (not
    /// private) for the unit tests.
    nonisolated static func requestURL(endpoint: String, language: String) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            print("[STT] ERROR: Invalid endpoint URL: \(endpoint)")
            throw STTError.invalidEndpoint(endpoint)
        }
        if !language.isEmpty {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "language", value: language)]
        }
        guard let url = components.url, !(components.host ?? "").isEmpty else {
            print("[STT] ERROR: Invalid endpoint URL: \(endpoint)")
            throw STTError.invalidEndpoint(endpoint)
        }
        return url
    }

    // MARK: - Parse Response

    private func parseTranscriptionResponse(data: Data) throws -> String {
        // Whisper-server JSON: { "text": "..." }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: plain text response (some local endpoints)
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw STTError.parseError
    }

    // MARK: - Errors

    enum STTError: LocalizedError {
        case invalidEndpoint(String)
        case audioTooShort
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint(let url):
                return "Invalid STT endpoint: \(url)"
            case .audioTooShort:
                return "Audio recording is too short. Please speak for at least 1 second."
            case .invalidResponse:
                return "Invalid response from STT server."
            case .apiError(let code, let msg):
                return "STT API error (\(code)): \(msg)"
            case .parseError:
                return "Could not parse transcription response."
            }
        }
    }
}

// MARK: - Data Multipart Helpers

extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
