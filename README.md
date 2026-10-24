# VoiceScribe

**Speech-to-text with AI refinement for macOS**

Record your voice, transcribe with best-in-class STT, refine with AI, copy to clipboard.

---

## Features

- **Two STT backends** — configurable in Settings:
  - **Local Whisper** — a self-hosted, private Whisperapy server (default)
  - **Deepgram Nova-3** — streams while you record, so the text is ready right after Stop; mixed Chinese + English, keyterms, optional live transcript
- **Four AI providers** — Claude (Anthropic), OpenAI, xAI (Grok), or any OpenAI-compatible endpoint (a self-hosted vLLM, llama.cpp, Ollama, LiteLLM or AI hub server) for post-processing
- **Built-in text editor** — double-click to edit raw or refined text, Esc to finish, with word/character count
- **One-click copy** to clipboard
- **9 refinement modes** — Clean Up, Formal, Casual, Bullets, Email, Summary, Technical, Translate, Custom
- **Keyboard shortcuts** — bare keys (Space, A, R) and Option-key combos for hands-free workflow
- **History sidebar** — recall and delete past transcriptions
- **Status bar** — shows active providers, input device, word/char count; click the STT badge to test its connection (it turns red, with the reason as its tooltip, when the provider cannot work)
- **Auto-refine** on stop, auto-copy on refine
- **Append mode** — add to existing transcription without clearing
- **Secure key storage** — API keys stored in macOS Keychain

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+
- For transcription, a local Whisper server or a Deepgram API key; for refinement, a Claude, OpenAI or xAI key, or an OpenAI-compatible endpoint (a local Whisper server plus a self-hosted endpoint is a fully self-hosted setup)

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
│   └── AppState.swift                # State, enums (STTProvider, DeepgramLanguageMode, AIProvider, RefinementMode)
├── Services/
│   ├── AudioRecorderService.swift    # AVAudioEngine → 16kHz WAV recording
│   ├── LocalWhisperService.swift     # Multipart upload to the local Whisper server
│   ├── DeepgramStream.swift          # Deepgram Nova-3 live WebSocket + pre-recorded fallback
│   ├── AIService.swift               # Claude, OpenAI, xAI & OpenAI-compatible endpoints
│   └── KeychainHelper.swift          # Secure API key storage via macOS Keychain
├── Views/
│   ├── ContentView.swift             # Main editor, controls, history sidebar
│   ├── TranscriptEditor.swift        # Read-only NSTextView editor, double-click to edit
│   └── SettingsView.swift            # Tabbed settings (API Keys, Transcription, AI & General)
├── Info.plist                        # Microphone permission
└── VoiceScribe.entitlements          # Sandbox, audio, network
```

### Data flow

```
Record → AudioRecorderService (AVAudioEngine → 16kHz mono PCM WAV)
  → LocalWhisperService.transcribe() (multipart POST to local Whisper)
    or DeepgramStream (audio streamed over a WebSocket while recording; final text right after Stop)
  → AppState.transcribedText
  → AIService.refine() (Claude, OpenAI, xAI, or an OpenAI-compatible endpoint)
  → AppState.refinedText → displayed in editor / copied to clipboard
```

## STT Provider Setup

### Local Whisper
- Expects a **Whisperapy** server: the audio is uploaded as the multipart field `video`, the language as a `language` query parameter, and the reply is `{"text": ...}` or plain text
- Servers that expect the OpenAI-style field `file` (whisper.cpp server, faster-whisper-server, LocalAI) are not supported
- In **Settings > Transcription**: select "Local Whisper", set the host, port, path and model (the defaults point at the Whisperapy server over Tailscale, `http://100.91.237.44:8000/api/transcribe`), and press **Test Connection**
- At launch the app checks `http://<host>:<port>/health`; installs still on one of the server's LAN addresses (`192.168.10.110`, `192.168.10.7`) are moved to the Tailscale IP

### Deepgram Nova-3
- Get an API key from the [Deepgram Console](https://console.deepgram.com/)
- Paste into **Settings > API Keys > Deepgram**
- In **Settings > Transcription**, select "Deepgram Nova-3", then pick the language (Chinese + English mixed, English, or Chinese), add keyterms for names and jargon, and press **Test Connection**
- With **Show live transcript** on, the text fills in while you speak; words still being recognized are dimmed
- If the connection drops mid-recording, the recording is uploaded to Deepgram after Stop instead, so nothing is lost

## AI Refinement Setup

### Claude (Anthropic)
- Get an API key from [Anthropic Console](https://console.anthropic.com/)
- Paste into **Settings > API Keys > Claude API Key**
- Default model: `claude-sonnet-4-20250514`

### OpenAI
- Get an API key from [OpenAI Platform](https://platform.openai.com/api-keys)
- Paste into **Settings > API Keys > OpenAI**
- Default model: `gpt-4o`

### xAI (Grok)
- Get an API key from [xAI Console](https://console.x.ai/)
- Paste into **Settings > API Keys > xAI API Key**
- Default model: `grok-3-mini`

### OpenAI-compatible endpoint (self-hosted)
- Pick **OpenAI-compatible** under **Settings > AI & General > Provider**
- Enter the **Base URL** including the version prefix the server expects, e.g. `http://192.168.10.7:8080/v1`; the app appends `/chat/completions` and `/models`
- The **API Key** is optional; leave it empty if the server does not check one
- Type the **Model** id, or press **Load Models** and pick one from the server's `/models` list
- Works with anything that speaks the OpenAI Chat Completions API: an AI hub, vLLM, llama.cpp, Ollama, LiteLLM, LM Studio
- Plain `http://` works for IP addresses; a hostname over plain HTTP may be blocked by App Transport Security, so use an IP or `https://` there

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Double-click editor | Start editing the text (it is read-only otherwise) |
| Esc | Finish editing; the editor is read-only again |
| Space | Start / Stop recording (when not editing) |
| A | Append recording / Stop (when not editing) |
| R | Refine transcription (when not editing) |
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

Records 16kHz, 16-bit mono PCM WAV — optimal for Whisper. With Deepgram the same audio is also streamed live as raw 16-bit PCM (`linear16`); the WAV is kept as the upload fallback.

## License

MIT
