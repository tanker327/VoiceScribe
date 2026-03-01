import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recorder = AudioRecorderService()
    @State private var customPrompt = ""
    @State private var showHistory = false
    @State private var showCopiedToast = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var alwaysOnTop = false
    @State private var isAppendMode = false
    @State private var currentHistoryEntryID: UUID?
    @State private var isLongPressing = false
    @State private var pressStartTime: Date?
    @State private var spaceKeyMonitor: Any?
    @State private var mouseMonitor: Any?

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
        .onAppear {
            installSpaceKeyMonitor()
            installMouseMonitor()
            // Resign first responder so the editor doesn't auto-focus on launch
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            removeSpaceKeyMonitor()
            removeMouseMonitor()
        }
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
                    .opacity(Float(i) / 12.0 < recorder.audioLevel * 50 ? 1 : 0.15)
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

            editorField(text: $appState.refinedText)
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

            editorField(text: $appState.transcribedText)
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
            Text("Space  Record  ·  ⌥E  Refine  ·  ⌥C  Copy")
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
            // Record / Stop / Abort
            recordButton(
                isActive: appState.isRecording && !isAppendMode,
                label: "Record",
                icon: "mic.fill",
                tint: .accentColor,
                tapAction: toggleRecording,
                disabled: appState.isTranscribing || (appState.isRecording && isAppendMode)
            )
            .keyboardShortcut("r", modifiers: .option)

            // Append / Stop / Abort
            recordButton(
                isActive: appState.isRecording && isAppendMode,
                label: "Append",
                icon: "plus.circle.fill",
                tint: .orange,
                tapAction: toggleAppendRecording,
                disabled: appState.isTranscribing || (appState.isRecording && !isAppendMode)
            )
            .keyboardShortcut("a", modifiers: .option)

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

            Button {
                alwaysOnTop.toggle()
                setWindowFloating(alwaysOnTop)
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
            }
            .help(alwaysOnTop ? "Disable always on top" : "Keep window on top")

            Button { appState.fontSize = max(10, appState.fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }

            Button { appState.fontSize = min(24, appState.fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
        }
    }

    private func setWindowFloating(_ floating: Bool) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        window.level = floating ? .floating : .normal
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
            isLongPressing = false
            pressStartTime = nil
            stopAndTranscribe()
        } else {
            isAppendMode = false
            startRecording()
        }
    }

    private func toggleAppendRecording() {
        if appState.isRecording {
            isLongPressing = false
            pressStartTime = nil
            stopAndTranscribe()
        } else {
            isAppendMode = true
            startAppendRecording()
        }
    }

    private func startRecording() {
        currentHistoryEntryID = nil
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

    private func startAppendRecording() {
        appState.refinedText = ""
        appState.showingRefined = false

        do {
            try recorder.startRecording()
            appState.isRecording = true
            appState.statusMessage = "Recording (append)…"
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
                    if isAppendMode && !appState.transcribedText.isEmpty {
                        appState.transcribedText += "\n" + text
                        // Update existing history entry with appended text
                        if let entryID = currentHistoryEntryID,
                           let idx = appState.history.firstIndex(where: { $0.id == entryID }) {
                            appState.history[idx].rawText = appState.transcribedText
                        }
                    } else {
                        appState.transcribedText = text
                        // Create a new history entry immediately
                        let entry = TranscriptionEntry(
                            rawText: text,
                            mode: appState.refinementMode.rawValue,
                            sttProvider: appState.sttProvider.rawValue
                        )
                        appState.history.insert(entry, at: 0)
                        if appState.history.count > 50 { appState.history = Array(appState.history.prefix(50)) }
                        currentHistoryEntryID = entry.id
                    }
                    isAppendMode = false
                    appState.isTranscribing = false
                    appState.statusMessage = "Transcribed ✓"
                    recorder.cleanupTempFile()

                    // Auto-copy transcription to clipboard
                    if appState.autoCopyOnTranscribe && !appState.autoRefineOnStop {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.transcribedText, forType: .string)
                    }

                    if appState.autoRefineOnStop {
                        refineText()
                    }
                }
            } catch {
                await MainActor.run {
                    isAppendMode = false
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

        let apiKey = appState.currentAIApiKey

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

                    // Update history entry with refined text
                    if let entryID = currentHistoryEntryID,
                       let idx = appState.history.firstIndex(where: { $0.id == entryID }) {
                        appState.history[idx].refinedText = refined
                        appState.history[idx].mode = appState.refinementMode.rawValue
                    }

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
        currentHistoryEntryID = nil
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Record Button (with long-press abort)

    private func recordButton(
        isActive: Bool,
        label: String,
        icon: String,
        tint: Color,
        tapAction: @escaping () -> Void,
        disabled: Bool
    ) -> some View {
        let buttonLabel: String
        let buttonIcon: String
        let buttonTint: Color

        if isActive && isLongPressing {
            buttonLabel = "Abort"
            buttonIcon = "xmark.circle.fill"
            buttonTint = .gray
        } else if isActive {
            buttonLabel = "Stop"
            buttonIcon = "stop.fill"
            buttonTint = .red
        } else {
            buttonLabel = label
            buttonIcon = icon
            buttonTint = tint
        }

        return Label(buttonLabel, systemImage: buttonIcon)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(buttonTint.opacity(isLongPressing ? 0.15 : 0.0))
            )
            .foregroundStyle(disabled ? .secondary : buttonTint)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !disabled, isActive, pressStartTime == nil else { return }
                        pressStartTime = Date()
                        // Schedule the visual transition to "Abort" after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            guard pressStartTime != nil else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isLongPressing = true
                            }
                        }
                    }
                    .onEnded { _ in
                        guard !disabled else { return }
                        let held = pressStartTime.map { Date().timeIntervalSince($0) } ?? 0
                        pressStartTime = nil

                        if isActive && held >= 2.0 {
                            abortRecording()
                        } else if !isLongPressing {
                            tapAction()
                        }
                        isLongPressing = false
                    }
            )
            .opacity(disabled ? 0.4 : 1.0)
    }

    private func abortRecording() {
        _ = recorder.stopRecording()
        recorder.cleanupTempFile()
        appState.isRecording = false
        appState.statusMessage = "Recording aborted"
        isAppendMode = false
        isLongPressing = false
        pressStartTime = nil
    }

    // MARK: - Editor Field

    private func editorField(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: CGFloat(appState.fontSize), weight: .regular, design: .default))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Event Monitors

    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept bare Space (no modifiers like Cmd, Opt, Ctrl)
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] else {
                return event
            }

            // If the first responder is a text view, let Space type normally
            if let responder = event.window?.firstResponder,
               responder is NSTextView {
                return event
            }

            // Otherwise toggle recording
            if !appState.isTranscribing {
                toggleRecording()
            }
            return nil // consume the event
        }
    }

    private func removeSpaceKeyMonitor() {
        if let monitor = spaceKeyMonitor {
            NSEvent.removeMonitor(monitor)
            spaceKeyMonitor = nil
        }
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let firstResponder = window.firstResponder,
                  firstResponder is NSTextView else {
                return event
            }

            // Check if the click landed inside the text view; if not, resign focus
            let textView = firstResponder as! NSTextView
            let locationInTextView = textView.convert(event.locationInWindow, from: nil)
            if !textView.bounds.contains(locationInTextView) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}
