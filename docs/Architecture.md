# Architecture

Living source map for VoiceInput (~5k LOC Swift, SPM executable, macOS 14+).
Update this file when structure changes — it is deliberately honest about
weaknesses, not aspirational.

## What it is

Menu-bar push-to-talk dictation: hold a hotkey → speak → release →
recognized (optionally LLM-polished) text is typed into the focused app.
No window by default; the SwiftUI main window opens on demand.

## Pipeline

```
HotkeyManager (CGEvent tap)
  → AppDelegate.hotkeyPressed/Released        # owns session lifecycle
  → SpeechRecognizer (SFSpeechRecognizer + AVAudioEngine)
      partials → FloatingPanel (waveform + live text)
  → on release: submitSession()
      ├── LLMRefiner (SSE stream, OpenAI-compatible / Ollama)
      │     streamed tokens → FloatingPanel
      │     final → TextInjector → HistoryStore
      │     "Use Original" → RefinementFallback → same TextInjector path
      └── LLM off → TextInjector (dictionary-replaced transcript)
                    → HistoryStore
TextInjector = clipboard snapshot (all items/types) → ⌘V CGEvent →
  pending-restore chain (per-injection ticket; canceled pre-paste writes
  abort synchronously so the next snapshot sees the true base)
Esc tap: keyDown/keyUp always in the event mask; EscapeRouting consumes
Esc only while a session is active → AppDelegate.cancelActiveDictation()
```

**Session identity:** `AppDelegate` owns `activeSession: {id, generation,
submitted, ...}`. Every async callback re-checks `sessionID` before touching
state — a stale callback from a cancelled session is dropped. A new dictation
cancels any in-flight refinement so late chunks can't inject text.

## Source map

| Path | Role |
|---|---|
| `App.swift` | `@main` NSApplicationDelegateAdaptor shell |
| `AppDelegate.swift` | Coordinator: menu bar, session lifecycle, wiring. **Known god object** — refactor boundary, split before adding more features |
| `Hotkey/HotkeyModel.swift` | `HotkeyBinding` (hotkey + behavior) list model, Codable |
| `Hotkey/HotkeyManager.swift` | CGEvent tap, binding storage + legacy migration, dispatch |
| `HotkeyRouting` (in HotkeyModel) | Pure routing: regular keys > modifier-only, `doubleTap > longPress > tap`, then business priority. Unimplemented behaviors pass through without consuming the key |
| `SpeechRecognizer.swift` | `SFSpeechRecognizer` wrapper; prefers on-device, falls back to server; warmed at launch |
| `LLMRefiner.swift` | SSE streaming refine; task stored in `TrackedTaskStore` |
| `TextInjector.swift` | clipboard swap + ⌘V + restore; CJK input-method aware; optional auto-Return; `InjectionTicket` tracks cancel-before/after-paste so a cancelled delivery suppresses send and deletes its history record |
| `DictationTarget.swift` | Frontmost app + focused AX element captured before the panel steals focus; re-validated before paste and before auto-Return; mismatch parks the result instead of sending |
| `EscapeRouting.swift` | Pure Esc routing: consume only while a session is active; `PressOwnership` pins one decision per physical press (repeats + keyUp follow it); ⌘⌥⎋ always passes through |
| `AutoSendRules.swift` | Pure per-app auto-send override resolution: `inherit` (absent entry) / on / off keyed by bundle ID; resolved once at session start |
| `RefinementFallback.swift` | "Use Original" while LLM is pending: clears `pendingSession` before cancelling so racing callbacks fail the request-ID guard; exactly-one injection/history |
| `Selection/SelectedTextProbe.swift` | Selected-text read: AX `AXSelectedText` (0.2 s timeout, caret-only early-exit) → ⌘C clipboard fallback with snapshot/restore + `changeCount` ownership check |
| `Selection/SelectionPolicy.swift` | Pure policy deciding caret vs real selection; untested surface = system IO only |
| `TrackedTaskStore.swift` | Retains tasks (incl. cancelled) until actual exit; drained in `applicationWillTerminate`. **Cancellation ≠ release** |
| `AppLogger.swift` + `LogRedactor.swift` | In-memory ring buffer; all lines redacted before storage (sensitive-key suffix match + `SensitiveLogValue` + free-text secret scrub + `~` home shortening) |
| `DiagnosticsExporter.swift` | `NSSavePanel` export: version, OS, permission tri-state, redacted logs |
| `LogsWindow.swift` | AppKit log viewer + export button |
| `Storage/DictionaryStore.swift` | Custom dictionary; `DictionaryRules` pure replacements (unit-tested) |
| `Storage/HistoryStore.swift` | Dictation records (no audio yet) |
| `MainWindow/` | SwiftUI: Home / History / Dictionary / LLM profiles / Settings / permissions; `AutoSendOverridesView` edits per-app send overrides |
| `FloatingPanel.swift`, `WaveformView.swift`, `SoundPlayer.swift` | Recording indicator UI + sounds |
| `LLMConfig.swift`, `KeychainHelper.swift` | Profiles config; API keys in Keychain |
| `UserDefaults+Keys.swift` | Typed preference accessors + legacy `hotkeyData` → binding-list migration |
| `AudioDeviceManager.swift`, `InputMethodManager.swift`, `LanguageManager.swift`, `LaunchAtLoginManager.swift` | Small single-purpose managers |

## Testing

`Tests/VoiceInputTests/` — XCTest on pure logic only: dictionary rules,
hotkey routing/decoding, selection policy, log redaction, task store,
stats, UserDefaults keys. `TestHelpers.swift` provides isolated
`UserDefaults` suites and temp dirs. **No TCC-dependent tests.**

Run via `make test` (adds the rpath SwiftPM omits; see AGENTS.md).

## Release

`Makefile` includes `Config/Signing.shared.mk` then optional gitignored
`Config/Signing.local.mk` (identity/entitlements override). `make dmg` →
`tools/build_dmg.sh` (hdiutil UDZO). Sparkle 2.10 auto-update: feed URL in
`Info.plist` → repo-root `appcast.xml`; private key in login keychain.
Full workflow: `docs/Release.md`.

## Known debts / boundaries

- `AppDelegate` is the acknowledged refactor boundary (coordinator +
  session state + menu + panel wiring).
- `SelectedTextProbe` exists but no feature consumes it yet (#21 will).
- `HotkeyBehavior` declares `tap`/`doubleTap` but only `longPress`
  (push-to-talk) is wired (#20 will).
- App is **not sandboxed**; entitlements file only. Permission footprint:
  Accessibility, Microphone, Speech — keep it that way (see Voxt's
  permission-minimization precedent).
