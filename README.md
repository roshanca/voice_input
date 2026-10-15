# VoiceInput

A lightweight macOS menu-bar app for **push-to-talk voice dictation**, anywhere on your system. Hold a hotkey, speak, release — the recognized (and optionally LLM-polished) text is typed directly into whatever app has focus.

## Features

- **Push-to-talk dictation** — hold the hotkey to record, release to transcribe and insert. Default hotkey is `Fn (Globe)`; also supports right-side modifiers (⌃⌥⇧⌘) and `F5`–`F12`.
- **Fast, on-device-first speech recognition** — powered by Apple's `SFSpeechRecognizer` with native punctuation. Prefers on-device recognition and automatically falls back to server-based recognition when Siri/Dictation is disabled; the speech session is warmed up at launch so the first recording starts instantly. Supports English, Simplified Chinese, and Traditional Chinese, switchable at any time.
- **Optional LLM refinement, streamed live** — clean up filler words, fix punctuation, and polish phrasing with an LLM. Output is streamed (SSE) token-by-token and mirrored to the floating panel as it arrives. Works with any **OpenAI-compatible API** (OpenAI, DeepSeek, etc.) or a **local Ollama** instance. Multiple named profiles with per-profile base URL, model, and system prompt; API keys are stored securely in the macOS Keychain.
- **Custom dictionary** — teach the app your vocabulary: term replacements are applied to transcripts and injected into the LLM prompt so names and jargon come out right.
- **Types into any app** — text is injected via clipboard + simulated ⌘V paste, with awareness of CJK input methods. Optional **auto-send** (presses Return afterward) for chat apps.
- **History & stats** — every dictation is saved locally with duration and word count; browse, copy, or re-insert past entries.
- **Floating recording indicator** — a compact always-on-top panel with a live waveform, recording state, and a streaming preview of the refined text as the LLM generates it.
- **Menu-bar native** — lives in the status bar with a SwiftUI main window (Home / History / Dictionary / Settings), launch-at-login, microphone selection, interaction sounds, and a built-in logs viewer.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+ or a standalone toolchain)
- Microphone, Speech Recognition, and Accessibility permissions (the app guides you through granting them on first launch)

> Accessibility access is required for the global hotkey (CGEvent tap) and for simulating ⌘V paste into other apps. The app polls for the grant and starts the hotkey automatically once it arrives — no restart needed.

## Build & Run

```bash
# Build a signed (ad-hoc) .app bundle
make build

# Build and launch
make run

# Build and install to /Applications
make install

# Remove build artifacts
make clean
```

This produces `VoiceInput.app` in the project root, signed with the local **"VoiceInput Dev"** identity (a stable self-signed certificate) so that macOS TCC permissions persist across rebuilds.

Always run the app through `make` targets — the bundle embeds `Sparkle.framework`, which a bare `swift build`/`swift run` binary can't locate at runtime (a SwiftPM limitation with executable targets). Signing identities can be overridden per machine via `Config/Signing.local.mk`, and `make dmg` packages a distributable disk image — see [docs/Release.md](docs/Release.md).

## Usage

1. Launch the app — a microphone icon appears in the menu bar.
2. On first run, grant **Microphone**, **Speech Recognition**, and **Accessibility** permissions when prompted (or from Settings → Permissions).
3. Hold the dictation hotkey (default: `Fn`) and speak.
4. Release — the transcript (optionally LLM-refined) is pasted into the focused app.

### Settings highlights

| Setting | Description |
|---|---|
| Recognition language | English / Simplified Chinese / Traditional Chinese |
| Dictate hotkey | `Fn (Globe)`, right ⌃/⌥/⇧/⌘, or `F5`–`F12` |
| Copy to clipboard | Keep the result on the clipboard instead of restoring the previous contents |
| Auto-send | Press Return after inserting (handy for chat apps) |
| LLM refinement | Enable/disable, pick the active profile |
| Microphone | Choose the input device; handles hot-plugging gracefully |

### LLM profiles

Add profiles under **Settings → LLM** with:

- **OpenAI Compatible** — any endpoint speaking the OpenAI chat-completions API (default: `https://api.openai.com/v1`, model `gpt-4o-mini`)
- **Ollama (Local)** — default `http://localhost:11434/v1`, model `llama3.1`

Each profile has its own system prompt, so you can keep different styles (e.g. "formal email" vs "chat shorthand"). API keys live in the Keychain, never in plain-text preferences.

## Project Structure

```
Sources/VoiceInput/
├── App.swift / AppDelegate.swift      # Entry point, menu bar, dictation pipeline
├── HotkeyManager.swift                # Global push-to-talk hotkey (CGEvent tap)
├── SpeechRecognizer.swift             # SFSpeechRecognizer wrapper, per-language locale
├── LLMRefiner.swift / LLMConfig.swift # Streaming (SSE) refinement pipeline & provider profiles
├── TextInjector.swift                 # Clipboard + simulated ⌘V insertion, auto-send
├── DictionaryStore / HistoryStore     # Local persistence (JSON in Application Support)
├── FloatingPanel.swift / WaveformView # Recording HUD
└── MainWindow/                        # SwiftUI window: Home, History, Dictionary, Settings
```

Built as a plain SwiftPM executable target and packaged into an `.app` bundle by the `Makefile` — no Xcode project required.

## Privacy

- Speech recognition runs **on-device** via Apple's Speech framework whenever possible; if Siri/Dictation is disabled on your Mac, it falls back to Apple's server-based recognition.
- Audio and transcripts never leave your Mac (beyond Apple's own recognition service in the fallback case) unless you explicitly enable LLM refinement, in which case only the transcript text is sent to the provider you configured. Transcripts are marked sensitive in the system log so they stay redacted.
- History, dictionary, and settings are stored locally in `~/Library/Application Support`.

## License

MIT
