import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var modelLoadError: String?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadCooldown = false
    @State private var modelCache: [AIProvider: [String]] = [:]

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
                SecureField("sk-...", text: $appState.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used for Whisper/GPT-4o transcription and OpenAI refinement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Claude (Anthropic)") {
                SecureField("sk-ant-...", text: $appState.claudeAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Used for Claude AI refinement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("xAI (Grok)") {
                SecureField("xai-...", text: $appState.xaiAPIKey)
                    .textFieldStyle(.roundedBorder)
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
                            Text(provider.rawValue)
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
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Host").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("192.168.10.110", text: $appState.localWhisperHost)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading) {
                            Text("Port").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("8000", text: $appState.localWhisperPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Path").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("/api/transcribe", text: $appState.localWhisperPath)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("Model name (e.g. whisper-large-v3)", text: $appState.localWhisperModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Uses OpenAI-compatible API format. Works with whisper.cpp server, faster-whisper-server, LocalAI, etc.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Language") {
                TextField("Language code (e.g. en, zh, ja)", text: $appState.sttLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text("ISO 639-1 code. Leave as 'en' for English. Use 'zh' for Chinese, 'ja' for Japanese, etc.")
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
                        if appState.hasAPIKey(for: provider) {
                            Text(provider.rawValue).tag(provider)
                        } else {
                            Text("\(provider.rawValue) (No API key)")
                                .tag(provider)
                        }
                    }
                }

                modelPickerSection

                Picker("Mode", selection: $appState.refinementMode) {
                    ForEach(RefinementMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
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
            appState.aiModel = newVal.defaultModel
            modelLoadError = nil
            availableModels = modelCache[newVal] ?? []
        }
    }

    // MARK: - Model Picker

    private var modelPickerSection: some View {
        Group {
            if availableModels.isEmpty {
                HStack {
                    Text("Model: \(appState.aiModel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
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

    private func loadModels() {
        guard !isLoadingModels, !modelLoadCooldown else { return }

        let provider = appState.aiProvider
        let apiKey = appState.currentAIApiKey

        modelLoadError = nil
        isLoadingModels = true

        Task {
            do {
                let models = try await AIService.shared.fetchModels(provider: provider, apiKey: apiKey)
                await MainActor.run {
                    availableModels = models
                    modelCache[provider] = models
                    isLoadingModels = false
                    modelLoadCooldown = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { modelLoadCooldown = false }
                    if !models.contains(appState.aiModel), let first = models.first {
                        appState.aiModel = first
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingModels = false
                    modelLoadCooldown = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { modelLoadCooldown = false }
                    modelLoadError = error.localizedDescription
                }
            }
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
