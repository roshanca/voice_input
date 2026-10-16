# Architecture

Living source map for VoiceInput (~5k LOC Swift, SPM executable, macOS 14+).
Update this file when structure changes — it is deliberately honest about
weaknesses, not aspirational.

## What it is

Menu-bar dictation: trigger a hotkey (hold, tap-to-toggle, or double-tap)
→ speak → recognized (optionally LLM-polished) text is typed into the
focused app. A second hotkey swaps the polish step for LLM translation,
a third sends the transcript to the LLM as an instruction (voice rewrite).
No window by default; the SwiftUI main window opens on demand.

## Pipeline

```
HotkeyManager (CGEvent tap)
  → AppDelegate.hotkeyPressed/Released        # owns session lifecycle
    (tap/doubleTap bindings → GestureRouting → onToggle → toggleDictation,
    which reuses the same pressed/released paths)
  → ASR seam: the session snapshots an ASR plan at press (#28)
      ├── .system → SpeechRecognizer (SFSpeechRecognizer + AVAudioEngine)
      │     partials → FloatingPanel (waveform + live text)
      └── .remote → RemoteASRRecognizer (same engine+tap, PCM → WAV file)
            release → multipart POST {base}/audio/transcriptions →
            {text} → final result → same submitSession path
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
Re-paste: ⌃⌘V chord (Hotkey.chord — exact modifier match, swallowed whole)
fires once per press → AppDelegate.rePasteLastResult() → TextInjector with
a freshly captured target; text = HistoryStore's latest outputText
Translate: ⌃⌥T chord (HotkeyBusiness.translate, hold) → same session
machinery (translatePressed/Released share the dictation internals; the
session carries `kind`). submitSession forks on kind → LLMRefiner.translate
(TranslationPrompt, `translateTargetLanguage`) → translated text →
TextInjector → HistoryStore. Unlike refinement this is not gated by
`llmEnabled` — with no configured profile the transcript is parked in
History + panel flash, nothing injected
Rewrite: ⌃⌥R chord (HotkeyBusiness.rewrite, hold) → same machinery, but
the transcript is the instruction itself (RewritePrompt — <instruction>
tags mark what to execute, the inverse of the inert-text wrappers) →
LLMRefiner.rewrite → answer delivery forks on the captured target's
`isWritable` (AX settable-text-attribute probe; undecidable = not
writable): writable → TextInjector → HistoryStore like dictation;
not writable → AnswerCardPanel (copyable card, Esc-dismissible via the
session-active Esc interception). A failed injection outcome (parked /
clipboard undeliverable) surfaces the card too — the generated text is
never lost. Same not-configured fallback as translate.

Selection actions: ⌃⇧T / ⌃⇧R / ⌃⇧D chords send press+release edges to
AppDelegate, which probes the selection on press (SelectedTextProbe):
  - selection found → run the action on this press (no waiting for release):
    translate/rewrite → SelectionTransformer (one-shot streamed LLM call,
    no history) → TextInjector replaces the selection in place;
    dictionary → SelectionPolicy.dictionaryCandidate → DictionaryStore
  - nothing selected → the press falls back to hold-to-dictate and its
    release routes to hotkeyReleased(); a key already released before the
    probe answers resolves to a no-op (a dictation could never stop)
```

**Session identity:** `AppDelegate` owns `activeSession: {id, generation,
submitted, ...}`. Every async callback re-checks `sessionID` before touching
state — a stale callback from a cancelled session is dropped. A new dictation
cancels any in-flight refinement so late chunks can't inject text.

**Per-app profile routing:** at session start, the captured target's bundle
ID resolves through `LLMProfileRouting` against the `perAppLLMProfileOverrides`
map (bundle ID → profile UUID). The session snapshots the resulting
`LLMConfig` and `submitSession` passes it to `LLMRefiner` as
`profileOverride`, so a mid-session app switch or profile change can't swap
the config mid-flight. Dangling ids (deleted profile, malformed value) fall
back to the global `currentLLMConfig` pick; selection transforms don't route.

## Source map

| Path | Role |
|---|---|
| `App.swift` | `@main` NSApplicationDelegateAdaptor shell |
| `AppDelegate.swift` | Coordinator: menu bar, session lifecycle, wiring. **Known god object** — refactor boundary, split before adding more features |
| `Hotkey/HotkeyModel.swift` | `HotkeyBinding` (hotkey + behavior) list model, Codable; `Hotkey` = fn/right-modifier/F-key/`chord` (key + exact `ModifierFlags`); `HotkeyBusiness` = dictation, `rePaste`, `translate`, `rewrite`, and three selection actions (`selectionTranslate`, `selectionRewrite`, `addToDictionary`) |
| `Hotkey/HotkeyManager.swift` | CGEvent tap, binding storage + legacy migration, dispatch. Re-paste chords swallow keyDown+keyUp and fire once per press (`rePastePressed` gates auto-repeat — the injected ⌘V's own keyUp can clear it mid-hold). Translate and rewrite bindings dispatch press/release edges like dictation's. Selection chords hand both edges to the delegate via `onSelectionAction` — the press's probe is async, so fallback state lives on the main actor, not the tap |
| `HotkeyRouting` (in HotkeyModel) | Pure routing: chords > regular keys > modifier-only, then `doubleTap > hold > tap`, then business priority (selectionTranslate > selectionRewrite > addToDictionary > rewrite > translate > rePaste > dictation). First matching routed binding owns the event |
| `Hotkey/GestureRouting.swift` | Pure tap/doubleTap edge state machine: tap fires on the release edge of a full cycle; doubleTap fires on the second press inside the double-click window; held-key repeats never count; unclaimed releases pass through. Per-binding state lives in the tap callback (`nonisolated` static, `escapeOwnership` pattern) |
| `SpeechRecognizer.swift` | `SFSpeechRecognizer` wrapper; prefers on-device, falls back to server; warmed at launch (only when provider = system — remote never requests Speech auth) |
| `ASR/ASRProvider.swift` | `ASRProvider` (system/remote) + `ASRSessionPlan` — the plan resolved at press and snapshotted into the session, so mid-session settings can't reroute a recording |
| `ASR/RemoteASRRecognizer.swift` | Remote-ASR backend: engine + shared `AudioTapContext` teeing converted PCM into a WAV file; release finalizes → uploads → delegate contract mirrors SpeechRecognizer's minus partials. Upload tracked in `TrackedTaskStore`; Esc cancels capture + upload |
| `ASR/AudioTapContext.swift` | Shared render-thread tap state (request **or** file sink, converter, RMS) — remote sessions set `fileSink`, system sessions set `request`; system path byte-identical when `fileSink` is nil |
| `ASR/RecordingFileWriter.swift` | `AVAudioFile` WAV sink (16 kHz mono Float32 — accepted by every Whisper-compatible endpoint); `discard` deletes partials so canceled dictations leave nothing on disk |
| `ASR/RemoteTranscriptionService.swift` | OpenAI-compatible `POST /audio/transcriptions`: pure request builder + response parser (`{text}`, `error.message`), BCP-47→ISO-639-1 language hint; `transcribe` is the only I/O. `RemoteASRError` is `LocalizedError` so panel text survives `Error` bridging |
| `ASR/MultipartFormData.swift` | Pure multipart/form-data body builder, fixed field order, byte-exact tested |
| `LLMRefiner.swift` | SSE streaming refine, translate, **or** rewrite (`Mode` selects system prompt + user wrapper); `profileOverride` pins a request to the session's routed `LLMConfig`; task stored in `TrackedTaskStore` |
| `LLMProfileRouting.swift` | Pure per-app profile routing: exact bundle-ID match wins, absent/dangling entries fall back to the global pick (selected id → first); resolved once at session start |
| `TranslationPrompt.swift` | Pure prompt builder for translate sessions — bidirectional against Chinese (already-in-target input translates back to Chinese), `<transcript>` inert-text wrapper like refine |
| `RewritePrompt.swift` | Pure prompt builder for rewrite sessions — the `<instruction>`-tagged transcript IS the command (inverse of the inert wrappers); output-only contract, ASR-noise-tolerant reading |
| `TextInjector.swift` | clipboard swap + ⌘V + restore; CJK input-method aware; optional auto-Return; `InjectionTicket` tracks cancel-before/after-paste so a cancelled delivery suppresses send and deletes its history record |
| `DictationTarget.swift` | Frontmost app + focused AX element captured before the panel steals focus (and at ⌃⌘V press for re-paste); re-validated before paste and before auto-Return; mismatch parks the result instead of sending. `isWritable` = capture-time probe of settable `AXValue`/`AXSelectedText`/`AXSelectedTextRange` — voice rewrite's inject-vs-card gate; undecidable resolves to not-writable |
| `EscapeRouting.swift` | Pure Esc routing: consume only while a session is active; `PressOwnership` pins one decision per physical press (repeats + keyUp follow it); ⌘⌥⎋ always passes through |
| `AutoSendRules.swift` | Pure per-app auto-send override resolution: `inherit` (absent entry) / on / off keyed by bundle ID; resolved once at session start |
| `RefinementFallback.swift` | "Use Original" while LLM is pending: clears `pendingSession` before cancelling so racing callbacks fail the request-ID guard; exactly-one injection/history |
| `Selection/SelectedTextProbe.swift` | Selected-text read: AX `AXSelectedText` (0.2 s timeout, caret-only early-exit) → ⌘C clipboard fallback with snapshot/restore + `changeCount` ownership check; drives the selection-action chords |
| `Selection/SelectionPolicy.swift` | Pure policy deciding caret vs real selection and dictionary-term validity; untested surface = system IO only |
| `Selection/SelectionFallback.swift` | Pure press-outcome decision: act on selection / fall back to dictation / ignore when the key was released before the probe answered |
| `Selection/SelectionTransformer.swift` | One-shot streamed LLM transform (translate → `translateTargetLanguage`, rewrite); own client so it can't cancel a dictation refinement; writes no history |
| `Selection/SelectionPrompts.swift` | Whole-instruction system prompts for the transforms — the selection itself is the user message |
| `TrackedTaskStore.swift` | Retains tasks (incl. cancelled) until actual exit; drained in `applicationWillTerminate`. **Cancellation ≠ release** |
| `AppLogger.swift` + `LogRedactor.swift` | In-memory ring buffer; all lines redacted before storage (sensitive-key suffix match + `SensitiveLogValue` + free-text secret scrub + `~` home shortening) |
| `DiagnosticsExporter.swift` | `NSSavePanel` export: version, OS, permission tri-state, redacted logs |
| `LogsWindow.swift` | AppKit log viewer + export button |
| `Storage/DictionaryStore.swift` | Custom dictionary; `DictionaryRules` pure replacements (unit-tested) |
| `Storage/HistoryStore.swift` | Dictation records (no audio yet) |
| `MainWindow/` | SwiftUI: Home / History / Dictionary / LLM profiles / Settings / permissions; `AutoSendOverridesView` edits per-app send overrides, `LLMProfileOverridesView` edits per-app profile routes |
| `AnswerCardPanel.swift` | Floating card for a rewrite answer that can't be injected (unwritable target or failed delivery): scrollable read-only text + Copy/Close; counts as session work so Esc dismisses it through the normal interception |
| `FloatingPanel.swift`, `WaveformView.swift`, `SoundPlayer.swift` | Recording indicator UI + sounds |
| `LLMConfig.swift`, `KeychainHelper.swift` | Profiles config; API keys in Keychain |
| `UserDefaults+Keys.swift` | Typed preference accessors + legacy `hotkeyData` → binding-list migration; `rePasteHotkeyBindings` defaults to ⌃⌘V, `translateHotkeyBindings` to ⌃⌥T (⌃⌥Space rejected — macOS's input-source switch), `rewriteHotkeyBindings` to ⌃⌥R, selection-action bindings to ⌃⇧T/⌃⇧R/⌃⇧D, `translateTargetLanguage` to English (shared by voice translate and translate-selection), `perAppLLMProfileOverrides` = bundle-ID → profile-UUID map; `asrProvider`/`remoteASRBaseURL`/`remoteASRModel` select the ASR backend (the remote key lives in Keychain under account `remote-asr`, not here) |
| `AudioDeviceManager.swift`, `InputMethodManager.swift`, `LanguageManager.swift`, `LaunchAtLoginManager.swift` | Small single-purpose managers |

## Testing

`Tests/VoiceInputTests/` — XCTest on pure logic only: dictionary rules,
hotkey routing/decoding, selection policy, log redaction, task store,
stats, UserDefaults keys, translation prompt contract, remote-ASR wire
format (multipart layout, request shape, response/error parsing) and
session-plan resolution. `TestHelpers.swift` provides isolated
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
- Selection-action bindings are persisted per business but have no editor
  UI yet — settings shows them read-only (#21 added the actions).
- `HotkeyManager` supports one binding per business for gesture purposes —
  two bindings on the same hotkey collapse to the routed winner; the
  settings UI edits a single dictation binding anyway.
- App is **not sandboxed**; entitlements file only. Permission footprint:
  Accessibility, Microphone, Speech — keep it that way (see Voxt's
  permission-minimization precedent). The remote-ASR provider (#28) needs
  only Microphone; Speech auth is skipped entirely while it's selected.
- Remote ASR is **batch upload only** — no streaming/WebSocket
  transcription; one remote config (no profile list like the LLM side);
  the provider applies to dictation/translate/rewrite sessions alike —
  selection-action transforms involve no ASR and are unaffected.
