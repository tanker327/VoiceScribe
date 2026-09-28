# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceScribe is a **macOS SwiftUI app** for speech-to-text transcription with AI-powered text refinement. It records audio, sends it to an STT backend, then optionally refines the transcript using an LLM (Claude, OpenAI, or xAI).

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

Unit tests use Swift Testing (`import Testing` / `@Test`) and run inside the app process. They cover the AI response parsers, the temperature rule, and the audio downsampler through `nonisolated static` seams on the services (no network or microphone needed). UI tests use XCTest and drive the real main window through XCUITest; they deliberately never record or call a provider API, because that would need microphone permission and would spend the user's API keys. Keep new UI tests to that rule. The stock `VoiceScribeUITestsLaunchTests` is flaky on this machine and unrelated to the app.

## Architecture

Single-state + services. No MVVM or coordinator layers. `AppState` is the only shared model, and `ContentView` implements every user action.

### Data flow

```
User taps Record → AudioRecorderService (AVAudioEngine → 16kHz mono 16-bit PCM WAV in temp dir)
    → STTService.transcribe() (multipart POST to OpenAI or local Whisper)
    → AppState.transcribedText  (+ a new TranscriptionEntry is added to history immediately)
    → AIService.refine() (Claude, OpenAI, or xAI API)
    → AppState.refinedText → shown in editor / copied to clipboard  (history entry updated in place)
```

### Key files

- **`App/VoiceScribeApp.swift`** — Entry point. Main window defaults to 440×620 (min 400×520); Settings window is fixed at 520×480. Injects `AppState` as `@EnvironmentObject`.
- **`Models/AppState.swift`** — Single `@MainActor ObservableObject` holding all settings and runtime state. Also defines `AppAppearance`, `STTProvider`, `AIProvider`, `RefinementMode` (each mode carries its own `systemPrompt`) and the `TranscriptionEntry` history model.
- **`Services/AudioRecorderService.swift`** — `AVAudioEngine` recorder, an `ObservableObject` owned as a `@StateObject` by `ContentView`. Installs an input tap, downsamples with `AVAudioConverter`, writes to a temp WAV on a serial `DispatchQueue`. Publishes `inputDeviceName` from a CoreAudio default-input-device listener. The smoothed RMS level lives in the nested `LevelMeter` observable so per-buffer updates re-render only `AudioLevelBar`, not the whole `ContentView`. The tap hands each buffer to the static `downsample`, which feeds the converter exactly once per buffer, and `rms`.
- **`Services/KeychainHelper.swift`** — Static Keychain CRUD (Security framework). Saving an empty value deletes the item.
- **`Services/STTService.swift`** — Singleton. Multipart/form-data POST. File field is `"file"` for OpenAI and `"video"` for the local endpoint. Parses `{ "text": ... }` and falls back to treating the body as plain text.
- **`Services/AIService.swift`** — Singleton. Claude uses the Messages API (`x-api-key`, `anthropic-version: 2023-06-01`, top-level `system`); the static `parseClaudeResponse` takes the first `text` content block and turns `refusal` and `max_tokens` stop reasons into errors; `parseChatCompletionResponse` does the same for a `length` finish reason. OpenAI and xAI share one Chat Completions path (Bearer token, `temperature: 0.3` except for reasoning models, which reject it). `fetchModels()` calls `/v1/models` and filters OpenAI results to `gpt-`/`o1`/`o3`/`o4` prefixes.
- **`Views/ContentView.swift`** — Main UI: `HSplitView` with the main panel (optional custom-prompt bar, editor, status bar, action bar) and an optional 240pt history sidebar. Owns the record/append/abort/transcribe/refine/copy/clear actions and the `NSEvent` monitors. The `canStartRecording` and `canRefine` predicates gate the buttons and the bare keys alike.
- **`Views/SettingsView.swift`** — Three tabs: API Keys, Transcription, AI & General. Caches fetched model lists per provider in `@State`; changing the provider resets `aiModel` to that provider's default.

### Concurrency model

- The whole module defaults to `@MainActor` isolation via the build setting. Services are plain classes and are therefore MainActor-isolated; `await URLSession.shared.data(for:)` suspends without blocking the UI.
- Anything that runs off the main actor must be `nonisolated`. `KeychainHelper.save` is, because `AppState` calls it from a debounced `DispatchWorkItem` on a global queue. The audio tap callback hops to `audioFileQueue` for file writes and to `DispatchQueue.main` to update published properties.
- `ContentView` keeps its async work in `@State` tasks (`transcriptionTask`, `refinementTask`, `toastTask`). Cancel the previous task before starting a new one, check `Task.isCancelled` after each `await`, and cancel all of them in `onDisappear`. Each task resets its in-flight flag in a `defer`, so cancellation (window closed, Clear pressed) never leaves the UI stuck.

### Persistence

- Settings are `@Published` properties on `AppState` with `didSet` observers that write to `UserDefaults` (not `@AppStorage`). `init()` restores them with `_prop = Published(wrappedValue:)` so `didSet` does not fire. Follow this pattern for any new setting.
- API keys are `@Published` too but persist to Keychain with a 0.5 s debounce. A one-time migration moves keys from UserDefaults to Keychain, guarded by the `keychainMigrationDone` flag.
- Enum raw values (`"gpt4o_transcribe"`, `"claude"`, `"cleanup"`, …) are stable persisted identifiers. `AppState.migrateEnumValues` maps the older display-string values; if you rename a raw value, add a mapping there.
- History is in-memory only (`@Published var history`), capped at 50, newest first, not persisted across launches. `ContentView` tracks the current entry via `currentHistoryEntryID` (set on transcription and when a sidebar entry is loaded) and updates it in place when refinement finishes or an append recording lands. The sidebar is disabled while a result is in flight.

### UI state machine (ContentView)

- The action bar has three phases: initial (Record only), recording (Abort + Stop, editor disabled), and has-content (Clear, Copy, Refine split button, Append, Record).
- **Append mode** keeps `transcribedText` and appends `"\n" + newText`; a normal Record clears it first. **Abort** cancels in-flight tasks and restores `textBeforeRecording`. **Clear** cancels any in-flight transcription or refinement.
- The Refine split button's menu triggers refinement with the chosen mode; the plain button, ⌥E, the `R` key and auto-refine use the mode from Settings (`appState.refinementMode`). Custom mode shows a prompt bar above the editor, and an empty custom prompt falls back to "Clean up this transcription."
- Auto-copy on transcribe is skipped when auto-refine is on, because the refined text is copied instead.

### Event monitors

Bare-key shortcuts (key codes Space=49, A=0, R=15) are `NSEvent` local `keyDown` monitors installed in `onAppear` and removed in `onDisappear` and on `willTerminateNotification`. They act only on the main window (resolved through `WindowAccessor`) and pass the event through when any modifier is held, when the first responder is an `NSTextView`, or when the action's predicate is false. A separate `leftMouseDown` monitor resigns the editor's first-responder status when the click lands outside the text view so bare keys work again.

## STT Providers

Three backends via `STTProvider`:
1. **GPT-4o Transcribe** (`gpt-4o-transcribe`) — default, requires OpenAI API key
2. **OpenAI Whisper** (`whisper-1`) — requires OpenAI API key
3. **Local Whisper** — a multipart upload to a self-hosted server. Host, port, path and model are separate settings (defaults `192.168.10.7`, `8000`, `/api/transcribe`, `whisper-large-v3`). The default is the Whisperapy server on power-linux-4090: field `video`, `language` as a query parameter, `model` ignored. No auth header is sent. Installs still on the previous default host (`192.168.10.110`) are migrated to the new one at launch.

`sttLanguage` (ISO 639-1, default `en`) is sent to every provider: as a form field for OpenAI, and additionally as a query item for the local endpoint.

## AI Providers

Three backends via `AIProvider`:
1. **Claude** — Anthropic Messages API, default model `claude-sonnet-4-20250514`
2. **OpenAI** — Chat Completions API, default model `gpt-4o`
3. **xAI (Grok)** — OpenAI-compatible Chat Completions at `api.x.ai`, default model `grok-3-mini`

`RefinementMode` has nine modes. `.translate` is bidirectional EN ↔ Simplified Chinese (it detects the input language), not English-only as the README implies.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Start / Stop recording (bare key, when editor not focused) |
| A | Append recording / Stop (bare key, when editor not focused and content exists) |
| R | Refine transcription (bare key, when editor not focused) |
| ⌥R | Start / Stop recording |
| ⌥A | Toggle append recording |
| ⌥E | Refine transcription |
| ⌥C | Copy current text |
| ⌘⌫ | Clear editor |

## Conventions

- **No Codable for API responses** — `STTService` and `AIService` parse JSON manually via `JSONSerialization`. Keep this consistent unless refactoring.
- **Singletons for services** — `STTService.shared` and `AIService.shared`. `AudioRecorderService` is a `@StateObject` in `ContentView`.
- **Errors** are nested `LocalizedError` enums per service (`STTError`, `AIError`, `RecorderError`); `ContentView` surfaces `localizedDescription` in an alert.
- **Logging** — `print()` with prefixes: `[STT]`, `[AIService]`, `[Recorder]`, `[Keychain]`, `[History]`, `[Migration]`.
- **Entitlements**: App Sandbox, Audio Input, Outgoing Network (client), User-selected file read-write. `Info.plist` carries `NSMicrophoneUsageDescription`.
