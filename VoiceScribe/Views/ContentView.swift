import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = AudioRecorderService()
    @State private var customPrompt = ""
    @State private var showHistory = false
    @State private var showCopiedToast = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        HSplitView {
            mainPanel
                .frame(minWidth: 440)

            if showHistory {
                historySidebar
                    .frame(width: 240)
            }
        }
        .toolbar { toolbarItems }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .overlay(alignment: .top) {
            if showCopiedToast {
                toastView("Copied to clipboard ✓")
            }
        }
    }

    // MARK: - Main Panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            controlsBar
            Divider()
            editorArea
            Divider()
            actionBar
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            // Recording dot
            Circle()
                .fill(appState.isRecording ? Color.red : Color.gray.opacity(0.25))
                .frame(width: 9, height: 9)
                .overlay {
                    if appState.isRecording {
                        Circle()
                            .fill(Color.red.opacity(0.35))
                            .frame(width: 16, height: 16)
                            .scaleEffect(1.3)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: appState.isRecording)
                    }
                }

            Text(appState.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            // Audio level meter
            if appState.isRecording {
                audioLevelBar
            }

            Spacer()

            // STT badge
            Text(appState.sttProvider.rawValue)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(4)

            Text("\(wordCount) words · \(charCount) chars")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var audioLevelBar: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: i))
                    .frame(width: 3, height: 10)
                    .opacity(Float(i) / 12.0 < recorder.audioLevel * 8 ? 1 : 0.15)
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        if index < 8 { return .green }
        if index < 10 { return .yellow }
        return .red
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        HStack(spacing: 10) {
            // Refinement mode
            Picker("", selection: $appState.refinementMode) {
                ForEach(RefinementMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .help("AI refinement mode")

            if appState.refinementMode == .custom {
                TextField("Custom prompt…", text: $customPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            Spacer()

            // AI provider badge
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                Text(appState.aiProvider.rawValue)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Editor Area

    private var editorArea: some View {
        ZStack {
            if appState.showingRefined && !appState.refinedText.isEmpty {
                refinedView
            } else {
                rawView
            }

            // Empty placeholder
            if currentText.isEmpty && !appState.isRecording && !appState.isTranscribing {
                placeholderView
            }

            // Loading overlays
            if appState.isTranscribing {
                loadingOverlay(text: "Transcribing audio…", icon: "waveform")
            }
            if appState.isRefining {
                loadingOverlay(text: "Refining with AI…", icon: "sparkles")
            }
        }
    }

    private var refinedView: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Refined Text", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                Spacer()
                Button("Show Original") { appState.showingRefined = false }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.07))

            TextEditor(text: $appState.refinedText)
                .font(.system(size: CGFloat(appState.fontSize)))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
    }

    private var rawView: some View {
        VStack(spacing: 0) {
            if !appState.refinedText.isEmpty {
                HStack {
                    Label("Original Text", systemImage: "mic")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Refined") { appState.showingRefined = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
            }

            TextEditor(text: $appState.transcribedText)
                .font(.system(size: CGFloat(appState.fontSize)))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(.secondary.opacity(0.35))
            Text("Press Record or start typing")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("⌥R  Record  ·  ⌥E  Refine  ·  ⌥C  Copy")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.35))
        }
        .allowsHitTesting(false)
    }

    private func loadingOverlay(text: String, icon: String) -> some View {
        ZStack {
            Color.black.opacity(0.04)
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Label(text, systemImage: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            // Record
            Button(action: toggleRecording) {
                Label(appState.isRecording ? "Stop" : "Record",
                      systemImage: appState.isRecording ? "stop.fill" : "mic.fill")
                    .fontWeight(.medium)
            }
            .keyboardShortcut("r", modifiers: .option)
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(appState.isRecording ? .red : .accentColor)
            .disabled(appState.isTranscribing)

            // Refine
            Button(action: refineText) {
                Label("Refine", systemImage: "sparkles")
                    .fontWeight(.medium)
            }
            .keyboardShortcut("e", modifiers: .option)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(appState.transcribedText.isEmpty || appState.isRefining || appState.isRecording)

            Spacer()

            // Copy
            Button(action: copyToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .option)
            .controlSize(.large)
            .disabled(currentText.isEmpty)

            // Clear
            Button(action: clearAll) {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Toggle history sidebar")

            Spacer()

            Button { appState.fontSize = max(10, appState.fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }

            Button { appState.fontSize = min(24, appState.fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
        }
    }

    // MARK: - History Sidebar

    private var historySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !appState.history.isEmpty {
                    Button("Clear All") { appState.history.removeAll() }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            if appState.history.isEmpty {
                Spacer()
                Text("No history yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(appState.history) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.refinedText ?? entry.rawText)
                            .font(.system(size: 11))
                            .lineLimit(3)
                        HStack {
                            Text(entry.date, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.mode)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(3)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.transcribedText = entry.rawText
                        appState.refinedText = entry.refinedText ?? ""
                        appState.showingRefined = entry.refinedText != nil
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }

    // MARK: - Toast

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 3)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Computed

    private var currentText: String {
        appState.showingRefined ? appState.refinedText : appState.transcribedText
    }

    private var wordCount: Int {
        currentText.split(separator: " ").count
    }

    private var charCount: Int {
        currentText.count
    }

    // MARK: - Actions

    private func toggleRecording() {
        if appState.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // Save current text to history before clearing
        if !appState.transcribedText.isEmpty {
            let entry = TranscriptionEntry(
                rawText: appState.transcribedText,
                refinedText: appState.refinedText.isEmpty ? nil : appState.refinedText,
                mode: appState.refinementMode.rawValue,
                sttProvider: appState.sttProvider.rawValue
            )
            appState.history.insert(entry, at: 0)
            if appState.history.count > 50 { appState.history = Array(appState.history.prefix(50)) }
            print("[History] Saved entry to history (\(entry.rawText.prefix(50))...)")
        }

        appState.refinedText = ""
        appState.showingRefined = false
        appState.transcribedText = ""

        do {
            try recorder.startRecording()
            appState.isRecording = true
            appState.statusMessage = "Recording…"
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        guard let audioURL = recorder.stopRecording() else {
            appState.isRecording = false
            appState.statusMessage = "No audio captured"
            return
        }

        appState.isRecording = false
        appState.isTranscribing = true
        appState.statusMessage = "Transcribing…"

        Task {
            do {
                let text = try await STTService.shared.transcribe(
                    fileURL: audioURL,
                    provider: appState.sttProvider,
                    apiKey: appState.openAIAPIKey,
                    localEndpoint: appState.localWhisperEndpoint,
                    localModel: appState.localWhisperModel,
                    language: appState.sttLanguage
                )

                await MainActor.run {
                    appState.transcribedText = text
                    appState.isTranscribing = false
                    appState.statusMessage = "Transcribed ✓"
                    recorder.cleanupTempFile()

                    if appState.autoRefineOnStop {
                        refineText()
                    }
                }
            } catch {
                await MainActor.run {
                    appState.isTranscribing = false
                    appState.statusMessage = "Transcription failed"
                    recorder.cleanupTempFile()
                    showErrorAlert(error.localizedDescription)
                }
            }
        }
    }

    private func refineText() {
        guard !appState.transcribedText.isEmpty else { return }

        let prompt: String
        if appState.refinementMode == .custom {
            prompt = customPrompt.isEmpty ? "Clean up this transcription." : customPrompt
        } else {
            prompt = appState.refinementMode.systemPrompt
        }

        let apiKey = appState.aiProvider == .claude ? appState.claudeAPIKey : appState.openAIAPIKey

        appState.isRefining = true
        appState.statusMessage = "Refining…"

        Task {
            do {
                let refined = try await AIService.shared.refine(
                    text: appState.transcribedText,
                    systemPrompt: prompt,
                    provider: appState.aiProvider,
                    apiKey: apiKey,
                    model: appState.aiModel
                )

                await MainActor.run {
                    appState.refinedText = refined
                    appState.showingRefined = true
                    appState.isRefining = false
                    appState.statusMessage = "Refined ✓"

                    // Auto-copy
                    if appState.autoCopyOnRefine {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(refined, forType: .string)
                    }


                }
            } catch {
                await MainActor.run {
                    appState.isRefining = false
                    appState.statusMessage = "Refinement failed"
                    showErrorAlert(error.localizedDescription)
                }
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText, forType: .string)
        withAnimation { showCopiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedToast = false }
        }
    }

    private func clearAll() {
        appState.transcribedText = ""
        appState.refinedText = ""
        appState.showingRefined = false
        appState.statusMessage = "Ready"
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }
}
