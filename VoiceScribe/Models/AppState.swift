import SwiftUI
import Combine

// MARK: - App Appearance

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var next: AppAppearance {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    // --- API Keys (stored in Keychain, debounced) ---
    @Published var openAIAPIKey: String = "" {
        didSet { scheduleKeychainSave(key: "openAIAPIKey", value: openAIAPIKey) }
    }
    @Published var claudeAPIKey: String = "" {
        didSet { scheduleKeychainSave(key: "claudeAPIKey", value: claudeAPIKey) }
    }
    @Published var xaiAPIKey: String = "" {
        didSet { scheduleKeychainSave(key: "xaiAPIKey", value: xaiAPIKey) }
    }
    /// Optional: self-hosted OpenAI-compatible servers often check no key at all.
    @Published var customAIAPIKey: String = "" {
        didSet { scheduleKeychainSave(key: "customAIAPIKey", value: customAIAPIKey) }
    }

    private var keychainSaveTimers: [String: DispatchWorkItem] = [:]

    private func scheduleKeychainSave(key: String, value: String) {
        keychainSaveTimers[key]?.cancel()
        let work = DispatchWorkItem { KeychainHelper.save(key: key, value: value) }
        keychainSaveTimers[key] = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // --- STT Settings ---
    @Published var sttProvider: STTProvider = .localWhisper {
        didSet { UserDefaults.standard.set(sttProvider.rawValue, forKey: "sttProvider") }
    }
    @Published var localWhisperHost: String = "100.91.237.44" {
        didSet { UserDefaults.standard.set(localWhisperHost, forKey: "localWhisperHost") }
    }
    @Published var localWhisperPort: String = "8000" {
        didSet { UserDefaults.standard.set(localWhisperPort, forKey: "localWhisperPort") }
    }
    @Published var localWhisperPath: String = "/api/transcribe" {
        didSet { UserDefaults.standard.set(localWhisperPath, forKey: "localWhisperPath") }
    }

    /// Full URL for the local Whisper endpoint, constructed from host, port, and path
    var localWhisperEndpoint: String {
        let host = localWhisperHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = localWhisperPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = localWhisperPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return "http://\(host):\(port)\(path)"
    }

    /// Health-check URL of the local Whisper server (same host and port, fixed `/health` path)
    var localWhisperHealthURL: String {
        let host = localWhisperHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = localWhisperPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return "http://\(host):\(port)/health"
    }

    @Published var localWhisperModel: String = "whisper-large-v3" {
        didSet { UserDefaults.standard.set(localWhisperModel, forKey: "localWhisperModel") }
    }
    @Published var sttLanguage: String = "en" {
        didSet { UserDefaults.standard.set(sttLanguage, forKey: "sttLanguage") }
    }

    // --- AI Refinement Settings ---
    @Published var aiProvider: AIProvider = .claude {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: "aiProvider") }
    }
    @Published var aiModel: String = "claude-sonnet-4-20250514" {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }

    // --- OpenAI-compatible endpoint (used when aiProvider == .openAICompatible) ---
    /// Endpoint root including the version prefix the server expects, e.g. http://192.168.10.7:8080/v1.
    @Published var customAIBaseURL: String = "" {
        didSet { UserDefaults.standard.set(customAIBaseURL, forKey: "customAIBaseURL") }
    }
    @Published var customAIModel: String = "" {
        didSet { UserDefaults.standard.set(customAIModel, forKey: "customAIModel") }
    }
    @Published var refinementMode: RefinementMode = .cleanup {
        didSet { UserDefaults.standard.set(refinementMode.rawValue, forKey: "refinementMode") }
    }

    // --- Editor Settings ---
    @Published var fontSize: Double = 16 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var autoRefineOnStop: Bool = false {
        didSet { UserDefaults.standard.set(autoRefineOnStop, forKey: "autoRefineOnStop") }
    }
    @Published var autoCopyOnTranscribe: Bool = true {
        didSet { UserDefaults.standard.set(autoCopyOnTranscribe, forKey: "autoCopyOnTranscribe") }
    }
    @Published var autoCopyOnRefine: Bool = true {
        didSet { UserDefaults.standard.set(autoCopyOnRefine, forKey: "autoCopyOnRefine") }
    }

    // --- Appearance ---
    @Published var appAppearance: AppAppearance = .system {
        didSet { UserDefaults.standard.set(appAppearance.rawValue, forKey: "appAppearance") }
    }

    // --- Runtime State ---
    @Published var isRecording = false
    @Published var isRefining = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    /// Set when the launch health check (or Settings' Test Connection) fails; nil otherwise.
    @Published var localWhisperHealthError: String?
    @Published var transcribedText = ""
    @Published var refinedText = ""
    @Published var showingRefined = false
    @Published var history: [TranscriptionEntry] = []

    init() {
        let defaults = UserDefaults.standard

        // One-time migration from UserDefaults to Keychain
        if !defaults.bool(forKey: "keychainMigrationDone") {
            for key in ["openAIAPIKey", "claudeAPIKey", "xaiAPIKey"] {
                if let value = defaults.string(forKey: key), !value.isEmpty {
                    KeychainHelper.save(key: key, value: value)
                    defaults.removeObject(forKey: key)
                    print("[Keychain] Migrated \(key) from UserDefaults to Keychain")
                }
            }
            defaults.set(true, forKey: "keychainMigrationDone")
        }

        // Migrate old display-string enum values to stable identifiers
        Self.migrateEnumValues(defaults)

        // Load API keys from Keychain (using _prop to skip didSet)
        _openAIAPIKey = Published(wrappedValue: KeychainHelper.load(key: "openAIAPIKey"))
        _claudeAPIKey = Published(wrappedValue: KeychainHelper.load(key: "claudeAPIKey"))
        _xaiAPIKey = Published(wrappedValue: KeychainHelper.load(key: "xaiAPIKey"))
        _customAIAPIKey = Published(wrappedValue: KeychainHelper.load(key: "customAIAPIKey"))

        // Load settings from UserDefaults (using _prop to skip didSet)
        if let raw = defaults.string(forKey: "sttProvider"),
           let val = STTProvider(rawValue: raw) {
            _sttProvider = Published(wrappedValue: val)
        }
        if let v = defaults.string(forKey: "localWhisperHost") {
            // The local Whisper server moved to power-linux-4090; carry installs still on the
            // previous default host across. A host the user set to anything else is kept.
            let host = v == "192.168.10.110" ? "192.168.10.7" : v
            if host != v {
                defaults.set(host, forKey: "localWhisperHost")
                print("[Migration] localWhisperHost: \(v) -> \(host)")
            }
            _localWhisperHost = Published(wrappedValue: host)
        }
        if let v = defaults.string(forKey: "localWhisperPort") { _localWhisperPort = Published(wrappedValue: v) }
        if let v = defaults.string(forKey: "localWhisperPath") { _localWhisperPath = Published(wrappedValue: v) }
        if let v = defaults.string(forKey: "localWhisperModel") { _localWhisperModel = Published(wrappedValue: v) }
        if let v = defaults.string(forKey: "sttLanguage") { _sttLanguage = Published(wrappedValue: v) }

        if let raw = defaults.string(forKey: "aiProvider"),
           let val = AIProvider(rawValue: raw) {
            _aiProvider = Published(wrappedValue: val)
        }
        if let v = defaults.string(forKey: "aiModel") { _aiModel = Published(wrappedValue: v) }
        if let v = defaults.string(forKey: "customAIBaseURL") { _customAIBaseURL = Published(wrappedValue: v) }
        if let v = defaults.string(forKey: "customAIModel") { _customAIModel = Published(wrappedValue: v) }
        if let raw = defaults.string(forKey: "refinementMode"),
           let val = RefinementMode(rawValue: raw) {
            _refinementMode = Published(wrappedValue: val)
        }

        if defaults.object(forKey: "fontSize") != nil {
            _fontSize = Published(wrappedValue: defaults.double(forKey: "fontSize"))
        }
        if defaults.object(forKey: "autoRefineOnStop") != nil {
            _autoRefineOnStop = Published(wrappedValue: defaults.bool(forKey: "autoRefineOnStop"))
        }
        if defaults.object(forKey: "autoCopyOnTranscribe") != nil {
            _autoCopyOnTranscribe = Published(wrappedValue: defaults.bool(forKey: "autoCopyOnTranscribe"))
        }
        if defaults.object(forKey: "autoCopyOnRefine") != nil {
            _autoCopyOnRefine = Published(wrappedValue: defaults.bool(forKey: "autoCopyOnRefine"))
        }

        if let raw = defaults.string(forKey: "appAppearance"),
           let val = AppAppearance(rawValue: raw) {
            _appAppearance = Published(wrappedValue: val)
        }
    }

    /// Migrate old display-string enum raw values to stable identifiers
    private static func migrateEnumValues(_ defaults: UserDefaults) {
        let sttMap = [
            "OpenAI Whisper": STTProvider.openAIWhisper.rawValue,
            "GPT-4o Transcribe": STTProvider.gpt4oTranscribe.rawValue,
            "Local Whisper": STTProvider.localWhisper.rawValue
        ]
        if let old = defaults.string(forKey: "sttProvider"), let new = sttMap[old] {
            defaults.set(new, forKey: "sttProvider")
            print("[Migration] sttProvider: \(old) -> \(new)")
        }

        let aiMap = [
            "Claude (Anthropic)": AIProvider.claude.rawValue,
            "OpenAI": AIProvider.openai.rawValue,
            "xAI (Grok)": AIProvider.xai.rawValue
        ]
        if let old = defaults.string(forKey: "aiProvider"), let new = aiMap[old] {
            defaults.set(new, forKey: "aiProvider")
            print("[Migration] aiProvider: \(old) -> \(new)")
        }

        let modeMap = [
            "Clean Up": RefinementMode.cleanup.rawValue,
            "Formal / Professional": RefinementMode.formal.rawValue,
            "Casual": RefinementMode.casual.rawValue,
            "Bullet Points": RefinementMode.bullets.rawValue,
            "Email Draft": RefinementMode.email.rawValue,
            "Summarize": RefinementMode.summary.rawValue,
            "Technical Writing": RefinementMode.technical.rawValue,
            "Translate EN \u{2194} CN": RefinementMode.translate.rawValue,
            "Custom Prompt": RefinementMode.custom.rawValue
        ]
        if let old = defaults.string(forKey: "refinementMode"), let new = modeMap[old] {
            defaults.set(new, forKey: "refinementMode")
            print("[Migration] refinementMode: \(old) -> \(new)")
        }
    }

    // MARK: - Computed Properties

    var currentAIApiKey: String {
        switch aiProvider {
        case .claude: return claudeAPIKey
        case .openai: return openAIAPIKey
        case .xai:    return xaiAPIKey
        case .openAICompatible: return customAIAPIKey
        }
    }

    /// The model sent to the current provider. The OpenAI-compatible endpoint has its own
    /// free-text model setting; the built-in providers share `aiModel`.
    var currentAIModel: String {
        aiProvider == .openAICompatible ? customAIModel : aiModel
    }

    /// The endpoint root for the current provider: built in, or the user's Base URL.
    var currentAIBaseURL: String {
        aiProvider == .openAICompatible ? customAIBaseURL : aiProvider.baseURL
    }

    /// Whether the provider can be used: a key for the built-in services, a Base URL for the
    /// OpenAI-compatible endpoint (its key is optional).
    func isConfigured(_ provider: AIProvider) -> Bool {
        switch provider {
        case .claude: return !claudeAPIKey.isEmpty
        case .openai: return !openAIAPIKey.isEmpty
        case .xai:    return !xaiAPIKey.isEmpty
        case .openAICompatible: return !customAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - History Management

    func addHistoryEntry(_ entry: TranscriptionEntry) {
        history.insert(entry, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        print("[History] Added entry (total: \(history.count))")
    }
}

// MARK: - STT Provider

enum STTProvider: String, CaseIterable, Identifiable, Codable {
    case openAIWhisper    = "openai_whisper"
    case gpt4oTranscribe  = "gpt4o_transcribe"
    case localWhisper     = "local_whisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIWhisper:   return "OpenAI Whisper"
        case .gpt4oTranscribe: return "GPT-4o Transcribe"
        case .localWhisper:    return "Local Whisper"
        }
    }

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

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude = "claude"
    case openai = "openai"
    case xai    = "xai"
    /// Any server speaking the OpenAI Chat Completions API (vLLM, llama.cpp, Ollama, LiteLLM, an
    /// AI hub…). Its Base URL, key and model are settings on `AppState`, not properties here.
    case openAICompatible = "openai_compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .xai:    return "xAI (Grok)"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Empty for the OpenAI-compatible endpoint: its model is `AppState.customAIModel`.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .xai:    return "grok-3-mini"
        case .openAICompatible: return ""
        }
    }

    /// Endpoint root including the API version prefix; `AIService` appends `messages`,
    /// `chat/completions` or `models`. Empty for the OpenAI-compatible endpoint: its root is
    /// `AppState.customAIBaseURL`.
    var baseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .xai:    return "https://api.x.ai/v1"
        case .openAICompatible: return ""
        }
    }

    /// The built-in services reject unauthenticated calls; a self-hosted endpoint may not check a key.
    var requiresAPIKey: Bool {
        self != .openAICompatible
    }
}

// MARK: - Refinement Mode

enum RefinementMode: String, CaseIterable, Identifiable, Codable {
    case cleanup    = "cleanup"
    case formal     = "formal"
    case casual     = "casual"
    case bullets    = "bullets"
    case email      = "email"
    case summary    = "summary"
    case technical  = "technical"
    case translate  = "translate"
    case custom     = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cleanup:   return "Clean Up"
        case .formal:    return "Formal / Professional"
        case .casual:    return "Casual"
        case .bullets:   return "Bullet Points"
        case .email:     return "Email Draft"
        case .summary:   return "Summarize"
        case .technical: return "Technical Writing"
        case .translate: return "Translate EN \u{2194} CN"
        case .custom:    return "Custom Prompt"
        }
    }

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

struct TranscriptionEntry: Identifiable {
    let id: UUID
    let date: Date
    var rawText: String
    var refinedText: String?
    var mode: RefinementMode
    let sttProvider: STTProvider

    init(rawText: String, refinedText: String? = nil, mode: RefinementMode = .cleanup, sttProvider: STTProvider = .gpt4oTranscribe) {
        self.id = UUID()
        self.date = Date()
        self.rawText = rawText
        self.refinedText = refinedText
        self.mode = mode
        self.sttProvider = sttProvider
    }
}
