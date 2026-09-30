import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var modelLoadError: String?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadCooldown = false
    @State private var modelCache: [AIProvider: [String]] = [:]
    @State private var isTestingSTT = false
    @State private var sttTestResult: Result<String, Error>?

    var body: some View {
        TabView {
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key") }

            sttTab
                .tabItem { Label("Transcription", systemImage: "mic") }

            aiAndGeneralTab
                .tabItem { Label("AI & General", systemImage: "brain") }
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - API Keys Tab

    private var apiKeysTab: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $appState.openAIAPIKey, prompt: Text("sk-..."))
                Text("Used for Whisper/GPT-4o transcription and OpenAI refinement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Claude (Anthropic)") {
                SecureField("API Key", text: $appState.claudeAPIKey, prompt: Text("sk-ant-..."))
                Text("Used for Claude AI refinement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("xAI (Grok)") {
                SecureField("API Key", text: $appState.xaiAPIKey, prompt: Text("xai-..."))
                Text("Used for Grok AI refinement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Speech-to-Text Tab

    private var sttTab: some View {
        Form {
            Section("Speech-to-Text Provider") {
                Picker("Provider", selection: $appState.sttProvider) {
                    ForEach(STTProvider.allCases) { provider in
                        HStack {
                            Text(provider.displayName)
                            if provider.requiresOpenAIKey && appState.openAIAPIKey.isEmpty {
                                Text("(No API key)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(appState.sttProvider.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if appState.sttProvider == .localWhisper {
                Section("Local Whisper Endpoint") {
                    TextField("Host", text: $appState.localWhisperHost, prompt: Text("100.91.237.44"))
                    TextField("Port", text: $appState.localWhisperPort, prompt: Text("8000"))
                    TextField("Path", text: $appState.localWhisperPath, prompt: Text("/api/transcribe"))
                    TextField("Model", text: $appState.localWhisperModel, prompt: Text("whisper-large-v3"))

                    Text("Multipart upload to the given path. Works with Whisperapy (default), whisper.cpp server, faster-whisper-server, LocalAI, etc.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(action: testSTTEndpoint) {
                            if isTestingSTT {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 16, height: 16)
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                        .disabled(isTestingSTT)
                        Spacer()
                    }

                    switch sttTestResult {
                    case .success(let text):
                        Label(text.isEmpty ? "Connected. The server accepted the test audio."
                                           : "Connected. Server returned: \(text)",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    case nil:
                        EmptyView()
                    }
                }
                .onChange(of: appState.localWhisperEndpoint) {
                    // The old result no longer applies to the new settings.
                    sttTestResult = nil
                    appState.localWhisperHealthError = nil
                }
            }

            Section("Language") {
                TextField("Language", text: $appState.sttLanguage, prompt: Text("en"))
                Text("ISO 639-1 code: en, zh, ja, etc.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - AI & General Tab

    private var aiAndGeneralTab: some View {
        Form {
            Section("AI Refinement") {
                Picker("Provider", selection: $appState.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        if appState.isConfigured(provider) {
                            Text(provider.displayName).tag(provider)
                        } else {
                            Text("\(provider.displayName) \(provider.requiresAPIKey ? "(No API key)" : "(No endpoint)")")
                                .tag(provider)
                        }
                    }
                }

                modelPickerSection

                Picker("Mode", selection: $appState.refinementMode) {
                    ForEach(RefinementMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                    }
                }
            }

            if appState.aiProvider == .openAICompatible {
                Section("OpenAI-compatible Endpoint") {
                    TextField("Base URL", text: $appState.customAIBaseURL, prompt: Text("http://192.168.10.7:8080/v1"))
                    SecureField("API Key", text: $appState.customAIAPIKey, prompt: Text("Optional"))

                    Text("Any server that speaks the OpenAI Chat Completions API: an AI hub, vLLM, llama.cpp, Ollama, LiteLLM, LM Studio… Include the version prefix the server expects (usually /v1); the app appends /chat/completions and /models. Leave the key empty if the server does not check one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Editor") {
                HStack {
                    Text("Font size")
                    Slider(value: $appState.fontSize, in: 10...24, step: 1)
                    Text("\(Int(appState.fontSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40)
                }
            }

            Section("Automation") {
                Toggle("Auto-refine after recording stops", isOn: $appState.autoRefineOnStop)
                Toggle("Auto-copy transcription to clipboard", isOn: $appState.autoCopyOnTranscribe)
                Toggle("Auto-copy refined text to clipboard", isOn: $appState.autoCopyOnRefine)
            }

            Section("Keyboard Shortcuts") {
                shortcutRow("Double-click", "Edit the text (read-only otherwise)")
                shortcutRow("Esc", "Finish editing")
                shortcutRow("Space", "Start / Stop recording")
                shortcutRow("A", "Append recording / Stop")
                shortcutRow("R", "Refine transcription")
                shortcutRow("⌥R", "Start / Stop recording")
                shortcutRow("⌥A", "Toggle append recording")
                shortcutRow("⌥E", "Refine transcription")
                shortcutRow("⌥C", "Copy current text")
                shortcutRow("⌘⌫", "Clear editor")
            }

            Section("About") {
                HStack {
                    Text("VoiceScribe")
                        .font(.system(size: 13, weight: .semibold))
                    Text("v1.0")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("Speech-to-text with AI refinement for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: appState.aiProvider) { _, newVal in
            // The OpenAI-compatible endpoint keeps its own model setting across switches.
            if newVal != .openAICompatible {
                appState.aiModel = newVal.defaultModel
            }
            modelLoadError = nil
            availableModels = modelCache[newVal] ?? []
        }
        .onChange(of: appState.customAIBaseURL) { _, _ in
            // A model list belongs to the server it came from.
            modelCache[.openAICompatible] = nil
            if appState.aiProvider == .openAICompatible {
                availableModels = []
                modelLoadError = nil
            }
        }
    }

    // MARK: - Model Picker

    private var modelPickerSection: some View {
        Group {
            if appState.aiProvider == .openAICompatible {
                // The model id is free text here; the list from /models is a helper, not a constraint.
                HStack {
                    TextField("Model", text: $appState.customAIModel, prompt: Text("e.g. qwen3.8-27b"))
                    if !availableModels.isEmpty {
                        Menu {
                            ForEach(availableModels, id: \.self) { modelId in
                                Button(modelId) { appState.customAIModel = modelId }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Pick one of the loaded models")
                    }
                    loadModelsButton
                }
            } else if availableModels.isEmpty {
                HStack {
                    Text("Model: \(appState.aiModel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    loadModelsButton
                }
            } else {
                Picker("Model", selection: $appState.aiModel) {
                    ForEach(availableModels, id: \.self) { modelId in
                        Text(modelId).tag(modelId)
                    }
                }
            }

            if let error = modelLoadError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var loadModelsButton: some View {
        Button(action: loadModels) {
            if isLoadingModels {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else {
                Label("Load Models", systemImage: "arrow.clockwise")
            }
        }
        .disabled(isLoadingModels || modelLoadCooldown)
        .font(.system(size: 11))
    }

    @State private var modelLoadTask: Task<Void, Never>?
    @State private var cooldownTask: Task<Void, Never>?

    private func loadModels() {
        guard !isLoadingModels, !modelLoadCooldown else { return }

        let provider = appState.aiProvider
        let apiKey = appState.currentAIApiKey
        let baseURL = appState.currentAIBaseURL

        modelLoadError = nil
        isLoadingModels = true

        modelLoadTask?.cancel()
        modelLoadTask = Task {
            do {
                let models = try await AIService.shared.fetchModels(provider: provider, apiKey: apiKey, baseURL: baseURL)
                guard !Task.isCancelled else { return }
                availableModels = models
                modelCache[provider] = models
                isLoadingModels = false
                startCooldown()
                if provider == .openAICompatible {
                    // Never replace a model the user typed; only fill an empty field.
                    if appState.customAIModel.isEmpty, let first = models.first {
                        appState.customAIModel = first
                    }
                } else if !models.contains(appState.aiModel), let first = models.first {
                    appState.aiModel = first
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingModels = false
                startCooldown()
                modelLoadError = error.localizedDescription
            }
        }
    }

    private func testSTTEndpoint() {
        let endpoint = appState.localWhisperEndpoint
        let model = appState.localWhisperModel
        let language = appState.sttLanguage

        sttTestResult = nil
        isTestingSTT = true
        Task {
            do {
                let text = try await STTService.shared.testLocalEndpoint(endpoint: endpoint, model: model, language: language)
                print("[STT] Test succeeded: \(endpoint)")
                sttTestResult = .success(text)
                appState.localWhisperHealthError = nil
            } catch {
                print("[STT] Test failed: \(endpoint): \(error.localizedDescription)")
                sttTestResult = .failure(error)
                appState.localWhisperHealthError = error.localizedDescription
            }
            isTestingSTT = false
        }
    }

    private func startCooldown() {
        modelLoadCooldown = true
        cooldownTask?.cancel()
        cooldownTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            modelLoadCooldown = false
        }
    }

    // MARK: - Helpers

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
