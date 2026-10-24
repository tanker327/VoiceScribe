# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceScribe is a **macOS SwiftUI app** for speech-to-text transcription with AI-powered text refinement. It records audio, sends it to an STT backend (or streams it live to Deepgram while recording), then optionally refines the transcript using an LLM (Claude, OpenAI, xAI, or any OpenAI-compatible endpoint such as a self-hosted model server).

- **Platform**: macOS 14.0+ (Sonoma). One main `Window` scene plus a `Settings` scene.
- **Toolchain**: Swift / SwiftUI. The project enables `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY`, so build with **Xcode 26 or newer** (the README's "Xcode 15+" is stale).
- **Bundle ID**: `com.voicescribe.app.VoiceScribe`. Keychain service name: `com.voicescribe`.
- **No SPM dependencies** — all networking is raw `URLSession` / `URLRequest`. No linter or formatter is configured.

## Build & Run

Open `VoiceScribe.xcodeproj` in Xcode and press ⌘R. The `VoiceScribe` scheme is not shared (it lives in gitignored `xcuserdata/`), so on a fresh clone open the project in Xcode once before using `xcodebuild`.

```bash
# Build from terminal
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -configuration Debug build

# Run tests
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe test

# Run one unit test suite / one UI test class
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -destination 'platform=macOS' -only-testing:VoiceScribeTests/AIServiceParsingTests test
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -destination 'platform=macOS' -only-testing:VoiceScribeUITests/VoiceScribeUITests test
```

Unit tests use Swift Testing (`import Testing` / `@Test`) and run inside the app process. They cover the AI response parsers, the temperature rule, the endpoint URL joining and auth headers, the configuration checks that fail before any request, `AppState`'s per-provider resolution (those tests restore the settings they touch, because they share the app's UserDefaults, and never set an API key: the Keychain is the user's real one, so key logic is tested through static seams like `AppState.isConfigured(_:deepgramKey:)`), and the audio downsampler and PCM16 conversion, and Deepgram's URL building, message parsing, transcript accumulation and error mapping through `nonisolated static` seams on the services (no network or microphone needed). `ContentView`'s STT badge message is a static seam too (`ContentView.sttProblem`). `TranscriptEditor` is tested in-process too: hosted in an `NSHostingView` inside an unshown window, so the double-click, typing, focus-loss and update paths run without the UI test runner. UI tests use XCTest and drive the real main window through XCUITest; they deliberately never record or call a provider API, because that would need microphone permission and would spend the user's API keys. Keep new UI tests to that rule. (The one test that clicks the Local Whisper badge only repeats the free `/health` GET the app sends at launch; the Deepgram badge is never clicked.) The stock `VoiceScribeUITestsLaunchTests` is flaky on this machine and unrelated to the app.

## Architecture

Single-state + services. No MVVM or coordinator layers. `AppState` is the only shared model, and `ContentView` implements every user action.

### Data flow

```
User taps Record → AudioRecorderService (AVAudioEngine → 16kHz mono 16-bit PCM WAV in temp dir)
    → LocalWhisperService.transcribe() (multipart POST to the local Whisper server)
      or, for Deepgram, DeepgramStream (PCM16 chunks over a WebSocket while recording; finish() after Stop)
    → AppState.transcribedText  (+ a new TranscriptionEntry is added to history immediately)
    → AIService.refine() (Claude, OpenAI, xAI, or an OpenAI-compatible endpoint)
    → AppState.refinedText → shown in editor / copied to clipboard  (history entry updated in place)
```

### Key files

- **`App/VoiceScribeApp.swift`** — Entry point. Main window defaults to 440×620 (min 400×520); Settings window is fixed at 520×480. Injects `AppState` as `@EnvironmentObject`.
- **`Models/AppState.swift`** — Single `@MainActor ObservableObject` holding all settings and runtime state. Also defines `AppAppearance`, `STTProvider`, `DeepgramLanguageMode`, `AIProvider`, `RefinementMode` (each mode carries its own `systemPrompt`) and the `TranscriptionEntry` history model.
- **`Services/AudioRecorderService.swift`** — `AVAudioEngine` recorder, an `ObservableObject` owned as a `@StateObject` by `ContentView`. Installs an input tap, downsamples with `AVAudioConverter`, writes to a temp WAV on a serial `DispatchQueue`. Publishes `inputDeviceName` from a CoreAudio default-input-device listener. The smoothed RMS level lives in the nested `LevelMeter` observable so per-buffer updates re-render only `AudioLevelBar`, not the whole `ContentView`. The tap hands each buffer to the static `downsample`, which feeds the converter exactly once per buffer, and `rms`. `startRecording(onPCM16Chunk:)` also delivers each buffer as PCM16 (`pcm16Data`) on the main queue for a streaming provider; the WAV is written either way.
- **`Services/DeepgramStream.swift`** — One object per Deepgram recording, owned by `ContentView` as `@State`. Opens `wss://api.deepgram.com/v1/listen` (`Authorization: Token`), buffers chunks until the socket opens, sends `KeepAlive` on open and every 8 s, and accumulates results in `TranscriptAccumulator` (finals appended, interim replaced, no space between CJK characters). `finish(fallbackFile:)` yields one main-queue turn so queued chunks go out, sends `CloseStream`, and resolves on `Metadata`, the socket closing, 1.5 s without a message or a 5 s cap, then promotes the interim. If the stream failed for any reason but a 4xx rejection, it uploads the WAV to the pre-recorded `POST /v1/listen` instead. A 4xx handshake (`dg-error` header holds the reason) calls `onRejected`, which aborts the recording. `testConnection` streams 1 s of silence for Settings.
- **`Services/KeychainHelper.swift`** — Static Keychain CRUD (Security framework). Saving an empty value deletes the item.
- **`Services/LocalWhisperService.swift`** — Singleton for Local Whisper. Multipart/form-data POST with file field `"video"`, `model`, `language` (also sent as a query item, which is where Whisperapy reads it) and `response_format`; no auth header. Parses `{ "text": ... }` and falls back to treating the body as plain text. Also the launch health check and Settings' silent-WAV connection test.
- **`Services/AIService.swift`** — Singleton. Claude uses the Messages API (`x-api-key`, `anthropic-version: 2023-06-01`, top-level `system`); the static `parseClaudeResponse` takes the first `text` content block and turns `refusal` and `max_tokens` stop reasons into errors; `parseChatCompletionResponse` does the same for a `length` finish reason. OpenAI, xAI and the OpenAI-compatible endpoint share one Chat Completions path (Bearer token, omitted when the compatible endpoint has no key; `temperature: 0.3` except for reasoning models, which reject it). Every request URL comes from the static `endpointURL(base:path:providerName:)`, which joins a base URL that already includes `/v1` (the provider's built-in one, or the user's Base URL for the compatible endpoint; trailing slashes dropped, `http(s)` with a host required) with `messages`, `chat/completions` or `models`. `fetchModels()` filters OpenAI results to `gpt-`/`o1`/`o3`/`o4` prefixes. A missing key (built-in providers only), Base URL or model is reported as a configuration error before any request.
- **`Views/ContentView.swift`** — Main UI: `HSplitView` with the main panel (optional custom-prompt bar, editor, status bar, action bar) and an optional 240pt history sidebar. Owns the record/append/abort/transcribe/refine/copy/clear actions, the editor's edit-mode flag (`isEditingText`, see below) and the `NSEvent` monitors. The `canStartRecording` and `canRefine` predicates gate the buttons and the bare keys alike. The STT badge in the status bar is a plain button: a click re-checks the selected provider (ignored while recording, transcribing or refining).
- **`Views/TranscriptEditor.swift`** — The editor, an `NSViewRepresentable` around a `TranscriptTextView` (`NSTextView` subclass) rather than SwiftUI's `TextEditor`, so the text can be read-only yet still selectable, scrollable and copyable. Plain text only, own `UndoManager` (dropped on programmatic text replacement), 12pt inset and 4pt line spacing. `dimmedSuffixLength` (UTF-16) draws a live interim tail in `secondaryLabelColor`, and text that changes while disabled (recording) scrolls to the end. The subclass reports a double-click while read-only (edit mode begins, caret placed at the click) and loss of first responder (edit mode ends).
- **`Views/SettingsView.swift`** — Three tabs: API Keys, Transcription, AI & General. Caches fetched model lists per provider in `@State`; changing the provider resets `aiModel` to that provider's default. The OpenAI-compatible provider adds an "OpenAI-compatible Endpoint" section to AI & General (Base URL, optional key, free-text model with Load Models as a helper menu); its model is `customAIModel`, not `aiModel`, and its cached model list is dropped when the Base URL changes. The Transcription tab switches on the STT provider: Local Whisper's endpoint fields and Language field, or Deepgram's language mode, keyterms and live-transcript toggle, each with a Test Connection row (shared helper `connectionTestRow`).

### Concurrency model

- The whole module defaults to `@MainActor` isolation via the build setting. Services are plain classes and are therefore MainActor-isolated; `await URLSession.shared.data(for:)` suspends without blocking the UI.
- Anything that runs off the main actor must be `nonisolated`. `KeychainHelper.save` is, because `AppState` calls it from a debounced `DispatchWorkItem` on a global queue. The audio tap callback hops to `audioFileQueue` for file writes and to `DispatchQueue.main` to update published properties and hand PCM16 chunks to a streaming provider.
- `NSObject` subclasses do not get the default isolation, so `DeepgramStream` is explicitly `@MainActor`; its `URLSession` delivers delegate calls on `OperationQueue.main`, and the `nonisolated` delegate method uses `MainActor.assumeIsolated`.
- `ContentView` keeps its async work in `@State` tasks (`transcriptionTask`, `refinementTask`, `toastTask`). Cancel the previous task before starting a new one, check `Task.isCancelled` after each `await`, and cancel all of them in `onDisappear`. Each task resets its in-flight flag in a `defer`, so cancellation (window closed, Clear pressed) never leaves the UI stuck.

### Persistence

- Settings are `@Published` properties on `AppState` with `didSet` observers that write to `UserDefaults` (not `@AppStorage`). `init()` restores them with `_prop = Published(wrappedValue:)` so `didSet` does not fire. Follow this pattern for any new setting.
- API keys are `@Published` too but persist to Keychain with a 0.5 s debounce. A one-time migration moves keys from UserDefaults to Keychain, guarded by the `keychainMigrationDone` flag. The OpenAI-compatible endpoint's `customAIAPIKey` is one of them and may legitimately stay empty; its `customAIBaseURL` and `customAIModel` are ordinary UserDefaults settings. `deepgramAPIKey` is a Keychain key too; `deepgramLanguageMode`, `deepgramKeyterms` and `deepgramLiveTranscript` are UserDefaults settings.
- Enum raw values (`"local_whisper"`, `"claude"`, `"cleanup"`, …) are stable persisted identifiers. `AppState.migrateEnumValues` maps the older display-string values, and the removed OpenAI STT providers (`openai_whisper`, `gpt4o_transcribe`) to `local_whisper`; if you rename or remove a raw value, add a mapping there.
- History is in-memory only (`@Published var history`), capped at 50, newest first, not persisted across launches. `ContentView` tracks the current entry via `currentHistoryEntryID` (set on transcription and when a sidebar entry is loaded) and updates it in place when refinement finishes or an append recording lands. The sidebar is disabled while a result is in flight.

### UI state machine (ContentView)

- The action bar has three phases: initial (Record only), recording (Abort + Stop, editor read-only), and has-content (Clear, Copy, Refine split button, Append, Record).
- **Edit mode**: the editor is read-only until double-clicked. Edit mode (`isEditingText`, shown as an accent border and "Editing · Esc to finish" in the status bar) ends on Escape, on a click outside the editor, and whenever Record, Append, Refine or Clear run (`endEditing()`), so the bare keys work right after. Read-only text can still be selected and copied with ⌘C. Recording keeps the editor read-only and ignores double-clicks.
- **Append mode** keeps `transcribedText` and appends `"\n" + newText`; a normal Record clears it first. **Abort** cancels in-flight tasks and restores `textBeforeRecording`. **Clear** cancels any in-flight transcription or refinement.
- The Refine split button's menu triggers refinement with the chosen mode; the plain button, ⌥E, the `R` key and auto-refine use the mode from Settings (`appState.refinementMode`). Custom mode shows a prompt bar above the editor, and an empty custom prompt falls back to "Clean up this transcription."
- Auto-copy on transcribe is skipped when auto-refine is on, because the refined text is copied instead.
- **Live transcript** (Deepgram, `deepgramLiveTranscript` on): results fill `transcribedText` while recording (after `textBeforeRecording` in append mode), the interim tail dimmed via `liveDimmedLength`. The final text is built from `textBeforeRecording`, not the live `transcribedText`. While a live transcript finalizes the status says "Finalizing…" and the loading overlay is hidden.

### Event monitors

Bare-key shortcuts (key codes Space=49, A=0, R=15) and Escape (53) are handled by one `NSEvent` local `keyDown` monitor installed in `onAppear` and removed in `onDisappear` and on `willTerminateNotification`. It acts only on the main window (resolved through `WindowAccessor`) and passes the event through when any modifier is held, when the first responder is an *editable* `NSTextView` (the editor in edit mode, or the custom prompt field), or when the action's predicate is false. The read-only editor also becomes first responder on a single click, which is why the check is `isEditable` and not the class. Escape while the editor is in edit mode calls `endEditing()` and is swallowed, except while an input method has marked text (then it cancels the composition). A separate `leftMouseDown` monitor resigns the editor's first-responder status when the click lands outside the text view, which ends edit mode so bare keys work again.

## STT Providers

Two backends via `STTProvider` (the OpenAI Whisper and GPT-4o Transcribe providers were removed on 2026-10-24; the OpenAI key is now used only for refinement):
1. **Local Whisper** (`local_whisper`) — **default provider**. A multipart upload to a self-hosted server. Host, port, path and model are separate settings (defaults `100.91.237.44`, `8000`, `/api/transcribe`, `whisper-large-v3`). The default is the Whisperapy server on power-linux-4090, reached over Tailscale: field `video`, `language` as a query parameter, `model` ignored. Only Whisperapy is supported; servers that expect the OpenAI-style field `file` (whisper.cpp, faster-whisper-server, LocalAI) are not. No auth header is sent. Installs on one of the server's LAN addresses (`192.168.10.110`, the old default, or `192.168.10.7`) are moved to the Tailscale IP at launch (`AppState.migratedLocalWhisperHost`); any other host is kept.
2. **Deepgram Nova-3** (`deepgram`) — streams while recording (`ContentView` creates a `DeepgramStream` when it is selected). `DeepgramLanguageMode`: mixed Chinese + English (default, `language=multi&language_hint=zh&language_hint=en`; Nova-3 multi covers Mandarin since 2026-10-23), English (`en`) or Chinese (`zh`). Always `smart_format=true`; the stream adds `encoding=linear16&sample_rate=16000&channels=1&interim_results=true&endpointing=300`. Keyterms (comma- or newline-separated, 500 tokens total) are repeated `keyterm` items, with `+` encoded as `%2B`. The STT badge turns red when its key is missing.

At launch, when Local Whisper is selected, `ContentView` GETs `http://<host>:<port>/health` (5s timeout). A failure sets `AppState.localWhisperHealthError`, which turns the STT badge red with the error as its tooltip. Settings' **Test Connection** (sends 1s of silence) sets or clears the same error, and editing the endpoint clears it. **Clicking the STT badge** re-checks the selected provider (`runConnectionCheck`): the same `/health` GET for Local Whisper, or `DeepgramStream.testConnection` for Deepgram, which sets or clears `AppState.deepgramConnectionError`, as Deepgram's Test Connection does; editing the Deepgram key, language or keyterms clears it. Deepgram is never checked automatically, because each check streams 1s of audio and uses a little quota. A missing Deepgram key outranks a failed check on the badge. The status text reports the outcome ("… connected ✓" / "… check failed").

`sttLanguage` (ISO 639-1, default `en`) is Local Whisper's language, sent as a form field and a query item. Deepgram uses `deepgramLanguageMode` instead.

## AI Providers

Four backends via `AIProvider`. `AIProvider.baseURL` includes the `/v1` prefix; `AppState.currentAIBaseURL` and `currentAIModel` resolve the base URL and model for whichever provider is selected.
1. **Claude** — Anthropic Messages API, default model `claude-sonnet-4-20250514`
2. **OpenAI** — Chat Completions API, default model `gpt-4o`
3. **xAI (Grok)** — OpenAI-compatible Chat Completions at `api.x.ai`, default model `grok-3-mini`
4. **OpenAI-compatible** (`openai_compatible`) — any Chat Completions server (an AI hub, vLLM, llama.cpp, Ollama, LiteLLM). Base URL (`customAIBaseURL`, must include the version prefix, e.g. `http://192.168.10.7:8080/v1`), optional key (`customAIAPIKey`) and free-text model (`customAIModel`) are settings; there is no default model. `requiresAPIKey` is false only for this provider.

`RefinementMode` has nine modes. `.translate` is bidirectional EN ↔ Simplified Chinese (it detects the input language), not English-only as the README implies.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Double-click editor | Enter edit mode (the editor is read-only otherwise) |
| Esc | Leave edit mode |
| Space | Start / Stop recording (bare key, when not in edit mode) |
| A | Append recording / Stop (bare key, when not in edit mode and content exists) |
| R | Refine transcription (bare key, when not in edit mode) |
| ⌥R | Start / Stop recording |
| ⌥A | Toggle append recording |
| ⌥E | Refine transcription |
| ⌥C | Copy current text |
| ⌘⌫ | Clear editor |

## Conventions

- **No Codable for API responses** — `LocalWhisperService` and `AIService` parse JSON manually via `JSONSerialization`. Keep this consistent unless refactoring.
- **Singletons for services** — `LocalWhisperService.shared` and `AIService.shared`. `AudioRecorderService` is a `@StateObject` in `ContentView`. The exception is `DeepgramStream`: one instance per recording (its state belongs to that recording), held in `ContentView`'s `deepgramStream` `@State`.
- **Errors** are nested `LocalizedError` enums per service (`STTError`, `AIError`, `RecorderError`, `DeepgramError`); `ContentView` surfaces `localizedDescription` in an alert.
- **Logging** — `print()` with prefixes: `[STT]`, `[Deepgram]`, `[AIService]`, `[Recorder]`, `[Keychain]`, `[History]`, `[Migration]`.
- **Entitlements**: App Sandbox, Audio Input, Outgoing Network (client), User-selected file read-write. `Info.plist` carries `NSMicrophoneUsageDescription`.
