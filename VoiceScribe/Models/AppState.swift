import SwiftUI
import Combine

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    // --- STT Settings ---
    @AppStorage("sttProvider")       var sttProvider: STTProvider = .gpt4oTranscribe
    @AppStorage("openAIAPIKey")      var openAIAPIKey: String = ""
    @AppStorage("localWhisperHost")  var localWhisperHost: String = "192.168.10.110"
    @AppStorage("localWhisperPort")  var localWhisperPort: String = "8000"
    @AppStorage("localWhisperPath")  var localWhisperPath: String = "/api/transcribe"

    /// Full URL for the local Whisper endpoint, constructed from host, port, and path
    var localWhisperEndpoint: String {
        "http://\(localWhisperHost):\(localWhisperPort)\(localWhisperPath)"
    }
    @AppStorage("localWhisperModel") var localWhisperModel: String = "whisper-large-v3"
    @AppStorage("sttLanguage")       var sttLanguage: String = "en"

    // --- AI Refinement Settings ---
    @AppStorage("aiProvider")        var aiProvider: AIProvider = .claude
    @AppStorage("claudeAPIKey")      var claudeAPIKey: String = ""
    @AppStorage("xaiAPIKey")         var xaiAPIKey: String = ""
    @AppStorage("aiModel")           var aiModel: String = "claude-sonnet-4-20250514"
    @AppStorage("refinementMode")    var refinementMode: RefinementMode = .cleanup

    // --- Editor Settings ---
    @AppStorage("fontSize")          var fontSize: Double = 16
    @AppStorage("autoRefineOnStop")       var autoRefineOnStop: Bool = false
    @AppStorage("autoCopyOnTranscribe")  var autoCopyOnTranscribe: Bool = true
    @AppStorage("autoCopyOnRefine")      var autoCopyOnRefine: Bool = true

    /// Appearance: "system", "light", or "dark"
    @AppStorage("appAppearance")     var appAppearance: String = "system"

    // --- Runtime State ---
    @Published var isRecording = false
    @Published var isRefining = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    @Published var transcribedText = ""
    @Published var refinedText = ""
    @Published var showingRefined = false
    @Published var history: [TranscriptionEntry] = []

    /// Returns the API key for the currently selected AI provider
    var currentAIApiKey: String {
        switch aiProvider {
        case .claude: return claudeAPIKey
        case .openai: return openAIAPIKey
        case .xai:    return xaiAPIKey
        }
    }

    /// Check if a given AI provider has an API key configured
    func hasAPIKey(for provider: AIProvider) -> Bool {
        switch provider {
        case .claude: return !claudeAPIKey.isEmpty
        case .openai: return !openAIAPIKey.isEmpty
        case .xai:    return !xaiAPIKey.isEmpty
        }
    }
}

// MARK: - STT Provider

enum STTProvider: String, CaseIterable, Identifiable {
    case openAIWhisper    = "OpenAI Whisper"
    case gpt4oTranscribe  = "GPT-4o Transcribe"
    case localWhisper     = "Local Whisper"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .openAIWhisper:   return "OpenAI Whisper API (whisper-1)"
        case .gpt4oTranscribe: return "GPT-4o audio transcription — best accuracy"
        case .localWhisper:    return "Self-hosted Whisper endpoint"
        }
    }

    /// The model string sent in the API request
    var modelName: String {
        switch self {
        case .openAIWhisper:   return "whisper-1"
        case .gpt4oTranscribe: return "gpt-4o-transcribe"
        case .localWhisper:    return ""          // filled from settings
        }
    }

    /// Base URL for the transcription endpoint
    func endpoint(localURL: String) -> String {
        switch self {
        case .openAIWhisper, .gpt4oTranscribe:
            return "https://api.openai.com/v1/audio/transcriptions"
        case .localWhisper:
            return localURL
        }
    }

    var requiresOpenAIKey: Bool {
        self == .openAIWhisper || self == .gpt4oTranscribe
    }
}

// MARK: - AI Provider

enum AIProvider: String, CaseIterable, Identifiable {
    case claude = "Claude (Anthropic)"
    case openai = "OpenAI"
    case xai   = "xAI (Grok)"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .xai:    return "grok-3-mini"
        }
    }

    var baseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .xai:    return "https://api.x.ai"
        }
    }
}

// MARK: - Refinement Mode

enum RefinementMode: String, CaseIterable, Identifiable {
    case cleanup    = "Clean Up"
    case formal     = "Formal / Professional"
    case casual     = "Casual"
    case bullets    = "Bullet Points"
    case email      = "Email Draft"
    case summary    = "Summarize"
    case technical  = "Technical Writing"
    case translate  = "Translate EN ↔ CN"
    case custom     = "Custom Prompt"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cleanup:   return "sparkles"
        case .formal:    return "briefcase"
        case .casual:    return "face.smiling"
        case .bullets:   return "list.bullet"
        case .email:     return "envelope"
        case .summary:   return "doc.text.magnifyingglass"
        case .technical: return "wrench.and.screwdriver"
        case .translate: return "globe"
        case .custom:    return "terminal"
        }
    }

    var systemPrompt: String {
        switch self {
        case .cleanup:
            return """
            Clean up this speech-to-text transcription: fix grammar, punctuation, \
            remove filler words (um, uh, like, you know), and make it read naturally. \
            Preserve the original meaning and tone. Return ONLY the cleaned text.
            """
        case .formal:
            return """
            Rewrite this speech-to-text transcription in a formal, professional tone. \
            Fix grammar, improve vocabulary, and structure it properly. \
            Return ONLY the rewritten text.
            """
        case .casual:
            return """
            Clean up this speech-to-text transcription while keeping a casual, friendly tone. \
            Fix obvious errors but maintain the conversational feel. \
            Return ONLY the cleaned text.
            """
        case .bullets:
            return """
            Convert this speech-to-text transcription into well-organized bullet points. \
            Group related ideas together. Fix any grammar issues. \
            Return ONLY the bullet points.
            """
        case .email:
            return """
            Convert this speech-to-text transcription into a well-formatted email. \
            Include an appropriate greeting and sign-off. Fix grammar and structure. \
            Return ONLY the email text.
            """
        case .summary:
            return """
            Summarize the key points from this speech-to-text transcription concisely. \
            Return ONLY the summary.
            """
        case .technical:
            return """
            Rewrite this speech-to-text transcription in clear technical writing style. \
            Use precise language, proper terminology, and logical structure. \
            Return ONLY the rewritten text.
            """
        case .translate:
            return """
            Detect the language of this transcription. \
            If it is in Chinese, translate it to natural, fluent English. \
            If it is in English, translate it to natural, fluent Simplified Chinese. \
            Return ONLY the translated text.
            """
        case .custom:
            return ""
        }
    }
}

// MARK: - History Entry

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    var rawText: String
    var refinedText: String?
    var mode: String
    let sttProvider: String

    init(rawText: String, refinedText: String? = nil, mode: String = "cleanup", sttProvider: String = "") {
        self.id = UUID()
        self.date = Date()
        self.rawText = rawText
        self.refinedText = refinedText
        self.mode = mode
        self.sttProvider = sttProvider
    }
}
