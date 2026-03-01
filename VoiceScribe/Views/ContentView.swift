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
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var refinementTask: Task<Void, Never>?
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
            applyAppearance()
            // Resign first responder so the editor doesn't auto-focus on launch
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            transcriptionTask?.cancel()
            refinementTask?.cancel()
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
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: 9, height: 9)

                Text(appState.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // STT badge
            Text(appState.sttProvider.rawValue)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(4)

            Text(appState.aiProvider.rawValue)
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

    private var audioLevelBar: some View {
        HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: i, total: 16))
                    .frame(width: 4, height: 16)
                    .opacity(Float(i) / 16.0 < recorder.audioLevel * 50 ? 1 : 0.15)
            }
        }
    }

    private func barColor(for index: Int, total: Int = 16) -> Color {
        let greenEnd = Int(Double(total) * 0.65)
        let yellowEnd = Int(Double(total) * 0.85)
        if index < greenEnd { return .green }
        if index < yellowEnd { return .yellow }
        return .red
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
            Text("Press Record or start typing")
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

                    audioLevelBar
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

                Button(action: copyToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .option)
                .controlSize(.large)
                .disabled(currentText.isEmpty)
                .help("Copy")

                refineButton

                Button(action: toggleAppendRecording) {
                    Label("Append", systemImage: "plus.circle.fill")
                }
                .controlSize(.large)
                .tint(.orange)
                .keyboardShortcut("a", modifiers: .option)
                .disabled(appState.isTranscribing || appState.isRefining)

                Button(action: toggleRecording) {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .option)
                .disabled(appState.isTranscribing || appState.isRefining)
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
                Image(systemName: appearanceIcon)
            }
            .help("Appearance: \(appState.appAppearance.capitalized)")

            Button { appState.fontSize = max(10, appState.fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }

            Button { appState.fontSize = min(24, appState.fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }

    private func setWindowFloating(_ floating: Bool) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        window.level = floating ? .floating : .normal
    }

    private var appearanceIcon: String {
        switch appState.appAppearance {
        case "light": return "sun.max.fill"
        case "dark":  return "moon.fill"
        default:      return "circle.lefthalf.filled"
        }
    }

    private func cycleAppearance() {
        switch appState.appAppearance {
        case "system": appState.appAppearance = "light"
        case "light":  appState.appAppearance = "dark"
        case "dark":   appState.appAppearance = "system"
        default:       appState.appAppearance = "system"
        }
        applyAppearance()
    }

    private func applyAppearance() {
        switch appState.appAppearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil  // follow system
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
//                            Text(entry.mode)
//                                .font(.system(size: 9))
//                                .padding(.horizontal, 4)
//                                .padding(.vertical, 1)
//                                .background(Color.accentColor.opacity(0.1))
//                                .cornerRadius(3)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.transcribedText = entry.rawText
                        appState.refinedText = entry.refinedText ?? ""
                        appState.showingRefined = entry.refinedText != nil
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

    private var hasContent: Bool {
        !appState.transcribedText.isEmpty || !appState.refinedText.isEmpty
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
                guard !Task.isCancelled else { return }
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
        refineText(with: .cleanup)
    }

    private func refineText(with mode: RefinementMode) {
        guard !appState.transcribedText.isEmpty else { return }

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
            do {
                let refined = try await AIService.shared.refine(
                    text: appState.transcribedText,
                    systemPrompt: prompt,
                    provider: appState.aiProvider,
                    apiKey: apiKey,
                    model: appState.aiModel
                )

                guard !Task.isCancelled else { return }

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
                guard !Task.isCancelled else { return }
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
        let success = NSPasteboard.general.setString(currentText, forType: .string)
        if success {
            withAnimation { showCopiedToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showCopiedToast = false }
            }
        } else {
            showErrorAlert("Failed to copy to clipboard.")
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

    // MARK: - Refine Button (with mode picker)

    private var refineButton: some View {
        let disabled = appState.transcribedText.isEmpty || appState.isRefining || appState.isRecording

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

            // Mode picker chevron — each option triggers refinement directly
            Menu {
                ForEach(RefinementMode.allCases) { mode in
                    Button {
                        refineText(with: mode)
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
            } label: {
                Color.clear.frame(width: 1, height: 1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 16)
        }
        .foregroundColor(disabled ? .secondary : .white)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(disabled ? Color.accentColor.opacity(0.3) : Color.accentColor)
        )
        .help(appState.refinementMode.rawValue)
        .allowsHitTesting(!disabled)
        .opacity(disabled ? 0.6 : 1.0)
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
        TextEditor(text: text)
            .font(.system(size: CGFloat(appState.fontSize), weight: .regular, design: .default))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Event Monitors

    private func installSpaceKeyMonitor() {
        removeSpaceKeyMonitor()
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept bare keys (no modifiers like Cmd, Opt, Ctrl)
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] else {
                return event
            }

            // If the first responder is a text view, let keys type normally
            if let responder = event.window?.firstResponder,
               responder is NSTextView {
                return event
            }

            guard !appState.isTranscribing else { return event }

            // Space key: record/stop
            if event.keyCode == 49 {
                if appState.isRecording {
                    // Stop any active recording (regular or append)
                    if isAppendMode {
                        toggleAppendRecording()
                    } else {
                        toggleRecording()
                    }
                } else {
                    toggleRecording()
                }
                return nil
            }

            // A key: append/stop (only when content exists)
            if event.keyCode == 0 && hasContent {
                if appState.isRecording {
                    // Stop any active recording
                    if isAppendMode {
                        toggleAppendRecording()
                    } else {
                        toggleRecording()
                    }
                } else {
                    toggleAppendRecording()
                }
                return nil
            }

            // R key: refine
            if event.keyCode == 15 && !appState.isRecording && !appState.isRefining && !appState.transcribedText.isEmpty {
                refineText()
                return nil
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
            guard let window = event.window,
                  let firstResponder = window.firstResponder,
                  firstResponder is NSTextView else {
                return event
            }

            // Check if the click landed inside the text view; if not, resign focus
            guard let textView = firstResponder as? NSTextView else { return event }
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
