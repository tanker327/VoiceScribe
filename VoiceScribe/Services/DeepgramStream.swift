import Foundation

/// One live Deepgram Nova-3 transcription. The WebSocket opens when recording starts, audio goes
/// out as 16 kHz mono PCM16 chunks while Deepgram sends back interim and final results, and after
/// Stop `finish` flushes the stream and returns the transcript.
///
/// The microphone starts without waiting for the handshake: chunks wait in `pendingAudio` until the
/// socket opens, so nothing said in the first few hundred milliseconds is lost.
///
/// Explicitly `@MainActor`: as an `NSObject` subclass it would otherwise not get the module's
/// default isolation, and its tasks (receive loop, KeepAlive, finalize timer) would run off the main actor.
@MainActor
final class DeepgramStream: NSObject, URLSessionWebSocketDelegate {
    /// Called after every result with the transcript so far, also while finalizing.
    var onUpdate: ((TranscriptAccumulator) -> Void)?
    /// Called once while recording if Deepgram refuses the connection (bad key or parameter).
    /// Nothing at Stop could fix that, so the caller ends the recording.
    var onRejected: ((DeepgramError) -> Void)?

    /// Why the stream failed, if it did. Text that arrived before the failure is kept.
    private(set) var failure: DeepgramError?

    private let apiKey: String
    private let languageMode: DeepgramLanguageMode
    private let keyterms: [String]

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var transcript = TranscriptAccumulator()
    private var pendingAudio: [Data] = []
    private var isOpen = false
    /// Set at Stop. Audio after it is dropped: Deepgram rejects audio that follows CloseStream.
    private var isClosing = false
    private var isClosed = false
    private var wasCancelled = false
    private var connectStartedAt = ContinuousClock.now
    private var closeStartedAt = ContinuousClock.now
    /// When the last server message arrived (or the socket opened, or Stop was pressed).
    private var lastActivity = ContinuousClock.now
    private var sentChunks = 0
    private var sentBytes = 0
    private var keepAliveTask: Task<Void, Never>?
    private var finishTimerTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(apiKey: String, languageMode: DeepgramLanguageMode, keyterms: [String]) throws {
        guard !apiKey.isEmpty else { throw DeepgramError.missingAPIKey }
        self.apiKey = apiKey
        self.languageMode = languageMode
        self.keyterms = keyterms
        super.init()
    }

    // MARK: - Public API

    /// Opens the WebSocket. Audio passed to `send` before it opens is buffered.
    func connect() {
        let url = Self.listenURL(streaming: true, languageMode: languageMode, keyterms: keyterms)
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        // Delegate callbacks on the main queue, so they run on the main actor like everything else here.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        connectStartedAt = .now

        print("[Deepgram] Connecting: \(url.absoluteString)")
        task.resume()
        Task { await receiveLoop(task) }
    }

    /// Sends one PCM16 chunk, or buffers it until the socket opens.
    func send(_ chunk: Data) {
        guard !isClosing, !isClosed, failure == nil else { return }
        if isOpen {
            sendAudio(chunk)
        } else {
            pendingAudio.append(chunk)
        }
    }

    /// Ends the stream after Stop and returns the transcript. If the stream failed for any reason
    /// other than a rejection, the recording at `fallbackFile` goes to the pre-recorded endpoint
    /// instead, so a dropped connection loses no speech.
    func finish(fallbackFile: URL) async throws -> String {
        let streamed = await finishStreaming()
        guard let failure, !wasCancelled else { return streamed }
        if failure.isRejection { throw failure }
        print("[Deepgram] Stream failed (\(failure.localizedDescription)); uploading the recording instead")
        return try await Self.transcribeFile(fallbackFile, apiKey: apiKey,
                                             languageMode: languageMode, keyterms: keyterms)
    }

    /// Drops the stream without waiting for results (Abort, Clear, window closed).
    func cancel() {
        guard !isClosed else { return }
        wasCancelled = true
        print("[Deepgram] Cancelled")
        resolveFinish("cancellation")
        close()
    }

    /// Streams one second of silence and closes. A wrong key or query parameter makes Deepgram
    /// refuse the handshake, so this checks every setting. Used by Settings' Test Connection.
    static func testConnection(apiKey: String, languageMode: DeepgramLanguageMode, keyterms: [String]) async throws {
        let stream = try DeepgramStream(apiKey: apiKey, languageMode: languageMode, keyterms: keyterms)
        stream.connect()
        stream.send(Data(count: 32_000))   // 1 s of 16 kHz PCM16 silence, buffered until open
        _ = await stream.finishStreaming()
        if let failure = stream.failure { throw failure }
        print("[Deepgram] Test connection OK")
    }

    // MARK: - Finalize

    /// Sends CloseStream, then waits for the first of: Metadata (Deepgram's last message), the
    /// socket closing, 1.5 s without a message, or a 5 s cap. Any interim left then becomes final.
    private func finishStreaming() async -> String {
        // The tap queues chunks on the main queue. Give the ones queued before the tap was removed
        // one turn to go out first: they hold the last word.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        if !isClosed && failure == nil {
            isClosing = true
            keepAliveTask?.cancel()
            closeStartedAt = .now
            lastActivity = .now
            let seconds = String(format: "%.1f", Double(sentBytes + pendingAudio.reduce(0) { $0 + $1.count }) / 32_000)
            print("[Deepgram] CloseStream after \(sentChunks) chunks (\(seconds) s of audio)\(isOpen ? "" : ", once connected")")
            // Not open yet: didOpen flushes the buffered audio and sends CloseStream after it.
            if isOpen { sendControl("CloseStream") }

            await withCheckedContinuation { continuation in
                finishContinuation = continuation
                startFinishTimer()
            }
        }

        transcript.promoteInterim()
        close()
        print("[Deepgram] Transcript ready (\(transcript.text.count) chars)")
        return transcript.text
    }

    private func startFinishTimer() {
        let started = ContinuousClock.now
        finishTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - started >= .seconds(5) {
                    if !self.isOpen {
                        self.fail(.connectionLost("timed out while connecting"))
                    }
                    self.resolveFinish("the 5 s cap")
                    return
                }
                // Counted only once open: before that, silence just means a slow handshake.
                if self.isOpen, ContinuousClock.now - self.lastActivity >= .milliseconds(1500) {
                    self.resolveFinish("1.5 s without a message")
                    return
                }
            }
        }
    }

    private func resolveFinish(_ reason: String) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        finishTimerTask?.cancel()
        print("[Deepgram] Finalized by \(reason), \(milliseconds(since: closeStartedAt)) ms after Stop")
        continuation.resume()
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        keepAliveTask?.cancel()
        finishTimerTask?.cancel()
        onUpdate = nil
        onRejected = nil
        pendingAudio.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        // The session keeps its delegate (self) alive until it is invalidated.
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func fail(_ error: DeepgramError) {
        guard failure == nil, !isClosed else { return }
        failure = error
        print("[Deepgram] ERROR: \(error.localizedDescription)")
        if error.isRejection && !isClosing {
            onRejected?(error)
        }
        resolveFinish("an error")
    }

    // MARK: - Socket

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        // The session delivers delegate calls on the main queue (see connect()).
        MainActor.assumeIsolated {
            guard webSocketTask === task else { return }
            didOpen()
        }
    }

    private func didOpen() {
        guard !isClosed else { return }
        isOpen = true
        lastActivity = .now
        print("[Deepgram] Connected in \(milliseconds(since: connectStartedAt)) ms; flushing \(pendingAudio.count) buffered chunks")

        // At once: the server drops a connection that stays silent at the start.
        sendControl("KeepAlive")
        pendingAudio.forEach(sendAudio)
        pendingAudio.removeAll()

        if isClosing {
            sendControl("CloseStream")   // Stop came before the handshake finished
        } else {
            startKeepAlive()
        }
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, !self.isClosing, !self.isClosed else { return }
                self.sendControl("KeepAlive")
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !isClosed {
            do {
                let message = try await task.receive()
                guard !isClosed else { return }
                lastActivity = .now
                switch message {
                case .string(let text): handle(text)
                case .data(let data):   handle(String(decoding: data, as: UTF8.self))
                @unknown default:       break
                }
            } catch {
                guard !isClosed else { return }
                receiveEnded(task: task, error: error)
                return
            }
        }
    }

    /// The socket stopped delivering messages: a close frame, a refused handshake, or a network
    /// failure. Only a normal close after CloseStream is a clean end.
    private func receiveEnded(task: URLSessionWebSocketTask, error: Error) {
        let code = task.closeCode
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if code == .normalClosure || code == .noStatusReceived {
            if isClosing {
                print("[Deepgram] Server closed the stream (\(code.rawValue))")
                resolveFinish("the socket closing")
            } else {
                fail(.connectionLost("the server closed the stream early"))
            }
        } else if code != .invalid {
            fail(.connectionLost("the server closed the stream (\(code.rawValue)\(reason.isEmpty ? "" : " \(reason)"))"))
        } else {
            fail(Self.connectionError(response: task.response, underlying: error))
        }
    }

    private func handle(_ text: String) {
        switch Self.parseEvent(text) {
        case .results(let segment, let isFinal):
            transcript.apply(segment, isFinal: isFinal)
            if isFinal && !segment.isEmpty {
                print("[Deepgram] Final segment (\(segment.count) chars)")
            }
            onUpdate?(transcript)
        case .metadata(let requestID):
            print("[Deepgram] Metadata, request_id \(requestID)")
            if isClosing { resolveFinish("Metadata") }
        case .error(let message):
            fail(.streamError(message))
        case .ignored:
            break   // UtteranceEnd, SpeechStarted
        }
    }

    private func sendAudio(_ chunk: Data) {
        sendFrame(.data(chunk))
        sentChunks += 1
        sentBytes += chunk.count
    }

    private func sendControl(_ type: String) {
        sendFrame(.string("{\"type\":\"\(type)\"}"))
    }

    private func sendFrame(_ message: URLSessionWebSocketTask.Message) {
        task?.send(message) { error in
            // A dead socket also ends the receive loop, which reports the failure.
            if let error { print("[Deepgram] Send failed: \(error.localizedDescription)") }
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    // MARK: - Requests

    /// The listen URL. Both endpoints take the model, language, formatting and keyterms; only the
    /// stream needs the raw-audio format and the interim and endpointing options. Internal (not
    /// private) for the unit tests.
    nonisolated static func listenURL(streaming: Bool, languageMode: DeepgramLanguageMode, keyterms: [String]) -> URL {
        var components = URLComponents()
        components.scheme = streaming ? "wss" : "https"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"

        var items = [URLQueryItem(name: "model", value: "nova-3")]
        items += languageMode.queryItems
        items.append(URLQueryItem(name: "smart_format", value: "true"))
        if streaming {
            items += [
                // Raw PCM has no header, so Deepgram has to be told its format.
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "channels", value: "1"),
                URLQueryItem(name: "interim_results", value: "true"),
                // 300 ms of silence ends a phrase; the 10 ms default splits mid-sentence.
                URLQueryItem(name: "endpointing", value: "300"),
            ]
        }
        items += keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = items
        // URLComponents leaves "+" as is, but Deepgram reads it as a space ("C++" would become "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        guard let url = components.url else { preconditionFailure("Deepgram listen URL is malformed") }
        return url
    }

    /// The error for a connection that ended without a close frame. An HTTP status means Deepgram
    /// refused the upgrade, and its `dg-error` header says why; no response means the network
    /// failed. Internal for the unit tests.
    nonisolated static func connectionError(response: URLResponse?, underlying: Error) -> DeepgramError {
        if let http = response as? HTTPURLResponse, http.statusCode != 101 {
            let reason = http.value(forHTTPHeaderField: "dg-error")
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            return .apiError(statusCode: http.statusCode, message: reason)
        }
        return .connectionLost(underlying.localizedDescription)
    }

    // MARK: - Parse Messages

    enum Event: Equatable {
        case results(transcript: String, isFinal: Bool)
        case metadata(requestID: String)
        case error(String)
        case ignored(String)
    }

    /// Reads one server message. Internal for the unit tests.
    nonisolated static func parseEvent(_ text: String) -> Event {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .ignored("not JSON")
        }
        let type = json["type"] as? String ?? ""
        switch type {
        case "Results":
            let channel = json["channel"] as? [String: Any]
            let alternatives = channel?["alternatives"] as? [[String: Any]]
            let transcript = alternatives?.first?["transcript"] as? String ?? ""
            return .results(transcript: transcript, isFinal: json["is_final"] as? Bool ?? false)
        case "Metadata":
            return .metadata(requestID: json["request_id"] as? String ?? "")
        case "Error":
            return .error(json["description"] as? String ?? json["message"] as? String ?? "Unknown error")
        default:
            return .ignored(type)
        }
    }

    // MARK: - Pre-recorded Fallback

    /// Transcribes a recorded WAV with `POST /v1/listen`, using the stream's model, language and
    /// keyterms. The WAV header tells Deepgram the audio format.
    static func transcribeFile(_ fileURL: URL, apiKey: String, languageMode: DeepgramLanguageMode,
                               keyterms: [String]) async throws -> String {
        let audio = try Data(contentsOf: fileURL)
        let url = listenURL(streaming: false, languageMode: languageMode, keyterms: keyterms)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        print("[Deepgram] Uploading \(audio.count) bytes to \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.upload(for: request, from: audio)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.invalidResponse
        }
        print("[Deepgram] Upload response status: \(httpResponse.statusCode)")
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["err_msg"] as? String
            throw DeepgramError.apiError(statusCode: httpResponse.statusCode, message: message ?? body)
        }
        let text = try parsePrerecordedResponse(data)
        print("[Deepgram] Upload transcription successful (\(text.count) chars)")
        return text
    }

    /// Reads `results.channels[0].alternatives[0].transcript`. Internal for the unit tests.
    nonisolated static func parsePrerecordedResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else {
            throw DeepgramError.parseError
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum DeepgramError: LocalizedError {
        case missingAPIKey
        case apiError(statusCode: Int, message: String)
        case connectionLost(String)
        case streamError(String)
        case invalidResponse
        case parseError

        /// A 4xx: the key or a query parameter is wrong, so neither waiting nor uploading the
        /// recording with the same settings can work.
        var isRejection: Bool {
            if case .apiError(let code, _) = self { return (400...499).contains(code) }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Deepgram API key is required. Set it in Settings → API Keys."
            case .apiError(let code, _) where code == 401 || code == 403:
                return "Deepgram rejected the API key (\(code)). Check it in Settings → API Keys."
            case .apiError(let code, let msg):
                return "Deepgram API error (\(code)): \(msg)"
            case .connectionLost(let reason):
                return "Lost the connection to Deepgram: \(reason)."
            case .streamError(let msg):
                return "Deepgram error: \(msg)"
            case .invalidResponse:
                return "Invalid response from Deepgram."
            case .parseError:
                return "Could not parse the Deepgram response."
            }
        }
    }
}

// MARK: - Transcript Accumulator

/// The transcript of one stream. Deepgram's final results are consecutive segments, each covering
/// only newly finalized audio, so they are appended. An interim result covers the audio since the
/// last final one and is replaced by the next result.
struct TranscriptAccumulator {
    private(set) var committed = ""
    private(set) var interim = ""

    /// The finished segments followed by the one still being recognized.
    var text: String { Self.join(committed, interim) }

    /// UTF-16 length of the interim tail of `text`, joining space included: the part the editor dims.
    var interimLength: Int { text.utf16.count - committed.utf16.count }

    mutating func apply(_ segment: String, isFinal: Bool) {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            committed = Self.join(committed, segment)
            interim = ""
        } else {
            interim = segment
        }
    }

    /// Makes the interim final. When finalize ends on a timer, the final result for the last
    /// words never came, and those words must not be lost.
    mutating func promoteInterim() {
        apply(interim, isFinal: true)
    }

    /// Joins with a space, except between two CJK characters: Chinese runs words together.
    nonisolated static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else {
            return head + tail
        }
        return isCJK(last) && isCJK(first) ? head + tail : head + " " + tail
    }

    nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,                      // CJK punctuation (。、「」)
             0x3040...0x30FF,                      // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF,     // Han
             0xF900...0xFAFF, 0x20000...0x2FA1F,   // Han compatibility, extensions
             0xFF00...0xFFEF:                      // Full-width forms (，！？)
            return true
        default:
            return false
        }
    }
}
