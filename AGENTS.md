# AGENTS.md

Guidance for coding agents (and human contributors) working on VoiceInput.

## Commands

```bash
make build     # release build → VoiceInput.app/ (signed with Config/Signing.*.mk)
make run       # build + open the app
make test      # XCTest suite — ALWAYS use this, not bare `swift test`
make dmg       # build + produce VoiceInput.dmg (hdiutil UDZO)
make install   # build + copy to /Applications
```

## Gotchas (read before running)

- **Use `make test`, never bare `swift test`.** The test bundle needs
  `-Xlinker -rpath $(swift build --show-bin-path)` to find `Sparkle.framework`
  — SwiftPM does not add it for executable-target binary deps. Same applies
  to `swift run`.
- **Never `exec` the built binary directly.** Launch via `open VoiceInput.app`
  — direct execution crashes on TCC (`NSSpeechRecognitionUsageDescription`
  is only honored inside a proper bundle context).
- **Permissions are real.** Tests must not depend on TCC-granted state
  (Accessibility / Microphone / Speech). Keep tests on pure logic; anything
  that reads AX or posts CGEvents stays untested or behind explicit harness
  seams.
- **`sensitive: true` log calls collapse the whole line to `<redacted>`.**
  To preserve event labels while still redacting content, pass
  `metadata: ["transcript": SensitiveLogValue(text)]` and keep `sensitive`
  false for the label.
- **Do not weaken `LogRedactor`.** Its suffix matching deliberately
  over-redacts (e.g. a key ending in `text`). Prefer false positives over
  leaking transcripts or secrets.
- **Cancellation ≠ completion.** Never drop a task handle after `cancel()`.
  Register it with `TrackedTaskStore` so its real exit is observable.
- `swift test` output ends with a Swift Testing "0 tests" run — normal, not
  a failure.

## Conventions

- Swift 5 mode, macOS 14+, `SwiftUI` + `AppKit` (no Catalyst).
- `@MainActor` on UI-touching types; nonisolated pure-logic `enum`s for
  anything testable (`LogRedactor`, `SelectionPolicy`, `HotkeyRouting`,
  `DictionaryRules`).
- One type per file, named after the type. Feature code lives under
  `Sources/VoiceInput/<Domain>/` (`Hotkey/`, `Selection/`, `Storage/`,
  `MainWindow/`); flat files are shared infrastructure.
- UserDefaults keys go through `UserDefaults+Keys.swift` — never raw
  `string(forKey:)` literals. Legacy key migrations belong in the accessor,
  not at call sites.
- Secrets (LLM API keys) live in Keychain via `KeychainHelper`; never in
  UserDefaults or logs.
- Comments explain *why*, not what. No doc-comment boilerplate.
- Commits: imperative, focused on *why*. Reference issues as `ref #N`;
  merge commits use `closes #N`.
- Architecture source-of-truth: `docs/Architecture.md` — update it when you
  change structure, add a subsystem, or alter the pipeline.

## Release

`docs/Release.md` covers signing identities, `make dmg`, Sparkle appcast,
and key management. The Sparkle private key lives in the login keychain —
never commit it.
