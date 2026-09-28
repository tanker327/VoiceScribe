import Testing
import Foundation
import AVFoundation
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
