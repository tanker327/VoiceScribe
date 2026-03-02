# VoiceScribe

**Speech-to-text with AI refinement for macOS**

Record your voice, transcribe with best-in-class STT, refine with AI, copy to clipboard.

---

## Features

- **Three STT backends** — configurable in Settings:
  - **GPT-4o Transcribe** — best accuracy (default)
  - **OpenAI Whisper API** — fast, reliable
  - **Local Whisper** — self-hosted, private (whisper.cpp server, faster-whisper, LocalAI, etc.)
- **Three AI providers** — Claude (Anthropic), OpenAI, or xAI (Grok) for post-processing
- **Built-in text editor** — edit raw or refined text, with word/character count
- **One-click copy** to clipboard
- **9 refinement modes** — Clean Up, Formal, Casual, Bullets, Email, Summary, Technical, Translate, Custom
- **Keyboard shortcuts** — bare keys (Space, A, R) and Option-key combos for hands-free workflow
- **History sidebar** — recall and delete past transcriptions
- **Status bar** — shows active providers, input device, word/char count
- **Auto-refine** on stop, auto-copy on refine
- **Append mode** — add to existing transcription without clearing
- **Secure key storage** — API keys stored in macOS Keychain

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+
- At least one API key (OpenAI for STT, Claude/OpenAI/xAI for refinement)

## Build & Run

Open `VoiceScribe.xcodeproj` in Xcode 15+ and press **Cmd+R**.

```bash
# Build from terminal
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -configuration Debug build

# Run tests
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe test
```

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
│   ├── AIService.swift               # Claude, OpenAI & xAI chat completions
│   └── KeychainHelper.swift          # Secure API key storage via macOS Keychain
├── Views/
│   ├── ContentView.swift             # Main editor, controls, history sidebar
│   └── SettingsView.swift            # Tabbed settings (API Keys, Transcription, AI & General)
├── Info.plist                        # Microphone permission
└── VoiceScribe.entitlements          # Sandbox, audio, network
```

### Data flow

```
Record → AudioRecorderService (AVAudioEngine → 16kHz mono PCM WAV)
  → STTService.transcribe() (multipart POST to OpenAI or local Whisper)
  → AppState.transcribedText
  → AIService.refine() (Claude, OpenAI, or xAI)
  → AppState.refinedText → displayed in editor / copied to clipboard
```

## STT Provider Setup

### GPT-4o Transcribe (recommended)
- Get an API key from [OpenAI Platform](https://platform.openai.com/api-keys)
- Paste into **Settings > API Keys > OpenAI API Key**
- Select "GPT-4o Transcribe" as provider

### OpenAI Whisper
- Same API key as above
- Select "OpenAI Whisper" as provider

### Local Whisper
Run a Whisper server locally:

```bash
# whisper.cpp server
./server -m models/ggml-large-v3.bin --host 0.0.0.0 --port 8080

# faster-whisper-server (Docker)
docker run -d -p 8080:8000 fedirz/faster-whisper-server:latest

# LocalAI
docker run -p 8080:8080 localai/localai:latest
```

In Settings > Transcription: select "Local Whisper", set the endpoint URL (e.g., `http://localhost:8080/v1/audio/transcriptions`).

## AI Refinement Setup

### Claude (Anthropic)
- Get an API key from [Anthropic Console](https://console.anthropic.com/)
- Paste into **Settings > API Keys > Claude API Key**
- Default model: `claude-sonnet-4-20250514`

### OpenAI
- Uses the same API key from the STT setup
- Default model: `gpt-4o`

### xAI (Grok)
- Get an API key from [xAI Console](https://console.x.ai/)
- Paste into **Settings > API Keys > xAI API Key**
- Default model: `grok-3-mini`

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Start / Stop recording (when editor not focused) |
| A | Append recording / Stop (when editor not focused) |
| R | Refine transcription (when editor not focused) |
| Option+R | Start / Stop recording |
| Option+A | Toggle append recording |
| Option+E | Refine transcription |
| Option+C | Copy current text |
| Cmd+Delete | Clear editor |

## Refinement Modes

| Mode | Description |
|------|-------------|
| Clean Up | Fix grammar, remove fillers, natural flow |
| Formal | Professional tone, structured |
| Casual | Keep conversational feel, fix errors |
| Bullets | Convert to organized bullet points |
| Email | Format as email with greeting/sign-off |
| Summarize | Extract key points concisely |
| Technical | Precise language, proper terminology |
| Translate | Translate to English (or clean up if already) |
| Custom | Your own prompt |

## Audio Format

Records 16kHz, 16-bit mono PCM WAV — optimal for all Whisper variants and GPT-4o Transcribe.

## License

MIT
