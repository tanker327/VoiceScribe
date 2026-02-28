import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var modelLoadError: String?

    var body: some View {
        TabView {
            sttTab
                .tabItem { Label("Transcription", systemImage: "mic") }

            aiTab
                .tabItem { Label("AI Refinement", systemImage: "brain") }

            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 520, height: 420)
    }

    // MARK: - Speech-to-Text Tab

    private var sttTab: some View {
        Form {
            Section("Speech-to-Text Provider") {
                Picker("Provider", selection: $appState.sttProvider) {
                    ForEach(STTProvider.allCases) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.rawValue)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(appState.sttProvider.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI API Key") {
                SecureField("sk-...", text: $appState.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Required for OpenAI Whisper and GPT-4o Transcribe.")
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

    // MARK: - AI Refinement Tab

    private var aiTab: some View {
        Form {
            Section("AI Provider for Refinement") {
                Picker("Provider", selection: $appState.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if appState.aiProvider == .claude {
                Section("Anthropic (Claude)") {
                    SecureField("Claude API Key", text: $appState.claudeAPIKey)
                        .textFieldStyle(.roundedBorder)

                    modelPickerSection
                }
            }

            if appState.aiProvider == .openai {
                Section("OpenAI") {
                    Text("Uses the same API key from the Transcription tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    modelPickerSection
                }
            }

            if appState.aiProvider == .xai {
                Section("xAI (Grok)") {
                    SecureField("xAI API Key", text: $appState.xaiAPIKey)
                        .textFieldStyle(.roundedBorder)

                    modelPickerSection
                }
            }

            Section("Default Refinement Mode") {
                Picker("Mode", selection: $appState.refinementMode) {
                    ForEach(RefinementMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: appState.aiProvider) { _, newVal in
            appState.aiModel = newVal.defaultModel
            appState.availableModels = []
            modelLoadError = nil
        }
    }

    // MARK: - Model Picker

    private var modelPickerSection: some View {
        Group {
            if appState.availableModels.isEmpty {
                HStack {
                    Text("Model: \(appState.aiModel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: loadModels) {
                        if appState.isLoadingModels {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("Load Models", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(appState.isLoadingModels)
                    .font(.system(size: 11))
                }
            } else {
                Picker("Model", selection: $appState.aiModel) {
                    ForEach(appState.availableModels, id: \.self) { modelId in
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
        let provider = appState.aiProvider
        let apiKey: String
        switch provider {
        case .claude: apiKey = appState.claudeAPIKey
        case .openai: apiKey = appState.openAIAPIKey
        case .xai:    apiKey = appState.xaiAPIKey
        }

        modelLoadError = nil
        appState.isLoadingModels = true

        Task {
            do {
                let models = try await AIService.shared.fetchModels(provider: provider, apiKey: apiKey)
                await MainActor.run {
                    appState.availableModels = models
                    appState.isLoadingModels = false
                    // Keep current selection if it's in the list, otherwise pick first
                    if !models.contains(appState.aiModel), let first = models.first {
                        appState.aiModel = first
                    }
                }
            } catch {
                await MainActor.run {
                    appState.isLoadingModels = false
                    modelLoadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
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
                Toggle("Auto-copy refined text to clipboard", isOn: $appState.autoCopyOnRefine)
            }

            Section("Keyboard Shortcuts") {
                shortcutRow("⌥R", "Start / Stop recording")
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
    }

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
