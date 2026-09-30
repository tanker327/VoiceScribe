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
    @State private var textBeforeRecording: String = ""
    /// True while the editor accepts typing. Entered by double-clicking the editor, left with
    /// Escape, a click elsewhere, or any action that replaces the text.
    @State private var isEditingText = false
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var refinementTask: Task<Void, Never>?
    @State private var toastTask: Task<Void, Never>?
    @State private var spaceKeyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var hostWindow: NSWindow?

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
        .background(WindowAccessor { window in
            if hostWindow !== window { hostWindow = window }
        })
        .onAppear {
            installSpaceKeyMonitor()
            installMouseMonitor()
            applyAppearance()
            checkLocalWhisperHealth()
            // Resign first responder so the editor doesn't auto-focus on launch
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            transcriptionTask?.cancel()
            refinementTask?.cancel()
            toastTask?.cancel()
            removeSpaceKeyMonitor()
            removeMouseMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
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
            if appState.refinementMode == .custom {
                controlsBar
                Divider()
            }
            editorArea
            Divider()
            statusBar
            Divider()
            actionBar
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if !appState.isRecording {
                Circle()
                    .fill(isEditingText ? Color.accentColor : Color.gray.opacity(0.25))
                    .frame(width: 9, height: 9)

                Text(isEditingText ? "Editing · Esc to finish" : appState.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // STT badge (red with a warning icon when the local server failed its health check)
            let sttError = appState.sttProvider == .localWhisper ? appState.localWhisperHealthError : nil
            HStack(spacing: 3) {
                if sttError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                Text(appState.sttProvider.displayName)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(sttError == nil ? Color.primary : Color.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((sttError == nil ? Color.accentColor : Color.red).opacity(0.12))
            .cornerRadius(4)
            .help(sttError.map { "Local Whisper is not reachable: \($0)" } ?? "")

            Text(appState.aiProvider.displayName)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(4)

            Label(recorder.inputDeviceName, systemImage: "mic")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)

            Text("\(wordCount) words · \(charCount) chars")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Runs once at launch so a down or misconfigured local Whisper server shows on the badge
    /// before the user records anything.
    private func checkLocalWhisperHealth() {
        guard appState.sttProvider == .localWhisper else { return }
        let url = appState.localWhisperHealthURL
        Task {
            do {
                try await STTService.shared.checkHealth(url: url)
                appState.localWhisperHealthError = nil
            } catch {
                print("[STT] Local Whisper unhealthy: \(error.localizedDescription)")
                appState.localWhisperHealthError = error.localizedDescription
            }
        }
    }

    // MARK: - Custom Prompt Bar

    private var controlsBar: some View {
        HStack {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Custom prompt…", text: $customPrompt)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
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
            Text("Press Record or double-click to type")
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Space Record · A Append · R Refine · ⌥C Copy")
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
            // Recording indicator on the left
            if appState.isRecording {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .overlay {
                            Circle()
                                .fill(Color.red.opacity(0.35))
                                .frame(width: 16, height: 16)
                                .scaleEffect(1.3)
                                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: appState.isRecording)
                        }

                    AudioLevelBar(meter: recorder.levelMeter)
                }
            }

            Spacer()

            if appState.isRecording {
                // Recording phase: Stop + Abort
                Button(action: abortRecording) {
                    Label("Abort", systemImage: "xmark.circle.fill")
                }
                .controlSize(.large)
                .tint(.gray)

                Button(action: toggleRecording) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .option)
            } else if hasContent || appState.isTranscribing {
                // Post-transcription phase
                Button(action: clearAll) {
                    Image(systemName: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .controlSize(.large)
                .help("Clear")
                .accessibilityLabel("Clear editor")

                Button(action: copyToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .option)
                .controlSize(.large)
                .disabled(currentText.isEmpty)
                .help("Copy")
                .accessibilityLabel("Copy to clipboard")

                refineButton

                Button(action: toggleAppendRecording) {
                    Label("Append", systemImage: "plus.circle.fill")
                }
                .controlSize(.large)
                .tint(.orange)
                .keyboardShortcut("a", modifiers: .option)
                .disabled(!canStartRecording)

                Button(action: toggleRecording) {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .option)
                .disabled(!canStartRecording)
            } else {
                // Initial phase: Record only
                Button(action: toggleRecording) {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .option)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
        .animation(.easeInOut(duration: 0.15), value: appState.isRecording)
        .animation(.easeInOut(duration: 0.15), value: hasContent)
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

            Button {
                cycleAppearance()
            } label: {
                Image(systemName: appState.appAppearance.icon)
            }
            .help("Appearance: \(appState.appAppearance.displayName)")

            Button { appState.fontSize = max(10, appState.fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .accessibilityLabel("Decrease font size")

            Button { appState.fontSize = min(24, appState.fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityLabel("Increase font size")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }

    private func setWindowFloating(_ floating: Bool) {
        hostWindow?.level = floating ? .floating : .normal
    }

    private func cycleAppearance() {
        appState.appAppearance = appState.appAppearance.next
        applyAppearance()
    }

    private func applyAppearance() {
        switch appState.appAppearance {
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
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
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.transcribedText = entry.rawText
                        appState.refinedText = entry.refinedText ?? ""
                        appState.showingRefined = entry.refinedText != nil
                        // Refine/Append must update this entry, not whichever was created last.
                        currentHistoryEntryID = entry.id
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation {
                                appState.history.removeAll { $0.id == entry.id }
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                }
                .listStyle(.sidebar)
                // Loading an entry while a result is in flight would let that result land on it.
                .disabled(appState.isTranscribing || appState.isRefining)
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
        currentText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    private var charCount: Int {
        currentText.count
    }

    private var hasContent: Bool {
        !appState.transcribedText.isEmpty || !appState.refinedText.isEmpty
    }

    /// Shared by the Record/Append buttons and the bare-key monitor so they can never disagree.
    private var canStartRecording: Bool {
        !appState.isRecording && !appState.isTranscribing && !appState.isRefining
    }

    /// Shared by the Refine button, its menu, and the R key.
    private var canRefine: Bool {
        !appState.transcribedText.isEmpty && !appState.isRecording && !appState.isTranscribing && !appState.isRefining
    }

    // MARK: - Actions

    private func toggleRecording() {
        if appState.isRecording {
            stopAndTranscribe()
        } else {
            isAppendMode = false
            startRecording()
        }
    }

    private func toggleAppendRecording() {
        if appState.isRecording {
            stopAndTranscribe()
        } else {
            isAppendMode = true
            startAppendRecording()
        }
    }

    private func startRecording() {
        guard canStartRecording else { return }
        endEditing()
        refinementTask?.cancel()
        currentHistoryEntryID = nil
        textBeforeRecording = appState.transcribedText
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
        guard canStartRecording else { return }
        endEditing()
        refinementTask?.cancel()
        textBeforeRecording = appState.transcribedText
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

        transcriptionTask?.cancel()
        transcriptionTask = Task {
            // Runs on success, failure and cancellation (window closed, Clear pressed),
            // so the UI can never be left stuck in the transcribing state.
            defer {
                isAppendMode = false
                appState.isTranscribing = false
                recorder.cleanupTempFile()
            }
            do {
                let text = try await STTService.shared.transcribe(
                    fileURL: audioURL,
                    provider: appState.sttProvider,
                    apiKey: appState.openAIAPIKey,
                    localEndpoint: appState.localWhisperEndpoint,
                    localModel: appState.localWhisperModel,
                    language: appState.sttLanguage
                )
                guard !Task.isCancelled else { return }

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
                        mode: appState.refinementMode,
                        sttProvider: appState.sttProvider
                    )
                    appState.addHistoryEntry(entry)
                    currentHistoryEntryID = entry.id
                }
                appState.statusMessage = "Transcribed ✓"

                if appState.autoCopyOnTranscribe && !appState.autoRefineOnStop {
                    copyToPasteboard(appState.transcribedText)
                }

                if appState.autoRefineOnStop {
                    appState.isTranscribing = false
                    refineText()
                }
            } catch {
                guard !Task.isCancelled else { return }
                appState.statusMessage = "Transcription failed"
                showErrorAlert(error.localizedDescription)
            }
        }
    }

    /// Refine with the mode chosen in Settings (or last picked from the split-button menu).
    private func refineText() {
        refineText(with: appState.refinementMode)
    }

    private func refineText(with mode: RefinementMode) {
        guard canRefine else { return }
        endEditing()

        appState.refinementMode = mode

        let prompt: String
        if mode == .custom {
            prompt = customPrompt.isEmpty ? "Clean up this transcription." : customPrompt
        } else {
            prompt = mode.systemPrompt
        }

        let apiKey = appState.currentAIApiKey

        appState.isRefining = true
        appState.statusMessage = "Refining…"

        refinementTask?.cancel()
        refinementTask = Task {
            // Runs on success, failure and cancellation so isRefining can never stay stuck.
            defer { appState.isRefining = false }
            do {
                let refined = try await AIService.shared.refine(
                    text: appState.transcribedText,
                    systemPrompt: prompt,
                    provider: appState.aiProvider,
                    apiKey: apiKey,
                    baseURL: appState.currentAIBaseURL,
                    model: appState.currentAIModel
                )
                guard !Task.isCancelled else { return }

                appState.refinedText = refined
                appState.showingRefined = true
                appState.statusMessage = "Refined ✓"

                // Update history entry with refined text
                if let entryID = currentHistoryEntryID,
                   let idx = appState.history.firstIndex(where: { $0.id == entryID }) {
                    appState.history[idx].refinedText = refined
                    appState.history[idx].mode = appState.refinementMode
                }

                if appState.autoCopyOnRefine {
                    copyToPasteboard(refined)
                }
            } catch {
                guard !Task.isCancelled else { return }
                appState.statusMessage = "Refinement failed"
                showErrorAlert(error.localizedDescription)
            }
        }
    }

    /// Single clipboard write path shared by the Copy button and both auto-copy settings.
    @discardableResult
    private func copyToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyToClipboard() {
        if copyToPasteboard(currentText) {
            toastTask?.cancel()
            withAnimation { showCopiedToast = true }
            toastTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation { showCopiedToast = false }
            }
        } else {
            showErrorAlert("Failed to copy to clipboard.")
        }
    }

    private func clearAll() {
        // Cancel in-flight work so a late result cannot repopulate the cleared editor
        // or overwrite the clipboard. The tasks' defer blocks also reset these flags.
        transcriptionTask?.cancel()
        refinementTask?.cancel()
        endEditing()
        appState.isTranscribing = false
        appState.isRefining = false
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

    // MARK: - Refine Button (with mode picker)

    private var refineButton: some View {
        let isDisabled = !canRefine

        return HStack(spacing: 0) {
            // Refine action
            Button(action: refineText) {
                Label("Refine", systemImage: "sparkles")
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .option)

            Divider()
                .frame(height: 16)
                .opacity(0.4)

            // Mode picker chevron - each option triggers refinement directly
            Menu {
                ForEach(RefinementMode.allCases) { mode in
                    Button {
                        refineText(with: mode)
                    } label: {
                        Label(mode.displayName, systemImage: mode.icon)
                    }
                }
            } label: {
                Color.clear.frame(width: 1, height: 1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 16)
        }
        .foregroundColor(isDisabled ? .secondary : .white)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDisabled ? Color.accentColor.opacity(0.3) : Color.accentColor)
        )
        .help(appState.refinementMode.displayName)
        .disabled(isDisabled)
    }

    private func abortRecording() {
        transcriptionTask?.cancel()
        refinementTask?.cancel()
        _ = recorder.stopRecording()
        recorder.cleanupTempFile()
        appState.isRecording = false
        appState.statusMessage = "Recording aborted"
        isAppendMode = false
        appState.transcribedText = textBeforeRecording
        appState.refinedText = ""
        appState.showingRefined = false
    }

    // MARK: - Editor Field

    private func editorField(text: Binding<String>) -> some View {
        TranscriptEditor(
            text: text,
            isEditing: $isEditingText,
            isEnabled: !appState.isRecording,
            fontSize: CGFloat(appState.fontSize)
        )
        .overlay {
            if isEditingText {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Leaves edit mode: the editor goes back to read-only and gives up focus so the bare keys
    /// work again. Safe to call when not editing.
    private func endEditing() {
        isEditingText = false
        if let window = hostWindow, window.firstResponder is TranscriptTextView {
            window.makeFirstResponder(nil)
        }
    }

    // MARK: - Event Monitors

    private func installSpaceKeyMonitor() {
        removeSpaceKeyMonitor()
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors see every window in the app. Act only on the main window so
            // Space/A/R in Settings keep operating the focused toggle or radio button.
            guard let window = event.window, window === hostWindow else { return event }

            // Only intercept bare keys (no modifiers like Cmd, Opt, Ctrl)
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] else {
                return event
            }

            // An editable text view (the editor in edit mode, or the custom prompt field) gets the
            // keys as typing. The read-only editor also takes focus on a single click, but it
            // must not swallow the shortcuts.
            if let textView = window.firstResponder as? NSTextView, textView.isEditable {
                // Escape leaves edit mode, unless an input method is composing: then Escape
                // cancels the composition and the text view must see it.
                if event.keyCode == 53, textView is TranscriptTextView, !textView.hasMarkedText() {
                    endEditing()
                    return nil
                }
                return event
            }

            switch event.keyCode {
            case 49: // Space: record / stop
                if appState.isRecording {
                    stopAndTranscribe()
                    return nil
                }
                if canStartRecording {
                    toggleRecording()
                    return nil
                }
            case 0 where hasContent: // A: append / stop
                if appState.isRecording {
                    stopAndTranscribe()
                    return nil
                }
                if canStartRecording {
                    toggleAppendRecording()
                    return nil
                }
            case 15: // R: refine
                if canRefine {
                    refineText()
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func removeSpaceKeyMonitor() {
        if let monitor = spaceKeyMonitor {
            NSEvent.removeMonitor(monitor)
            spaceKeyMonitor = nil
        }
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window === hostWindow,
                  let textView = window.firstResponder as? NSTextView else {
                return event
            }

            // Check if the click landed inside the text view; if not, resign focus
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

// MARK: - Audio Level Bar

/// Observes only the recorder's level meter, so the per-buffer level updates
/// re-render these 16 bars and nothing else.
private struct AudioLevelBar: View {
    @ObservedObject var meter: AudioRecorderService.LevelMeter
    private let barCount = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: i))
                    .frame(width: 4, height: 16)
                    .opacity(Float(i) / Float(barCount) < meter.level * 50 ? 1 : 0.15)
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let greenEnd = Int(Double(barCount) * 0.65)
        let yellowEnd = Int(Double(barCount) * 0.85)
        if index < greenEnd { return .green }
        if index < yellowEnd { return .yellow }
        return .red
    }
}

// MARK: - Window Accessor

/// Reports the NSWindow hosting this SwiftUI view, so the event monitors can be
/// scoped to the main window instead of every window in the app.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReporterView {
        let view = WindowReporterView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowReporterView, context: Context) {
        nsView.onWindowChange = onResolve
    }

    final class WindowReporterView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            let callback = onWindowChange
            // Defer so SwiftUI state is not mutated during the view-hierarchy update.
            DispatchQueue.main.async { callback?(window) }
        }
    }
}
