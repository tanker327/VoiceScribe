# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceScribe is a **macOS SwiftUI app** for speech-to-text transcription with AI-powered text refinement. It records audio, sends it to an STT backend, then optionally refines the transcript using an LLM (Claude, OpenAI, or xAI).

- **Platform**: macOS 14.0+ (Sonoma)
- **Language**: Swift / SwiftUI
- **Bundle ID**: `com.voicescribe.app`
- **No SPM dependencies** — all networking is done via raw `URLSession` and `URLRequest`

## Build & Run

Open `VoiceScribe.xcodeproj` in Xcode 15+ and press ⌘R. There is no command-line build setup.

```bash
# Build from terminal
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -configuration Debug build

# Run tests
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe test

# Run a single test
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -only-testing:VoiceScribeTests/VoiceScribeTests/example test
```

Unit tests use Swift Testing (`import Testing` / `@Test`), UI tests use XCTest.

## Architecture

The app follows a simple **single-state + services** pattern. No MVVM or coordinator layers.

### Data flow

```
User taps Record → AudioRecorderService (AVAudioEngine → 16kHz mono PCM WAV)
    → STTService.transcribe() (multipart POST to OpenAI or local Whisper)
    → AppState.transcribedText
    → AIService.refine() (Claude, OpenAI, or xAI API)
    → AppState.refinedText → displayed in editor / copied to clipboard
```

### Key files

- **`App/VoiceScribeApp.swift`** — Entry point. Creates the main window and Settings window. Injects `AppState` as `@EnvironmentObject`.
- **`Models/AppState.swift`** — Single `@MainActor ObservableObject` holding all app state. Uses `@AppStorage` for persisted settings and `@Published` for runtime state. Defines enums: `STTProvider`, `AIProvider`, `RefinementMode`, and the `TranscriptionEntry` history model. Includes `hasAPIKey(for:)` helper to check provider key availability.
- **`Services/AudioRecorderService.swift`** — `AVAudioEngine`-based recorder. Installs a tap on the input node, downsamples to 16kHz mono PCM via `AVAudioConverter`, writes to a temp WAV file. Thread-safe file access with serial `DispatchQueue`.
- **`Services/KeychainHelper.swift`** — Enum with static methods for secure API key storage via macOS Keychain (Security framework). Stores keys under service `"com.voicescribe"`.
- **`Services/STTService.swift`** — Singleton. Builds multipart/form-data requests for the OpenAI transcriptions API (or compatible local endpoint). Uses different field names: `"video"` for local, `"file"` for OpenAI.
- **`Services/AIService.swift`** — Singleton. Handles Claude (Anthropic Messages API with `x-api-key` header), OpenAI (Chat Completions with Bearer token), and xAI (same format as OpenAI). Manual JSON serialization, no Codable models. Supports `fetchModels()` for dynamic model loading via `/v1/models`.
- **`Views/ContentView.swift`** — Main UI with HSplitView (main panel + history sidebar). Contains status bar (provider badges, input device, word/char count), controls bar, text editor (raw/refined toggle), action bar with audio level visualization, and toolbar. Installs `NSEvent` local monitors for bare keys (Space, A, R) when editor is not focused.
- **`Views/SettingsView.swift`** — Three-tab settings: API Keys (all provider keys), Transcription (STT provider, local endpoint, language), AI & General (AI provider/model/mode, editor, automation, shortcuts, about). Caches fetched models per provider.

### Important patterns

- **No Codable for API responses** — Both `STTService` and `AIService` parse JSON manually via `JSONSerialization`. Keep this consistent unless refactoring.
- **Singletons for services** — `STTService.shared` and `AIService.shared`. `AudioRecorderService` is a `@StateObject` in `ContentView`.
- **No custom persistence layer** — API keys stored in Keychain via `KeychainHelper` (auto-migrated from UserDefaults on first launch). All other settings use `@AppStorage`/UserDefaults.
- **History is in-memory only** (`@Published var history`) — capped at 50 entries, not persisted across launches. Individual entries can be deleted from the sidebar.
- **Logging** — Services use `print()` with prefixes: `[STT]`, `[AIService]`, `[History]`.
- **Entitlements required**: App Sandbox, Audio Input, Outgoing Network (client), User-selected file read-write.

## STT Providers

Three backends configured via `STTProvider` enum:
1. **GPT-4o Transcribe** (`gpt-4o-transcribe`) — default, requires OpenAI API key
2. **OpenAI Whisper** (`whisper-1`) — requires OpenAI API key
3. **Local Whisper** — any OpenAI-compatible endpoint (whisper.cpp, faster-whisper, LocalAI), configurable host/port/path

## AI Providers

Three backends via `AIProvider` enum:
1. **Claude** — Anthropic Messages API, default model `claude-sonnet-4-20250514`
2. **OpenAI** — Chat Completions API, default model `gpt-4o`
3. **xAI (Grok)** — OpenAI-compatible Chat Completions at `api.x.ai`, default model `grok-3-mini`

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

Bare keys (Space, A, R) are implemented via `NSEvent` local monitors and only activate when the text editor is not focused.
