# Plan: Deepgram Nova-3 streaming STT provider

Status: implemented 2026-10-24 (unit and UI tests pass); live smoke test and manual acceptance pending. Source spec: `claude-voice-dictation-deepgram-guide.md`.

## Goal

Add a fourth STT provider, **Deepgram Nova-3**, that streams audio while you record, so the text is
ready about 300 ms after Stop instead of after a full upload and transcription. Optionally the text
can also appear live in the editor while you speak.

## API facts checked against Deepgram's live docs and changelog (2026-10-24)

The Context7 index was older than the 2026-10-23 release. Each row below was confirmed on
developers.deepgram.com.

| Item | Current API | Impact on the guide |
|---|---|---|
| Endpoint | `wss://api.deepgram.com/v1/listen`, header `Authorization: Token <key>` | As in the guide |
| Raw PCM | `encoding=linear16&sample_rate=16000&channels=1` are required for raw audio | As in the guide |
| `interim_results`, `endpointing`, `smart_format` | Supported; `endpointing` defaults to 10 ms | Use `true` / `300` / `true` |
| `keyterm` | Nova-3 only, repeat the parameter per term, limit **500 tokens in total** (≈100 words) | The guide says "~50 terms"; the real limit is tokens |
| `language=multi` (Nova-3) | Since **2026-10-23**: code-switching across **55 languages, including Mandarin Simplified (`zh`)**. Before that it covered only 10 languages without Chinese | Mixed Chinese/English works in one stream, as the guide says |
| `language_hint` (Nova-3) | Since **2026-10-23**: repeatable (`language_hint=zh&language_hint=en`), streaming supported, applies only with `language=multi` (ignored otherwise). Hints bias detection without restricting it, and stay fixed for the connection. An unsupported code makes the handshake fail with 400 | Use as in the guide |
| Chinese, single language | Nova-3 `zh` / `zh-CN` / `zh-Hans`, `zh-TW` / `zh-Hant`, `zh-HK` (Cantonese) | Offered as the "Chinese only" mode |
| Code-switching endpointing | Deepgram recommends `endpointing=100` with `language=multi` | Start at 300 (the guide / Claude value) and compare with 100 |
| Response language fields | With `multi`: `alternatives[].languages`, `languages_hinted`, `words[].language` | Logged only; not used for display |
| Control messages | `{"type":"KeepAlive"}`, `{"type":"Finalize"}`, `{"type":"CloseStream"}` as text frames | As in the guide |
| After CloseStream | Server flushes the last `Results`, sends one `Metadata` message, then closes | `Metadata` is the "done" signal |
| Errors | Handshake rejection is an HTTP status (401 bad key, 400 bad parameter, with a `dg-error` header); in-stream errors are close frames (1008 `DATA-0000`, 1011 `NET-000x`) | Map them to clear messages |
| SDK | `@deepgram/sdk` is JavaScript; there is no official Swift SDK | Use `URLSessionWebSocketTask` (the project has no SPM dependencies) |

## Design

### Flow

```
Record ─┬─ AudioRecorderService (unchanged WAV writing)
        │     └─ new: each 16 kHz buffer → PCM16 LE Data → onPCM16Chunk (main queue)
        └─ DeepgramStream.connect()  (opens the socket in parallel with the mic)
              chunks are buffered in memory until the socket opens, then flushed in order
              KeepAlive on open, then every 8 s
              Results(is_final=false) → interim = transcript
              Results(is_final=true)  → committed += transcript; interim = ""
              onUpdate(committed + interim) → editor (live mode only)
Stop ── recorder.stopRecording() → yield one main-queue turn (queued chunks go out first)
        → CloseStream → wait for the first of:
              Metadata received | socket closed | 1.5 s with no message | 5 s cap
        → promote any interim to committed → close the socket → return text
        → the same post-transcription code as today (history, auto-copy, auto-refine)
        (stream failed, other than a 4xx → the recorded WAV goes to POST /v1/listen instead)
```

The mic starts at once, without waiting for the socket, so the first words aren't lost during the
roughly 300 ms handshake. Audio is still sent only after `open`, as the guide requires: chunks wait
in a buffer until then.

### Files

1. **`Models/AppState.swift`**
   - `STTProvider.deepgram = "deepgram"` (stable raw value). Display name "Deepgram Nova-3", model
     `nova-3`, endpoint `wss://api.deepgram.com/v1/listen`, new `isStreaming` (true only here).
     *Update 2026-10-24:* the OpenAI STT providers were removed, leaving Local Whisper and Deepgram,
     so `modelName`, `endpoint` and `isStreaming` went too: `ContentView` checks `== .deepgram`
     and `listenURL` holds `nova-3`.
   - `deepgramAPIKey`: Keychain with the 0.5 s debounce, the same pattern as the other keys.
   - `deepgramKeyterms: String` (UserDefaults; separated by commas, full-width commas or new
     lines) plus a computed list that is trimmed with empties dropped. Not capped in the app: an
     over-limit list makes Deepgram refuse the handshake with a 400, and its `dg-error` reason is shown.
   - `deepgramLiveTranscript: Bool = true` (UserDefaults): `live` vs `final-only` display mode.
   - `deepgramLanguageMode` (UserDefaults, guide 6.6), its own enum with stable raw values:
     **Mixed Chinese + English** (default: `language=multi&language_hint=zh&language_hint=en`),
     **English** (`language=en`), **Chinese** (`language=zh`). It is separate from `sttLanguage`
     because `multi` and the hints mean nothing to the other providers (now just Local Whisper).
2. **`Services/AudioRecorderService.swift`**
   - `startRecording(onPCM16Chunk:)`. When it is passed, the tap converts the 16 kHz Float32 buffer
     with a new `nonisolated static func pcm16Data(from:)` (clamped, little-endian) and hops to
     main, as the level meter does. A 4096-frame tap at 48 kHz gives ~85 ms, ~2.7 KB per chunk, which
     is within the guide's 20–100 ms.
   - WAV writing stays as it is, so the batch providers don't change.
3. **`Services/DeepgramStream.swift`** (new)
   - `DeepgramStream`: one object per recording, owned by `ContentView` as `@State`. A session
     object rather than a singleton, because all of its state belongs to one recording, and a late
     callback from an old socket can't reach a new one.
   - `nonisolated static func listenURL(streaming:languageMode:keyterms:)` (wss stream or https pre-recorded): model, `language` (+ repeated
     `language_hint` in mixed mode), encoding, sample rate, channels, `interim_results`,
     `endpointing=300`, `smart_format`, repeated `keyterm`.
   - `nonisolated static func parse(_ text: String) -> Event`: Results (interim or final),
     Metadata, Error, or ignored.
   - `TranscriptAccumulator` struct: committed and interim text, joined with a space except between
     CJK characters, and `finish()` promotes the interim.
   - Explicitly `@MainActor` (an `NSObject` subclass doesn't get the module's default isolation). A
     dedicated `URLSession` with its delegate on the main queue reports `didOpen`; the receive loop
     runs as an `async` loop on the main actor and reads close codes and the refused handshake's
     HTTP status from the task.
   - `DeepgramError` (`LocalizedError`): missing key, API error (401/403 worded as a rejected key,
     other codes with the `dg-error` or `err_msg` text), connection lost, stream error, invalid
     response, parse error. `isRejection` (any 4xx) decides between aborting and the REST fallback.
   - Logs use the `[Deepgram]` prefix: URL without the key, open, chunk count and bytes, every final
     segment, CloseStream, the path that resolved finalize, request_id from Metadata, and close code.
4. **`Views/ContentView.swift`**
   - `startRecording` / `startAppendRecording`: if the provider is streaming, check the key (fail
     before the mic starts), create the session, wire `onPCM16Chunk`, and route `onUpdate` into
     `transcribedText` (prefixed with `textBeforeRecording + "\n"` in append mode). If the
     handshake fails while recording, stop and restore the text, and show the error.
   - `stopAndTranscribe`: streaming providers `await session.finish()`. Both paths then call one
     shared `applyTranscription(_:)`, which builds the final text from `textBeforeRecording`
     instead of the live `transcribedText`.
   - `abortRecording`, `clearAll`, `onDisappear`: cancel the session too.
   - While a live transcript is finalizing, the status bar shows "Finalizing…" and the
     "Transcribing audio…" overlay is hidden, so it doesn't cover the text.
   - The STT badge turns red when Deepgram is selected and has no key.
5. **`Views/SettingsView.swift`**
   - API Keys tab: a "Deepgram" section with a SecureField.
   - Transcription tab: the provider picker warns when the key is missing. A "Deepgram" section
     holds the Language picker (Mixed Chinese + English / English / Chinese), the Keyterms field
     (comma-separated), the "Show live transcript while recording" toggle and Test Connection. The shared
     Language field is hidden while Deepgram is selected.
6. **`CLAUDE.md`**: add the provider to "STT Providers", "Key files", data flow and concurrency notes.

### Deliberately not doing (deviations from the guide)

- **`@deepgram/sdk`**: it's for JS/Node. Swift uses `URLSessionWebSocketTask` with the same protocol.
- **`utterance_end_ms` / `vad_events`**: the app commits on `is_final` and on Stop, so it never acts
  on `UtteranceEnd` or `SpeechStarted`.
- **`/v1/auth/grant` temporary tokens / backend**: this is a personal macOS app, and guide 5.1
  allows a Keychain key.
- **`SttProvider` protocol + xAI Grok STT**: there's only one streaming provider. I'll extract a
  protocol when a second one is added.
- **Auto-reconnect / 5xx retry**: a failure shows an error. Text committed before the failure is kept.
- **`Finalize` message**: CloseStream already flushes. Finalize is only for continuous dictation,
  which the app doesn't have.

## Tests

Unit tests (Swift Testing, no network or microphone, through the `nonisolated static` seams):

- `listenURL`: every parameter present, `keyterm` repeated, a multi-word keyterm percent-encoded,
  empty keyterms dropped; mixed mode sends `language=multi` plus both hints, English/Chinese modes
  send their single `language` and no hints.
- `parseEvent` / `parsePrerecordedResponse`: interim and final Results, empty transcript,
  Metadata, Error, unknown type, bad JSON, the pre-recorded transcript and a malformed one.
- `TranscriptAccumulator`: interim overwrite, final append, CJK joiner, an empty final clears the
  interim, `promoteInterim()`, UTF-16 interim length.
- `pcm16Data(from:)`: 0, ±1.0, clamping beyond ±1, little-endian byte order, byte count.
- `connectionError` and `DeepgramError`: 401/403 (rejected key), 400 with `dg-error`, 429, 503,
  no response; every description, and only a 4xx counts as a rejection. Missing key fails in `init`.
- `AppState`: keyterm parsing, Deepgram settings surviving a relaunch (restored afterwards),
  stable language-mode raw values, provider properties, and `isConfigured` through its static seam
  (no test sets an API key: that would write the user's real Keychain).
- `ContentView.recordedText`: normal vs append, empty append.
- `TranscriptEditor`: dimmed interim tail and its restyle when it turns final; scroll to the end
  while recording, scroll position kept otherwise.

UI test: `testDeepgramShowsItsBadgeAndOwnSettings` selects Deepgram with a launch argument (never
persisted) and checks the badge and the Deepgram section in Settings. It never records and never
presses Test Connection.

Not covered by automated tests: `DeepgramStream`'s connection lifecycle (buffering until open,
KeepAlive, flush order, CloseStream, the four finalize paths, close-code mapping, cancel, the
fallback decision), the REST upload itself, and `ContentView`'s recording flow. These need a
network or a microphone. The smoke test and the manual checks below cover them, or a fake-socket
test seam could (not added).

End-to-end smoke test (scratchpad only, not committed): generate speech with
`say --file-format=WAVE --data-format=LEI16@16000` (English, and a mixed Chinese sentence with
English terms, e.g. "把 Brewer 的 pipeline 部署到 homelab", using the `Tingting` voice),
stream it in real time through the same URL and protocol, and check that the last word arrives and
the keyterm is spelled right. This needs the API key. See "API key" below.

Manual acceptance (guide section 8, with a real microphone):

- [ ] Text complete < 500 ms after Stop
- [ ] Last word never lost
- [ ] Keyterms spelled correctly
- [ ] Mixed zh+en sentences on Mixed mode (`multi` + hints), compared with Chinese mode (`zh`)
      and with Local Whisper on the same recording; also `endpointing` 300 vs 100
- [ ] Wi-Fi off → clear error, no hang, earlier text kept
- [ ] `live` and `final-only` both work; append, abort and clear during finalize all behave

## API key

The implementation doesn't need it. It's needed only for the end-to-end checks. Please don't paste
it into the chat, because it would stay in the transcript.

- For the app: enter it in Settings → API Keys → Deepgram after the build. It goes to the Keychain.
- For the scripted smoke test: copy the key, then run
  `! pbpaste > <scratchpad>/deepgram.key` so it goes straight to a file I can read. I delete the
  file afterwards.

## Decisions (2026-10-24)

1. **Live text style: interim in a lighter color.** `TranscriptEditor` gets a `dimmedSuffixLength`;
   the last N characters (the current interim) are drawn in `secondaryLabelColor`.
2. **REST fallback: yes.** If the stream fails while recording, or ends without a result, Stop sends
   the WAV that was recorded alongside to `POST https://api.deepgram.com/v1/listen` with the same
   model, language and keyterm parameters (`Content-Type: audio/wav`), and parses
   `results.channels[0].alternatives[0].transcript`. A rejected key (401/403) does not fall back.
3. **Test Connection: yes.** Settings sends 1 s of silence through the socket (open → audio →
   CloseStream → Metadata), which checks the key and every query parameter.
