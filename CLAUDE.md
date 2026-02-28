# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceScribe is a **macOS SwiftUI app** for speech-to-text transcription with AI-powered text refinement. It records audio, sends it to an STT backend, then optionally refines the transcript using an LLM (Claude or OpenAI).

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
User taps Record → AudioRecorderService (AVAudioEngine → 16kHz WAV)
    → STTService.transcribe() (multipart POST to OpenAI or local Whisper)
    → AppState.transcribedText
    → AIService.refine() (Claude Messages API or OpenAI Chat Completions)
    → AppState.refinedText → displayed in editor / copied to clipboard
```

### Key files

- **`App/VoiceScribeApp.swift`** — Entry point. Creates the main window and Settings window. Injects `AppState` as `@EnvironmentObject`.
- **`Models/AppState.swift`** — Single `ObservableObject` holding all app state. Uses `@AppStorage` for persisted settings and `@Published` for runtime state. Also defines enums: `STTProvider`, `AIProvider`, `RefinementMode`, and the `TranscriptionEntry` history model.
- **`Services/AudioRecorderService.swift`** — `AVAudioEngine`-based recorder. Installs a tap on the input node, downsamples to 16kHz mono PCM via `AVAudioConverter`, writes to a temp WAV file. Publishes `audioLevel` for the UI meter.
- **`Services/STTService.swift`** — Singleton. Builds multipart/form-data requests for the OpenAI transcriptions API (or compatible local endpoint). Includes `Data` extension helpers for multipart encoding.
- **`Services/AIService.swift`** — Singleton. Handles both Claude (Anthropic Messages API with `x-api-key` header) and OpenAI (Chat Completions with Bearer token). Manual JSON serialization, no Codable models.
- **`Views/ContentView.swift`** — Main UI. Contains the status bar, controls bar, text editor (raw/refined toggle), action bar with Record/Refine/Copy/Clear buttons, history sidebar, and all action methods (`toggleRecording`, `stopAndTranscribe`, `refineText`, `copyToClipboard`).
- **`Views/SettingsView.swift`** — Three-tab settings: Transcription (STT provider, API key, local endpoint), AI Refinement (provider, model, mode), General (font size, automation toggles).

### Important patterns

- **No Codable for API responses** — Both `STTService` and `AIService` parse JSON manually via `JSONSerialization`. Keep this consistent unless refactoring.
- **Singletons for services** — `STTService.shared` and `AIService.shared`. `AudioRecorderService` is a `@StateObject` in `ContentView`.
- **All settings persisted via `@AppStorage`** — stored in UserDefaults. No custom persistence layer.
- **History is in-memory only** (`@Published var history`) — capped at 50 entries, not persisted across launches.
- **Entitlements required**: App Sandbox, Audio Input, Outgoing Network (client), User-selected file read-write.

## STT Providers

Three backends configured via `STTProvider` enum:
1. **GPT-4o Transcribe** (`gpt-4o-transcribe`) — default, requires OpenAI API key
2. **OpenAI Whisper** (`whisper-1`) — requires OpenAI API key
3. **Local Whisper** — any OpenAI-compatible endpoint (whisper.cpp, faster-whisper, LocalAI)

## AI Providers

Two backends via `AIProvider` enum:
1. **Claude** — Anthropic Messages API, default model `claude-sonnet-4-20250514`
2. **OpenAI** — Chat Completions API, default model `gpt-4o`
