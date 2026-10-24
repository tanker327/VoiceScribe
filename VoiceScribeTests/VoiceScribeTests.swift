import Testing
import Foundation
import AVFoundation
import AppKit
import SwiftUI
@testable import VoiceScribe

// MARK: - AIService response parsing

struct AIServiceParsingTests {

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func claudeTextOnlyResponse() throws {
        let data = try json(["stop_reason": "end_turn",
                             "content": [["type": "text", "text": "  Cleaned text.  "]]])
        #expect(try AIService.parseClaudeResponse(data) == "Cleaned text.")
    }

    @Test func claudeThinkingBlockBeforeText() throws {
        // Current models return a thinking block first; the parser must skip it.
        let data = try json(["stop_reason": "end_turn",
                             "content": [["type": "thinking", "thinking": ""],
                                         ["type": "text", "text": "Cleaned text."]]])
        #expect(try AIService.parseClaudeResponse(data) == "Cleaned text.")
    }

    @Test func claudeRefusalIsAnError() throws {
        let data = try json(["stop_reason": "refusal", "content": [] as [Any]])
        #expect(throws: AIService.AIError.self) { try AIService.parseClaudeResponse(data) }
    }

    @Test func claudeTruncationIsAnError() throws {
        let data = try json(["stop_reason": "max_tokens",
                             "content": [["type": "text", "text": "Half of the"]]])
        #expect(throws: AIService.AIError.self) { try AIService.parseClaudeResponse(data) }
    }

    @Test func claudeMissingTextBlockIsParseError() throws {
        let data = try json(["stop_reason": "end_turn",
                             "content": [["type": "thinking", "thinking": ""]]])
        #expect(throws: AIService.AIError.self) { try AIService.parseClaudeResponse(data) }
    }

    @Test func chatCompletionResponse() throws {
        let data = try json(["choices": [["finish_reason": "stop",
                                          "message": ["role": "assistant", "content": " Done. "]]]])
        #expect(try AIService.parseChatCompletionResponse(data, provider: "OpenAI") == "Done.")
    }

    @Test func chatCompletionLengthIsAnError() throws {
        let data = try json(["choices": [["finish_reason": "length",
                                          "message": ["role": "assistant", "content": "Half"]]]])
        #expect(throws: AIService.AIError.self) {
            try AIService.parseChatCompletionResponse(data, provider: "OpenAI")
        }
    }

    @Test(arguments: [("gpt-4o", true), ("gpt-4.1-mini", true), ("grok-3-mini", true),
                      ("o1", false), ("o3-mini", false), ("o4-mini", false), ("gpt-5", false)])
    func temperatureSupport(model: String, expected: Bool) {
        #expect(AIService.supportsTemperature(model: model) == expected)
    }
}

// MARK: - AudioRecorderService downsampling

struct AudioDownsamplingTests {

    /// Feeds a rising ramp through the tap-buffer conversion path one buffer at a time.
    /// If the converter were ever handed the same input twice, the output would rewind.
    @Test func downsamplingNeverDuplicatesInput() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))

        let framesPerBuffer: AVAudioFrameCount = 4096
        let bufferCount = 20
        let totalFrames = Float(framesPerBuffer) * Float(bufferCount)
        var produced: [Float] = []
        var sampleIndex: Float = 0

        for _ in 0..<bufferCount {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: framesPerBuffer))
            buffer.frameLength = framesPerBuffer
            for channel in 0..<Int(input.channelCount) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(framesPerBuffer) {
                    data[i] = (sampleIndex + Float(i)) / totalFrames   // ramp 0 -> 1
                }
            }
            sampleIndex += Float(framesPerBuffer)

            let converted = try #require(AudioRecorderService.downsample(buffer, with: converter, to: output))
            #expect(converted.frameLength <= AVAudioFrameCount(Double(framesPerBuffer) * 16_000 / 48_000))
            produced.append(contentsOf: UnsafeBufferPointer(start: converted.floatChannelData![0],
                                                            count: Int(converted.frameLength)))
        }

        // Roughly one third of the input frames, minus a little converter latency.
        let expected = Int(totalFrames / 3)
        #expect(produced.count > expected - 2_000 && produced.count <= expected)

        // The ramp must never run backwards: a rewind means duplicated input.
        let rewinds = zip(produced, produced.dropFirst()).filter { $1 < $0 - 0.001 }.count
        #expect(rewinds == 0)
        #expect(produced.last ?? 0 > 0.9)
    }

    @Test func pcm16IsLittleEndianAndClipped() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5))
        buffer.frameLength = 5
        for (i, sample) in [Float(0), 1, -1, 2, 0.5].enumerated() { buffer.floatChannelData![0][i] = sample }

        let data = AudioRecorderService.pcm16Data(from: buffer)
        #expect(data.count == 10)
        let samples = data.withUnsafeBytes { raw in
            (0..<5).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        #expect(samples == [0, 32_767, -32_767, 32_767, 16_383], "2.0 is clipped to full scale")
        #expect(Array(data[2..<4]) == [0xFF, 0x7F], "low byte first")
    }

    @Test func rmsOfSilenceIsZeroAndOfFullScaleIsOne() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        #expect(AudioRecorderService.rms(of: buffer) == 0)
        for i in 0..<160 { buffer.floatChannelData![0][i] = 1 }
        #expect(abs(AudioRecorderService.rms(of: buffer) - 1) < 0.0001)
    }
}

// MARK: - STTService request URL

struct STTRequestURLTests {

    @Test func localEndpointGetsLanguageQueryItem() throws {
        let url = try STTService.requestURL(endpoint: "http://192.168.10.7:8000/api/transcribe",
                                            provider: .localWhisper, language: "en")
        #expect(url.absoluteString == "http://192.168.10.7:8000/api/transcribe?language=en")
    }

    @Test func localEndpointWithoutLanguageIsUnchanged() throws {
        let url = try STTService.requestURL(endpoint: "http://192.168.10.7:8000/api/transcribe",
                                            provider: .localWhisper, language: "")
        #expect(url.absoluteString == "http://192.168.10.7:8000/api/transcribe")
    }

    @Test func openAIEndpointKeepsLanguageOutOfTheQuery() throws {
        let url = try STTService.requestURL(endpoint: "https://api.openai.com/v1/audio/transcriptions",
                                            provider: .gpt4oTranscribe, language: "en")
        #expect(url.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    }

    @Test func invalidEndpointThrows() {
        #expect(throws: STTService.STTError.self) {
            try STTService.requestURL(endpoint: "http://:8000", provider: .localWhisper, language: "en")
        }
    }
}

// MARK: - AIService endpoint URLs

@MainActor
struct AIServiceEndpointTests {

    @Test func builtInProvidersCarryTheVersionPrefix() throws {
        let chat = try AIService.endpointURL(base: AIProvider.openai.baseURL, path: "chat/completions", providerName: "OpenAI")
        #expect(chat.absoluteString == "https://api.openai.com/v1/chat/completions")
        let messages = try AIService.endpointURL(base: AIProvider.claude.baseURL, path: "messages", providerName: "Claude")
        #expect(messages.absoluteString == "https://api.anthropic.com/v1/messages")
        let models = try AIService.endpointURL(base: AIProvider.xai.baseURL, path: "models", providerName: "xAI")
        #expect(models.absoluteString == "https://api.x.ai/v1/models")
    }

    @Test(arguments: ["http://192.168.10.7:8080/v1", "http://192.168.10.7:8080/v1/", " http://192.168.10.7:8080/v1// "])
    func customBaseURLDropsTrailingSlashesAndWhitespace(base: String) throws {
        let url = try AIService.endpointURL(base: base, path: "models", providerName: "OpenAI-compatible")
        #expect(url.absoluteString == "http://192.168.10.7:8080/v1/models")
    }

    @Test(arguments: ["", "   ", "192.168.10.7:8080/v1", "ftp://host/v1", "http://", "http:///v1"])
    func unusableCustomBaseURLThrows(base: String) {
        #expect(throws: AIService.AIError.self) {
            try AIService.endpointURL(base: base, path: "models", providerName: "OpenAI-compatible")
        }
    }

    @Test func onlyTheCompatibleEndpointMayGoWithoutAKey() {
        #expect(!AIProvider.openAICompatible.requiresAPIKey)
        #expect(AIProvider.allCases.filter(\.requiresAPIKey).count == 3)
        #expect(AIProvider.openAICompatible.baseURL.isEmpty && AIProvider.openAICompatible.defaultModel.isEmpty)
    }
}

// MARK: - AIService request building

@MainActor
struct AIServiceRequestTests {

    @Test func claudeUsesItsOwnHeaderPair() {
        let headers = AIService.authorizationHeaders(provider: .claude, apiKey: "sk-ant-1")
        #expect(headers == ["x-api-key": "sk-ant-1", "anthropic-version": "2023-06-01"])
    }

    @Test(arguments: [AIProvider.openai, .xai, .openAICompatible])
    func chatCompletionProvidersSendABearerToken(provider: AIProvider) {
        #expect(AIService.authorizationHeaders(provider: provider, apiKey: "k") == ["Authorization": "Bearer k"])
    }

    @Test func compatibleEndpointWithoutAKeySendsNoAuthorizationHeader() {
        #expect(AIService.authorizationHeaders(provider: .openAICompatible, apiKey: "").isEmpty)
    }

    /// The configuration checks run before a request is built, so these never touch the network.
    private func expectConfigurationError(_ isExpected: @escaping (AIService.AIError) -> Bool,
                                          performing body: @escaping () async throws -> Void) async {
        await #expect(performing: body, throws: { error in
            (error as? AIService.AIError).map(isExpected) ?? false
        })
    }

    @Test func compatibleEndpointWithoutAModelFailsBeforeAnyRequest() async {
        await expectConfigurationError({ if case .missingModel = $0 { return true } else { return false } }) {
            _ = try await AIService.shared.refine(text: "t", systemPrompt: "p", provider: .openAICompatible,
                                                  apiKey: "", baseURL: "http://192.168.10.7:8080/v1", model: "")
        }
    }

    @Test func compatibleEndpointWithoutABaseURLFailsBeforeAnyRequest() async {
        let isInvalidBaseURL: (AIService.AIError) -> Bool = { if case .invalidBaseURL = $0 { return true } else { return false } }
        await expectConfigurationError(isInvalidBaseURL) {
            _ = try await AIService.shared.refine(text: "t", systemPrompt: "p", provider: .openAICompatible,
                                                  apiKey: "", baseURL: "  ", model: "qwen3.8-27b")
        }
        await expectConfigurationError(isInvalidBaseURL) {
            _ = try await AIService.shared.fetchModels(provider: .openAICompatible, apiKey: "", baseURL: "")
        }
    }

    @Test(arguments: [AIProvider.claude, .openai, .xai])
    func builtInProvidersStillRequireAKey(provider: AIProvider) async {
        let isMissingKey: (AIService.AIError) -> Bool = { if case .missingAPIKey = $0 { return true } else { return false } }
        await expectConfigurationError(isMissingKey) {
            _ = try await AIService.shared.refine(text: "t", systemPrompt: "p", provider: provider,
                                                  apiKey: "", baseURL: provider.baseURL)
        }
        await expectConfigurationError(isMissingKey) {
            _ = try await AIService.shared.fetchModels(provider: provider, apiKey: "", baseURL: provider.baseURL)
        }
    }
}

// MARK: - AppState provider resolution

@MainActor
struct AppStateProviderResolutionTests {

    /// AppState persists every setting as it changes and the tests run inside the app, so the
    /// values touched here are put back afterwards.
    @Test func compatibleEndpointUsesItsOwnBaseURLAndModel() {
        let state = AppState()
        let saved = (state.aiProvider, state.aiModel, state.customAIBaseURL, state.customAIModel)
        defer {
            state.aiProvider = saved.0
            state.aiModel = saved.1
            state.customAIBaseURL = saved.2
            state.customAIModel = saved.3
        }

        state.aiProvider = .openAICompatible
        state.customAIBaseURL = "http://192.168.10.7:8080/v1"
        state.customAIModel = "qwen3.8-27b"
        state.aiModel = "gpt-4o"
        #expect(state.currentAIBaseURL == "http://192.168.10.7:8080/v1")
        #expect(state.currentAIModel == "qwen3.8-27b")
        #expect(state.isConfigured(.openAICompatible))

        state.customAIBaseURL = "   "
        #expect(!state.isConfigured(.openAICompatible), "a blank Base URL does not count as configured")

        state.aiProvider = .openai
        #expect(state.currentAIBaseURL == "https://api.openai.com/v1")
        #expect(state.currentAIModel == "gpt-4o")
    }
}

// MARK: - TranscriptEditor

/// Hosts the editor the way ContentView does, in an NSHostingView inside an unshown window, and
/// drives the NSTextView the user would type into. Covers the read-only default, the double-click
/// that starts editing, focus loss that ends it, and both directions of the text binding without
/// the UI test runner.
@MainActor
struct TranscriptEditorTests {

    /// Mutable backing store so the bindings behave like ContentView's @State.
    final class Model {
        var text: String
        var isEditing = false
        var isEnabled = true
        var fontSize: CGFloat = 16
        var dimmedSuffixLength = 0
        init(text: String) { self.text = text }
    }

    private func editor(for model: Model) -> TranscriptEditor {
        TranscriptEditor(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            isEditing: Binding(get: { model.isEditing }, set: { model.isEditing = $0 }),
            isEnabled: model.isEnabled,
            fontSize: model.fontSize,
            dimmedSuffixLength: model.dimmedSuffixLength)
    }

    private func makeHost(_ model: Model) throws -> (NSWindow, NSHostingView<TranscriptEditor>, TranscriptTextView) {
        let host = NSHostingView(rootView: editor(for: model))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let textView = try #require(settle(host), "SwiftUI did not build the editor's NSTextView")
        return (window, host, textView)
    }

    /// Lets SwiftUI build or update the AppKit view, then returns the editor's text view.
    @discardableResult
    private func settle(_ host: NSView) -> TranscriptTextView? {
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let textView = firstTextView(in: host) { return textView }
        }
        return nil
    }

    private func firstTextView(in view: NSView) -> TranscriptTextView? {
        if let textView = view as? TranscriptTextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }

    private func update(_ host: NSHostingView<TranscriptEditor>, with model: Model) {
        host.rootView = editor(for: model)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func startsReadOnlyWithTheBoundTextAndStyle() throws {
        let model = Model(text: "hello world")
        let (window, _, textView) = try makeHost(model)
        defer { window.close() }
        #expect(textView.string == "hello world")
        #expect(!textView.isEditable)
        #expect(textView.isSelectable, "read-only text can still be selected and copied")
        #expect(textView.font?.pointSize == 16)
        #expect(textView.textContainerInset == NSSize(width: 12, height: 12))
        #expect(!textView.isRichText)
    }

    @Test func externalChangesReachTheTextView() throws {
        let model = Model(text: "before")
        let (window, host, textView) = try makeHost(model)
        defer { window.close() }

        model.text = "after"      // transcription landed, history loaded, or Clear
        model.isEditing = true
        model.fontSize = 20
        update(host, with: model)
        #expect(textView.string == "after")
        #expect(textView.isEditable)
        #expect(textView.font?.pointSize == 20)

        model.isEnabled = false   // recording: edit mode must not make the text editable
        update(host, with: model)
        #expect(!textView.isEditable)
    }

    @Test func typingWritesBackThroughTheBinding() throws {
        let model = Model(text: "abc")
        model.isEditing = true
        let (window, _, textView) = try makeHost(model)
        defer { window.close() }
        #expect(textView.isEditable)
        textView.insertText("d", replacementRange: NSRange(location: 3, length: 0))
        #expect(model.text == "abcd")
    }

    @Test func doubleClickStartsEditingAndPlacesTheCaret() throws {
        let model = Model(text: "hello world")
        let (window, _, textView) = try makeHost(model)
        defer { window.close() }

        let point = textView.convert(NSPoint(x: 30, y: 20), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        textView.mouseDown(with: click)

        #expect(model.isEditing)
        #expect(textView.isEditable)
        #expect(window.firstResponder === textView)
        #expect(textView.selectedRange().length == 0, "the caret goes to the click; no word is selected")
    }

    @Test func doubleClickIsRefusedWhileDisabled() throws {
        let model = Model(text: "hello")
        model.isEnabled = false
        let (window, _, textView) = try makeHost(model)
        defer { window.close() }
        // Ask the way mouseDown does. A refusal makes mouseDown fall back to the ordinary
        // double-click (word selection) instead of entering edit mode.
        #expect(textView.onDoubleClick?(textView) == false)
        #expect(!model.isEditing)
        #expect(!textView.isEditable)
    }

    @Test func liveInterimTailIsDimmedUntilItTurnsFinal() throws {
        let model = Model(text: "Hello world")
        model.dimmedSuffixLength = 6   // " world" is still being recognized
        let (window, host, textView) = try makeHost(model)
        defer { window.close() }
        let storage = try #require(textView.textStorage)
        let color = { (index: Int) in storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        #expect(color(0) != .secondaryLabelColor)
        #expect(color(6) == .secondaryLabelColor)

        model.dimmedSuffixLength = 0   // the same words came back final
        update(host, with: model)
        #expect(textView.string == "Hello world")
        #expect(color(6) != .secondaryLabelColor)
    }

    private func clipView(of textView: NSTextView) throws -> NSClipView {
        try #require(textView.enclosingScrollView?.contentView)
    }

    private let longText = (1...200).map { "line \($0)" }.joined(separator: "\n")

    @Test func textArrivingWhileRecordingScrollsToTheNewestWords() throws {
        let model = Model(text: "")
        model.isEnabled = false   // recording
        let (window, host, textView) = try makeHost(model)
        defer { window.close() }

        model.text = longText
        update(host, with: model)
        let clip = try clipView(of: textView)
        #expect(clip.bounds.minY > 0)
        #expect(clip.bounds.maxY >= textView.frame.maxY - 1, "the last line is in view")
    }

    @Test func otherReplacementsKeepTheScrollPosition() throws {
        let model = Model(text: "")
        let (window, host, textView) = try makeHost(model)
        defer { window.close() }

        model.text = longText   // a history entry loaded, not a live transcript
        update(host, with: model)
        #expect(try clipView(of: textView).bounds.minY == 0)
    }

    @Test func losingFocusEndsEditing() async throws {
        let model = Model(text: "hello")
        model.isEditing = true
        let (window, _, textView) = try makeHost(model)
        defer { window.close() }
        window.makeFirstResponder(textView)
        #expect(window.firstResponder === textView)

        window.makeFirstResponder(nil)
        // The editor reports the loss on the next main-actor turn, never mid-update.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isEditing)
    }
}

// MARK: - STTService test audio

struct STTSilentWAVTests {

    @Test func silentWAVIsAValid16kHzMonoPCMFile() throws {
        let wav = STTService.silentWAV(seconds: 1)
        #expect(wav.count == 44 + 32_000)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")

        // AVAudioFile must accept it, since the server decodes it like a real recording.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 16_000)
        // The STT service rejects audio of 1000 bytes or less as too short.
        #expect(wav.count > 1000)
    }
}

// MARK: - Local Whisper health check

@MainActor
struct LocalWhisperHealthTests {

    @Test func healthURLUsesHostAndPortButNotThePath() {
        let state = AppState()
        let saved = (state.localWhisperHost, state.localWhisperPort, state.localWhisperPath)
        defer {
            state.localWhisperHost = saved.0
            state.localWhisperPort = saved.1
            state.localWhisperPath = saved.2
        }

        state.localWhisperHost = " 100.91.237.44 "
        state.localWhisperPort = "8000"
        state.localWhisperPath = "/api/transcribe"
        #expect(state.localWhisperHealthURL == "http://100.91.237.44:8000/health")
    }

    @Test func blankHostFailsBeforeAnyRequest() async {
        await #expect(throws: STTService.STTError.self) {
            try await STTService.shared.checkHealth(url: "http://:8000/health")
        }
    }
}

// MARK: - Deepgram request URLs

@MainActor
struct DeepgramURLTests {

    private func values(_ name: String, in url: URL) -> [String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.filter { $0.name == name }.compactMap(\.value)
    }

    @Test func streamingURLDescribesTheRawAudioAndAsksForInterimResults() {
        let url = DeepgramStream.listenURL(streaming: true, languageMode: .english, keyterms: [])
        #expect(url.absoluteString.hasPrefix("wss://api.deepgram.com/v1/listen?"))
        let expected = [("model", "nova-3"), ("language", "en"), ("smart_format", "true"),
                        ("encoding", "linear16"), ("sample_rate", "16000"), ("channels", "1"),
                        ("interim_results", "true"), ("endpointing", "300")]
        for (name, value) in expected {
            #expect(values(name, in: url) == [value], "\(name)")
        }
        #expect(values("language_hint", in: url).isEmpty, "hints only apply to language=multi")
    }

    @Test func mixedModeIsTheCodeSwitchingModelHintedToChineseAndEnglish() {
        let url = DeepgramStream.listenURL(streaming: true, languageMode: .mixedChineseEnglish, keyterms: [])
        #expect(values("language", in: url) == ["multi"])
        #expect(values("language_hint", in: url) == ["zh", "en"])
    }

    @Test func chineseModeIsMonolingual() {
        let url = DeepgramStream.listenURL(streaming: true, languageMode: .chinese, keyterms: [])
        #expect(values("language", in: url) == ["zh"])
        #expect(values("language_hint", in: url).isEmpty)
    }

    @Test func preRecordedURLLeavesOutTheStreamingOptions() {
        let url = DeepgramStream.listenURL(streaming: false, languageMode: .mixedChineseEnglish, keyterms: ["Brewer"])
        #expect(url.absoluteString.hasPrefix("https://api.deepgram.com/v1/listen?"))
        for name in ["encoding", "sample_rate", "channels", "interim_results", "endpointing"] {
            #expect(values(name, in: url).isEmpty, "\(name)")
        }
        #expect(values("language", in: url) == ["multi"])
        #expect(values("keyterm", in: url) == ["Brewer"])
    }

    @Test func keytermsAreRepeatedAndPercentEncoded() {
        let url = DeepgramStream.listenURL(streaming: true, languageMode: .english,
                                           keyterms: ["Brewer", "customer service", "C++"])
        #expect(values("keyterm", in: url) == ["Brewer", "customer service", "C++"])
        let query = url.query(percentEncoded: true) ?? ""
        #expect(query.contains("keyterm=customer%20service"))
        #expect(query.contains("keyterm=C%2B%2B"), "a bare + would reach Deepgram as a space")
    }
}

// MARK: - Deepgram message parsing

@MainActor
struct DeepgramParsingTests {

    @Test func interimAndFinalResults() {
        let interim = #"{"type":"Results","is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"hello wor","confidence":0.9}]}}"#
        #expect(DeepgramStream.parseEvent(interim) == .results(transcript: "hello wor", isFinal: false))
        let final = #"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"Hello world."}]}}"#
        #expect(DeepgramStream.parseEvent(final) == .results(transcript: "Hello world.", isFinal: true))
    }

    @Test func resultsWithoutAnAlternativeAreEmpty() {
        let json = #"{"type":"Results","is_final":true,"channel":{"alternatives":[]}}"#
        #expect(DeepgramStream.parseEvent(json) == .results(transcript: "", isFinal: true))
    }

    @Test func metadataAndErrors() {
        let metadata = #"{"type":"Metadata","request_id":"8c8ebea9","duration":3.2}"#
        #expect(DeepgramStream.parseEvent(metadata) == .metadata(requestID: "8c8ebea9"))
        let error = #"{"type":"Error","description":"Failed to decode audio.","message":"DATA-0000"}"#
        #expect(DeepgramStream.parseEvent(error) == .error("Failed to decode audio."))
    }

    @Test func otherMessagesAreIgnored() {
        #expect(DeepgramStream.parseEvent(#"{"type":"UtteranceEnd","last_word_end":2.4}"#) == .ignored("UtteranceEnd"))
        #expect(DeepgramStream.parseEvent("not json") == .ignored("not JSON"))
    }

    @Test func preRecordedResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": ["channels": [["alternatives": [["transcript": " 把 Brewer 的 pipeline 部署到 homelab。 "]]]]]
        ])
        #expect(try DeepgramStream.parsePrerecordedResponse(data) == "把 Brewer 的 pipeline 部署到 homelab。")
        #expect(throws: DeepgramStream.DeepgramError.self) {
            try DeepgramStream.parsePrerecordedResponse(Data(#"{"results":{"channels":[]}}"#.utf8))
        }
    }
}

// MARK: - Deepgram transcript accumulation

@MainActor
struct TranscriptAccumulatorTests {

    @Test func interimIsReplacedAndFinalSegmentsAreAppended() {
        var transcript = TranscriptAccumulator()
        transcript.apply("hello", isFinal: false)
        transcript.apply("hello wor", isFinal: false)
        #expect(transcript.text == "hello wor")
        #expect(transcript.committed.isEmpty)

        transcript.apply("Hello world.", isFinal: true)
        transcript.apply("how", isFinal: false)
        #expect(transcript.text == "Hello world. how")
        #expect(transcript.interimLength == 4, "the joining space is part of the dimmed tail")

        transcript.apply("How are you?", isFinal: true)
        #expect(transcript.text == "Hello world. How are you?")
        #expect(transcript.interimLength == 0)
    }

    @Test func anEmptyFinalClearsTheInterim() {
        var transcript = TranscriptAccumulator()
        transcript.apply("Hello.", isFinal: true)
        transcript.apply("um", isFinal: false)
        transcript.apply("", isFinal: true)
        #expect(transcript.text == "Hello.")
    }

    @Test func promotingTheInterimKeepsTheLastWords() {
        var transcript = TranscriptAccumulator()
        transcript.apply("Deploy it", isFinal: true)
        transcript.apply("tonight", isFinal: false)
        transcript.promoteInterim()
        #expect(transcript.committed == "Deploy it tonight")
        #expect(transcript.interim.isEmpty)
    }

    @Test(arguments: [("今天天气", "很好。", "今天天气很好。"),
                      ("你好。", "谢谢", "你好。谢谢"),
                      ("我们用", "Brewer", "我们用 Brewer"),
                      ("Done.", "好的", "Done. 好的"),
                      ("Hello", "world", "Hello world"),
                      ("", "first", "first")])
    func segmentsJoinWithASpaceExceptBetweenChineseCharacters(head: String, tail: String, joined: String) {
        #expect(TranscriptAccumulator.join(head, tail) == joined)
    }

    @Test func interimLengthCountsUTF16LikeTheTextView() {
        var transcript = TranscriptAccumulator()
        transcript.apply("你好", isFinal: true)
        transcript.apply("世界🌏", isFinal: false)
        #expect(transcript.interimLength == ("世界🌏" as NSString).length)
    }
}

// MARK: - Deepgram errors

@MainActor
struct DeepgramErrorTests {

    private func response(_ status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: URL(string: "https://api.deepgram.com/v1/listen")!, statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: headers))
    }

    @Test func aRefusedKeyIsARejection() throws {
        let error = DeepgramStream.connectionError(response: try response(401), underlying: URLError(.badServerResponse))
        #expect(error.isRejection)
        #expect(error.localizedDescription == "Deepgram rejected the API key (401). Check it in Settings → API Keys.")
    }

    @Test func aBadParameterShowsDeepgramsReason() throws {
        let error = DeepgramStream.connectionError(response: try response(400, headers: ["dg-error": "Keyterm limit exceeded."]),
                                                   underlying: URLError(.badServerResponse))
        #expect(error.isRejection)
        #expect(error.localizedDescription == "Deepgram API error (400): Keyterm limit exceeded.")
    }

    @Test func serverAndNetworkFailuresFallBackToTheRecording() throws {
        let server = DeepgramStream.connectionError(response: try response(503), underlying: URLError(.badServerResponse))
        #expect(!server.isRejection)
        let offline = DeepgramStream.connectionError(response: nil, underlying: URLError(.notConnectedToInternet))
        #expect(!offline.isRejection)
        #expect(offline.localizedDescription.hasPrefix("Lost the connection to Deepgram"))
    }

    @Test func everyErrorReadsClearlyAndOnlyA4xxIsARejection() {
        typealias E = DeepgramStream.DeepgramError
        #expect(E.apiError(statusCode: 403, message: "").localizedDescription
                == "Deepgram rejected the API key (403). Check it in Settings → API Keys.")
        #expect(E.apiError(statusCode: 429, message: "Too many requests").isRejection)
        #expect(E.connectionLost("the server closed the stream (1011 NET-0001)").localizedDescription
                == "Lost the connection to Deepgram: the server closed the stream (1011 NET-0001).")
        #expect(E.streamError("Failed to decode audio.").localizedDescription == "Deepgram error: Failed to decode audio.")
        let notRejections: [E] = [.missingAPIKey, .connectionLost("x"), .streamError("x"), .invalidResponse, .parseError]
        for error in notRejections {
            #expect(!error.isRejection, "\(error)")
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    @Test func aMissingKeyFailsBeforeAnyConnection() {
        #expect(throws: DeepgramStream.DeepgramError.self) {
            try DeepgramStream(apiKey: "", languageMode: .english, keyterms: [])
        }
    }
}

// MARK: - Deepgram settings

@MainActor
struct DeepgramSettingsTests {

    @Test func keytermsSplitOnCommasAndNewLines() {
        let state = AppState()
        let saved = state.deepgramKeyterms
        defer { state.deepgramKeyterms = saved }

        state.deepgramKeyterms = " Brewer, homelab\ncustomer service，Kubernetes ,, \n"
        #expect(state.deepgramKeytermList == ["Brewer", "homelab", "customer service", "Kubernetes"])
    }

    @Test func onlyDeepgramStreams() {
        #expect(STTProvider.allCases.filter(\.isStreaming) == [.deepgram])
        #expect(STTProvider.deepgram.modelName == "nova-3")
        #expect(STTProvider.deepgram.endpoint(localURL: "") == "wss://api.deepgram.com/v1/listen")
        #expect(!STTProvider.deepgram.requiresOpenAIKey)
    }

    /// The stored raw values are persisted identifiers, like the other enums'.
    @Test func languageModeRawValuesAreStable() {
        #expect(DeepgramLanguageMode.allCases.map(\.rawValue) == ["multi_zh_en", "en", "zh"])
    }

    @Test func deepgramSettingsSurviveARelaunch() {
        let state = AppState()
        let saved = (state.deepgramLanguageMode, state.deepgramKeyterms, state.deepgramLiveTranscript)
        defer {
            state.deepgramLanguageMode = saved.0
            state.deepgramKeyterms = saved.1
            state.deepgramLiveTranscript = saved.2
        }

        state.deepgramLanguageMode = .chinese
        state.deepgramKeyterms = "Brewer, homelab"
        state.deepgramLiveTranscript = false
        let relaunched = AppState()
        #expect(relaunched.deepgramLanguageMode == .chinese)
        #expect(relaunched.deepgramKeytermList == ["Brewer", "homelab"])
        #expect(!relaunched.deepgramLiveTranscript)
    }

    /// Through the static seam: setting a key on AppState would write the user's real Keychain.
    @Test func eachProviderNeedsOnlyItsOwnKey() {
        #expect(AppState.isConfigured(.localWhisper, openAIKey: "", deepgramKey: ""), "Local Whisper sends no key")
        #expect(AppState.isConfigured(.deepgram, openAIKey: "", deepgramKey: "dg-1"))
        #expect(!AppState.isConfigured(.deepgram, openAIKey: "sk-1", deepgramKey: ""))
        #expect(!AppState.isConfigured(.gpt4oTranscribe, openAIKey: "", deepgramKey: "dg-1"),
                "a Deepgram key does not configure OpenAI")
        #expect(AppState.isConfigured(.openAIWhisper, openAIKey: "sk-1", deepgramKey: ""))

        let state = AppState()   // read only
        #expect(state.isConfigured(.deepgram) == !state.deepgramAPIKey.isEmpty)
    }
}


// MARK: - Recorded text in the editor

struct RecordedTextTests {

    @Test func aNormalRecordingStandsOnItsOwn() {
        #expect(ContentView.recordedText("new", after: "earlier", appending: false) == "new")
    }

    @Test func appendGoesOnANewLineAfterTheEarlierText() {
        #expect(ContentView.recordedText("new", after: "earlier", appending: true) == "earlier\nnew")
        #expect(ContentView.recordedText("new", after: "", appending: true) == "new")
    }

    @Test func anEmptyAppendLeavesTheEarlierTextAlone() {
        // Also what a live transcript shows before the first words arrive.
        #expect(ContentView.recordedText("", after: "earlier", appending: true) == "earlier")
    }
}
