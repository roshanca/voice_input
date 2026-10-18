# Architecture

Living source map for VoiceInput (~5k LOC Swift, SPM executable, macOS 14+).
Update this file when structure changes — it is deliberately honest about
weaknesses, not aspirational.

## What it is

Menu-bar dictation: trigger a hotkey (hold, tap-to-toggle, or double-tap)
→ speak → recognized (optionally LLM-polished) text is typed into the
focused app. A second hotkey swaps the polish step for LLM translation,
a third sends the transcript to the LLM as an instruction (voice rewrite).
No window by default; the SwiftUI main window opens on demand — except on
first launch, when a paged onboarding flow (permissions → mic → hotkey
practice → LLM pointer) runs before the flag `hasCompletedOnboarding`
settles the app into the menu bar (#27).

## Pipeline

```
HotkeyManager (CGEvent tap)
  → AppDelegate.hotkeyPressed/Released        # owns session lifecycle
    (tap/doubleTap bindings → GestureRouting → onToggle → toggleDictation,
    which reuses the same pressed/released paths)
  → ASR seam: the session snapshots an ASR plan at press (#28)
      ├── .system → SpeechRecognizer (SFSpeechRecognizer + AVAudioEngine)
      │     partials → FloatingPanel (waveform + live text)
      │     every partial also runs through EndCommandMatcher (#26): a
      │     configured trigger phrase at the transcript tail ends the
      │     session via the same releaseSession path the key takes, and
      │     the phrase is stripped from the stored text — the final
      │     result re-strips (a mid-string occurrence means post-command
      │     audio kept transcribing, so it's truncated there)
      └── .remote → RemoteASRRecognizer (same engine+tap, PCM → WAV file
            in RecordingTempStore's owner-only temp dir)
            release → multipart POST {base}/audio/transcriptions →
            {text} → final result → same submitSession path — batch ASR
            can't fire the command mid-record; the same tail-strip still
            removes a spoken trigger before submit. WAV lifecycle (#35):
            Esc/quit discard it, the upload removes it on every outcome,
            writer release is a last-resort delete, and a launch sweep
            reclaims orphans — the writer holds an exclusive flock for its
            whole life, so the sweep can prove a file is unowned (lock
            free + expired) instead of guessing from age; the pre-#35
            leak location in the temp root is swept with the same checks
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

History audio (#25): the tap tees the same converted PCM it appends to the
recognition request into a per-session CAF (HistoryAudioWriter inside
AudioTapContext, `History Audio/<sessionID>.caf`). Graceful stop seals the
clip; teardown/Esc discard it; sessions that never produce a record (empty
transcript, superseded/canceled pending session) delete it from AppDelegate.
recordHistory attaches `audioFileName` only when the clip exists on disk →
History rows get a play/pause button driven by the shared single-slot
HistoryAudioPlayer. Deleting a record or clearing history removes its clip;
HistoryAudioRetention keeps clips only on the newest 100 audio-bearing
records, and a launch-time reconcile sweeps files no record references.
```

**Session identity:** `AppDelegate` owns `activeSession: {id, generation,
submitted, ...}`. Every async callback re-checks `sessionID` before touching
state — a stale callback from a cancelled session is dropped. A new dictation
cancels any in-flight refinement so late chunks can't inject text. Selection
transforms carry the same contract one level down (#33): the caller stamps
each request with a UUID kept in `selectionTransformRequestID`, partial and
completion callbacks for any other id are dropped, and cancellation is
recognized in both its shapes (`CancellationError` and `URLError.cancelled`)
— so a superseded/Esc-cancelled request can no longer resolve in-flight
state under its successor.

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
| `AppDelegate.swift` | Coordinator: menu bar, session lifecycle, wiring, launch gate for onboarding (first run swaps the standalone Accessibility modal for the flow's permissions step and polls so the tap still activates on grant). **Known god object** — refactor boundary, split before adding more features |
| `Hotkey/HotkeyModel.swift` | `HotkeyBinding` (hotkey + behavior) list model, Codable; `Hotkey` = fn/right-modifier/F-key/`chord` (key + exact `ModifierFlags`); `HotkeyBusiness` = dictation, `rePaste`, `translate`, `rewrite`, and three selection actions (`selectionTranslate`, `selectionRewrite`, `addToDictionary`) |
| `Hotkey/HotkeyManager.swift` | CGEvent tap, binding storage + legacy migration, dispatch. Re-paste chords swallow keyDown+keyUp and fire once per press (`rePastePressed` gates auto-repeat). Chord press stacks keep ordinary same-letter typing intact and prevent injected ⌘V events from stealing a physical chord's release. Hold-mode press edges drop auto-repeat keyDowns at the tap — required since #26: the voice end command clears `isHotkeyHeld` while the key is still down, and an unfiltered repeat would restart a session under the same hold. Translate and rewrite bindings dispatch press/release edges like dictation's. Selection chords hand both edges to the delegate via `onSelectionAction` — the press's probe is async, so fallback state lives on the main actor, not the tap |
| `HotkeyRouting` (in HotkeyModel) | Pure routing: chords > regular keys > modifier-only, then `doubleTap > hold > tap`, then business priority (selectionTranslate > selectionRewrite > addToDictionary > rewrite > translate > rePaste > dictation). First matching routed binding owns the keyDown; a chord's repeats and keyUp follow that owner even if modifiers change, while an unclaimed press passes both edges through |
| `Hotkey/GestureRouting.swift` | Pure tap/doubleTap edge state machine: tap fires on the release edge of a full cycle; doubleTap fires on the second press inside the double-click window; held-key repeats never count; unclaimed releases pass through. Per-binding state lives in the tap callback (`nonisolated` static, `escapeOwnership` pattern) |
| `SpeechRecognizer.swift` | `SFSpeechRecognizer` wrapper; prefers on-device, falls back to server; warmed at launch (only when provider = system — remote never requests Speech auth). `AudioTapContext` also tees the converted PCM into the session's `HistoryAudioWriter` when `historyAudioEnabled` is on |
| `ASR/ASRProvider.swift` | `ASRProvider` (system/remote) + `ASRSessionPlan` — the plan resolved at press and snapshotted into the session, so mid-session settings can't reroute a recording |
| `ASR/RemoteASRRecognizer.swift` | Remote-ASR backend: engine + shared `AudioTapContext` teeing converted PCM into a frame-capped WAV file under the restricted `RecordingTempStore` dir; release finalizes → uploads → delegate contract mirrors SpeechRecognizer's minus partials. The tap polls `fileSinkLimitReached` so an over-cap recording fails like a route change (#34). Upload tracked in `TrackedTaskStore`; Esc and app-quit cancel capture + upload and discard the file. Also tees a history clip like the system path |
| `ASR/AudioTapContext.swift` | Shared render-thread tap state (request, file sink, history writer, converter, RMS) — remote sessions set `fileSink`, system sessions set `request`; either may set `audioWriter`; system path byte-identical when `fileSink` is nil. Mirrors the sink's `reachedLimit` latch onto `fileSinkLimitReached` (#34) |
| `ASR/RecordingTempStore.swift` | Dedicated owner-only (0700) temp dir `VoiceInput-ASR/` for remote-ASR WAVs, `voiceinput-asr-<uuid>.wav` convention. The dir is opened once O_NOFOLLOW\|O_DIRECTORY and validated (real dir, our uid, mode repaired); directory-bound ops are fd-relative (fstatat/unlinkat, mkstemp+renameat for creation) so symlinks and mid-check swaps can't escape it. The verified file identity is carried end-to-end: the writer opens `/dev/fd/<lockFD>` — vnode-bound, no dir-path resolution — and the upload reads the same descriptor path, while deletion is an inode-checked unlinkat. Recordings are created under an exclusive flock; `sweepOrphans` (launch) deletes a candidate only when it is convention-named with a real UUID, a regular non-symlink file, older than `orphanMaxAge`, AND its lock is free — a live session's file fails the lock, never the age guess. Also sweeps the pre-#35 leak location in the shared temp root |
| `ASR/RecordingFileWriter.swift` | `AVAudioFile` WAV sink (16 kHz mono Float32 — accepted by every Whisper-compatible endpoint) holding the recording's exclusive flock for its lifetime; `maxFrames` caps the recording and latches `reachedLimit` (#34); `discard` deletes partials through the store's inode-checked unlinkat so canceled dictations leave nothing on disk and can't unlink a planted lookalike, and `deinit` removes the file + releases the lock as a last resort — a released writer can never strand audio |
| `ASR/RemoteTranscriptionService.swift` | OpenAI-compatible `POST /audio/transcriptions`: pure request builder + response parser (`{text}`, `error.message`), BCP-47→ISO-639-1 language hint; `transcribe` is the only I/O — upload size gated before load, response read through `BoundedBodyReader`, whole request under `TotalRequestTimeout` (#34). `RemoteASRError` is `LocalizedError` so panel text survives `Error` bridging |
| `ASR/MultipartFormData.swift` | Pure multipart/form-data body builder, fixed field order, byte-exact tested |
| `LLMRefiner.swift` | SSE streaming refine, translate, **or** rewrite (`Mode` selects system prompt + user wrapper); the whole exchange runs through `SSEStreamExchange` (headers + body inside one wall-clock race, byte caps, coalesced partials — #34); `profileOverride` pins a request to the session's routed `LLMConfig`; task stored in `TrackedTaskStore` |
| `ResourceLimits.swift`, `SSEStreamExchange.swift`, `SSEStreamParser.swift`, `PartialUpdateCoalescer.swift`, `TotalRequestTimeout.swift`, `BoundedBodyReader.swift` | Client-side resource ceilings (#34): numeric caps; one bounded SSE exchange — connect, headers, and body share a `TotalRequestTimeout` race that cancels the stream-owning task (a trickling or stalled body can't outrun it); incremental SSE reader enforcing line/event/output caps; rate limiter for partial UI updates; capped response-body reader (`collect` fails closed, `prefix` samples error bodies) |
| `LLMProfileRouting.swift` | Pure per-app profile routing: exact bundle-ID match wins, absent/dangling entries fall back to the global pick (selected id → first); resolved once at session start |
| `TranslationPrompt.swift` | Pure prompt builder for translate sessions — bidirectional against Chinese (already-in-target input translates back to Chinese), `<transcript>` inert-text wrapper like refine |
| `RewritePrompt.swift` | Pure prompt builder for rewrite sessions — the `<instruction>`-tagged transcript IS the command (inverse of the inert wrappers); output-only contract, ASR-noise-tolerant reading |
| `TextInjector.swift` | clipboard swap + ⌘V + restore; CJK input-method aware; optional auto-Return; `InjectionTicket` tracks cancel-before/after-paste so a cancelled delivery suppresses send and deletes its history record |
| `DictationTarget.swift` | Frontmost app + focused AX element captured before the panel steals focus (and at ⌃⌘V press for re-paste); re-validated before paste and before auto-Return; mismatch parks the result instead of sending. **No readable focused element at capture = unverifiable target** (#31): delivery fails closed unless the app is on the user's `unverifiedFocusAllowlist`, which waives "cannot verify" only — the current focus is still probed, so a definitive "focus is nowhere" (`.noValue`/empty read) and positive evidence of a move still block, as do the app-identity checks. Validation runs through injectable probes (`FocusRead`) so the decision tree is unit-tested without TCC. `isWritable` = capture-time probe of settable `AXValue`/`AXSelectedText`/`AXSelectedTextRange` — voice rewrite's inject-vs-card gate; undecidable resolves to not-writable |
| `EscapeRouting.swift` | Pure Esc routing: consume only while a session is active; `PressOwnership` pins one decision per physical press (repeats + keyUp follow it); ⌘⌥⎋ always passes through |
| `AutoSendRules.swift` | Pure per-app auto-send override resolution: `inherit` (absent entry) / on / off keyed by bundle ID; resolved once at session start |
| `EndCommandMatcher.swift` | Pure voice-end-command matching (#26): tail-only, word-boundary-aware (Latin glue chars only — CJK phrases need no boundary), tolerant of ASR trailing punctuation; `truncateAfterTrigger` drops a re-emitted/mid-string trigger plus post-command audio from late results; `phrases(from:)` parses the comma/line-separated setting |
| `RefinementFallback.swift` | "Use Original" while LLM is pending: clears `pendingSession` before cancelling so racing callbacks fail the request-ID guard; exactly-one injection/history |
| `Selection/SelectedTextProbe.swift` | Selected-text read: AX `AXSelectedText` (0.2 s timeout, caret-only early-exit) → ⌘C clipboard fallback with snapshot/restore + `changeCount` ownership check; drives the selection-action chords |
| `Selection/SelectionPolicy.swift` | Pure policy deciding caret vs real selection and dictionary-term validity; untested surface = system IO only |
| `Selection/SelectionFallback.swift` | Pure press-outcome decision: act on selection / fall back to dictation / ignore when the key was released before the probe answered |
| `Selection/SelectionTransformer.swift` | One-shot streamed LLM transform (translate → `translateTargetLanguage`, rewrite); own client so it can't cancel a dictation refinement; same `SSEStreamExchange` bounded request as the refiner (#34); writes no history. Caller-stamped `requestID` gates every callback: identity is restamped/cleared before `task.cancel()`, and partial/failure/success emissions re-check it plus `Task.isCancelled` — `URLError.cancelled` counts as a cancel, never a failure. `config`/`session` injectable for the scripted-URLProtocol tests |
| `Selection/SelectionPrompts.swift` | Whole-instruction system prompts for the transforms — the selection itself is the user message |
| `TrackedTaskStore.swift` | Retains tasks (incl. cancelled) until actual exit; drained in `applicationWillTerminate`. **Cancellation ≠ release** |
| `AppLogger.swift` + `LogRedactor.swift` | In-memory ring buffer; all lines redacted before storage (sensitive-key suffix match + `SensitiveLogValue` + free-text secret/userinfo scrub + `~` home shortening); endpoint URLs log via `sanitizedURL` (scheme/host/port + allowlisted path/query, userinfo never), failures via stable `errorCode` — server bodies and `localizedDescription` echo never reach a line |
| `DiagnosticsExporter.swift` | `NSSavePanel` export: version, OS, permission tri-state, redacted logs |
| `LogsWindow.swift` | AppKit log viewer + export button |
| `Storage/DictionaryStore.swift` | Custom dictionary; `DictionaryRules` pure replacements (unit-tested) |
| `Storage/HistoryStore.swift` | Dictation records incl. `audioFileName` (`decodeIfPresent` — pre-audio records decode to nil); record-cap trims, `delete` and `clearAll` remove the clips too; `maxAudioRecords` = 100 clip retention |
| `Storage/HistoryAudioStore.swift` | Clip directory (`Application Support/VoiceInput/History Audio/`): `<sessionID>.caf` naming convention, path-contained file ops; dir injectable for tests |
| `Storage/HistoryAudioWriter.swift` | Per-session CAF capture owned by `AudioTapContext`: write() on the render thread under its lock (real-time safe), finish seals on graceful stop (empty clips deleted), discard deletes on cancel; write errors latch off |
| `Storage/HistoryAudioRetention.swift` | Pure newest-N clip policy: which `audioFileName`s to delete so only the newest N audio-bearing records keep theirs |
| `MainWindow/` | SwiftUI: Home / History / Dictionary / LLM profiles / Settings / permissions; `AutoSendOverridesView` edits per-app send overrides, `LLMProfileOverridesView` edits per-app profile routes, `UnverifiedFocusAllowlistView` edits the unverified-focus opt-ins; `HistoryAudioPlayer` = shared single-slot play/pause for History rows; Settings → General hosts the "Re-run Onboarding" affordance |
| `Onboarding/` | First-run paged flow (#27): `OnboardingStep` (pure step order — permissions before the hotkey practice because the tap needs Accessibility) → `OnboardingView` pager inside `OnboardingWindowController` (plain NSWindow — the floating panel is nonactivating session UI, wrong shape here). Permissions step embeds `PermissionsSection` verbatim (same checks + Settings deep links); mic step reuses the `SettingsStore` picker; the hotkey step shows the persisted `savedDictation` binding — the live tap makes a press there a real dictation — and LLM step only deep-links to Settings (no rebuilt editor). `show()` reinstalls the root view so re-runs restart at welcome; finish/skip writes `hasCompletedOnboarding`, mid-flow close doesn't |
| `AnswerCardPanel.swift` | Floating card for a rewrite answer that can't be injected (unwritable target or failed delivery): scrollable read-only text + Copy/Close; counts as session work so Esc dismisses it through the normal interception |
| `FloatingPanel.swift`, `WaveformView.swift`, `SoundPlayer.swift` | Recording indicator UI + sounds |
| `LLMConfig.swift`, `KeychainHelper.swift` | Profiles config; API keys in Keychain |
| `UserDefaults+Keys.swift` | Typed preference accessors + legacy `hotkeyData` → binding-list migration; `rePasteHotkeyBindings` defaults to ⌃⌘V, `translateHotkeyBindings` to ⌃⌥T (⌃⌥Space rejected — macOS's input-source switch), `rewriteHotkeyBindings` to ⌃⌥R, selection-action bindings to ⌃⇧T/⌃⇧R/⌃⇧D, `translateTargetLanguage` to English (shared by voice translate and translate-selection), `perAppLLMProfileOverrides` = bundle-ID → profile-UUID map, `unverifiedFocusAllowlist` = per-app opt-ins for unverifiable-focus delivery (#31), `historyAudioEnabled` defaults on (bounds: 100-clip retention); `asrProvider`/`remoteASRBaseURL`/`remoteASRModel` select the ASR backend (the remote key lives in Keychain under account `remote-asr`, not here); `voiceEndCommandEnabled`/`voiceEndCommandPhrases` drive the voice end command — default on, phrases default to "over,完毕", blank restores the default; `hasCompletedOnboarding` gates the first-run flow (#27) |
| `AudioDeviceManager.swift`, `InputMethodManager.swift`, `LanguageManager.swift`, `LaunchAtLoginManager.swift` | Small single-purpose managers |

## Testing

`Tests/VoiceInputTests/` — XCTest on pure logic only: dictionary rules,
hotkey routing/decoding, selection policy, log redaction, task store,
stats, UserDefaults keys, translation prompt contract, end-command tail
matching/truncation, remote-ASR wire format (multipart layout, request
shape, response/error parsing, upload ceiling) and session-plan
resolution, selection-transform cancellation isolation (scripted
URLProtocol on a fictional host — no real network), dictation-target
validation (#31: missing/unreadable/churning focus, same-app field
switch, explicit-allowlist waiver — all via scripted probes), client
resource limits (#34: SSE line/event/output caps and total-duration
bounds, partial-update coalescing, bounded body reads, request timeout,
recording frame cap), and the temp-recording lifecycle (writer
finish/discard/release, tap-context cancel, recording-lock
exclusivity, symlinked-dir rejection, orphan-sweep naming/age/lock
gates incl. the legacy temp-root location).
`TestHelpers.swift` provides isolated `UserDefaults` suites and temp
dirs. **No TCC-dependent tests.**

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
