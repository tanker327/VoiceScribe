# VoiceScribe

**Speech-to-text with AI refinement for macOS**

Record your voice → transcribe with best-in-class STT → refine with AI → copy to clipboard.

---

## Features

- 🎙️ **Three STT backends** — configurable in Settings:
  - **GPT-4o Transcribe** — best accuracy (default)
  - **OpenAI Whisper API** — fast, reliable
  - **Local Whisper** — self-hosted, private (whisper.cpp server, faster-whisper, LocalAI, etc.)
- 🧠 **AI Refinement** — Claude (Anthropic) or OpenAI for post-processing
- ✏️ **Built-in text editor** — edit raw or refined text
- 📋 **One-click copy** to clipboard
- 🔄 **8 refinement modes** — Clean Up, Formal, Casual, Bullets, Email, Summary, Technical, Translate, Custom
- ⌨️ **Keyboard shortcuts** — ⌥R record, ⌥E refine, ⌥C copy
- 📜 **History sidebar** — recall past transcriptions
- ⚙️ **Auto-refine** on stop, auto-copy on refine

## Architecture

```
VoiceScribe/
├── App/
│   └── VoiceScribeApp.swift          # Entry point, window config
├── Models/
│   └── AppState.swift                # State, enums (STTProvider, AIProvider, RefinementMode)
├── Services/
│   ├── AudioRecorderService.swift    # AVAudioEngine → 16kHz WAV recording
│   ├── STTService.swift              # Multipart upload to OpenAI / local Whisper
│   └── AIService.swift               # Claude & OpenAI chat completions
├── Views/
│   ├── ContentView.swift             # Main editor, controls, history
│   └── SettingsView.swift            # Tabbed settings (STT, AI, General)
├── Info.plist                        # Microphone permission
└── VoiceScribe.entitlements          # Sandbox, audio, network
```

## Setup in Xcode

1. **Create a new Xcode project**:
   - macOS → App
   - Interface: SwiftUI
   - Language: Swift
   - Product Name: `VoiceScribe`
   - Bundle ID: `com.voicescribe.app`

2. **Replace generated files** with the files from this project:
   - Delete the default `ContentView.swift` and `VoiceScribeApp.swift`
   - Drag all `.swift` files into the Xcode project navigator
   - Replace `Info.plist` and add the `.entitlements` file

3. **Configure signing & capabilities**:
   - Under **Signing & Capabilities**, add:
     - ✅ App Sandbox
     - ✅ Audio Input (under Hardware)
     - ✅ Outgoing Connections (Client) (under Network)

4. **Set deployment target** to macOS 14.0+

5. **Build and Run** (⌘R)

## STT Provider Setup

### GPT-4o Transcribe (recommended)
- Get an API key from [OpenAI Platform](https://platform.openai.com/api-keys)
- Paste into **Settings → Transcription → OpenAI API Key**
- Select "GPT-4o Transcribe" as provider

### OpenAI Whisper
- Same API key as above
- Select "OpenAI Whisper" as provider

### Local Whisper
- Run a Whisper server locally. Examples:

  **whisper.cpp server:**
  ```bash
  ./server -m models/ggml-large-v3.bin --host 0.0.0.0 --port 8080
  ```

  **faster-whisper-server (Docker):**
  ```bash
  docker run -d -p 8080:8000 fedirz/faster-whisper-server:latest
  ```

  **LocalAI:**
  ```bash
  docker run -p 8080:8080 localai/localai:latest
  ```

- In Settings → Transcription:
  - Select "Local Whisper"
  - Set endpoint URL (e.g., `http://localhost:8080/v1/audio/transcriptions`)
  - Set model name if required by your server

## AI Refinement Setup

### Claude (Anthropic)
- Get an API key from [Anthropic Console](https://console.anthropic.com/)
- Paste into **Settings → AI Refinement → Claude API Key**
- Default model: `claude-sonnet-4-20250514`

### OpenAI
- Uses the same API key from the STT tab
- Default model: `gpt-4o`

## Keyboard Shortcuts

| Shortcut | Action                  |
|----------|-------------------------|
| ⌥R       | Start / Stop recording  |
| ⌥E       | Refine with AI          |
| ⌥C       | Copy current text       |
| ⌘⌫       | Clear editor            |

## Audio Format

Records 16kHz, 16-bit mono PCM WAV — optimal for all Whisper variants and GPT-4o Transcribe.

## Refinement Modes

| Mode        | Description                                    |
|-------------|------------------------------------------------|
| Clean Up    | Fix grammar, remove fillers, natural flow      |
| Formal      | Professional tone, structured                  |
| Casual      | Keep conversational feel, fix errors           |
| Bullets     | Convert to organized bullet points             |
| Email       | Format as email with greeting/sign-off         |
| Summarize   | Extract key points concisely                   |
| Technical   | Precise language, proper terminology            |
| Translate   | Translate to English (or clean up if already)  |
| Custom      | Your own prompt                                 |

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+
- At least one API key (OpenAI for STT, Claude or OpenAI for refinement)

## License

MIT — use it however you like.
