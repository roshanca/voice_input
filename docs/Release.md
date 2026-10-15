# Releasing VoiceInput

This document covers the full release pipeline: signing configuration →
build → DMG packaging → Sparkle appcast → distribution.

## Signing configuration

Code signing is configured in Make syntax under `Config/`:

- `Config/Signing.shared.mk` — committed defaults:
  - `CODESIGN_IDENTITY` (default: `VoiceInput Dev`, the stable self-signed
    certificate that keeps TCC permissions across rebuilds)
  - `CODESIGN_ENTITLEMENTS` (default: `VoiceInput.entitlements`)
- `Config/Signing.local.mk` — **gitignored** per-machine overrides. Copy
  `Config/Signing.local.mk.example` to create it. Values here win because
  the Makefile includes it after the shared file:

  ```make
  include Config/Signing.shared.mk
  -include Config/Signing.local.mk
  ```

  Example — sign with a Developer ID identity for a notarized build:

  ```make
  CODESIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
  ```

Command-line overrides also work for one-off builds:

```bash
make build CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## Build

```bash
make build   # swift build -c release → VoiceInput.app (signed, Sparkle embedded)
make test    # swift test
```

`make build`:

1. Compiles the release binary with an
   `@executable_path/../Frameworks` rpath.
2. Assembles `VoiceInput.app` and stamps `CFBundleVersion` with a
   date-based build number (`YYYYMMDD.HHMM`, monotonically increasing —
   Sparkle compares this field).
3. Embeds `Sparkle.framework` (from the SwiftPM artifact) into
   `Contents/Frameworks/`.
4. Signs the bundle with `$(CODESIGN_IDENTITY)` and
   `$(CODESIGN_ENTITLEMENTS)`.

## DMG packaging

```bash
make dmg     # build + tools/build_dmg.sh → VoiceInput.dmg
```

`tools/build_dmg.sh` stages the `.app` plus an `/Applications` symlink in a
temp directory and creates a compressed UDZO image with `hdiutil` (no
external dependencies; `create-dmg` is not required). A custom Finder
background/layout can be added to the script later if wanted.

## Sparkle auto-updates

- Dependency: `Sparkle` Swift package, pinned to `from: 2.10.0` in
  `Package.swift` (exact version recorded in `Package.resolved`).
- `Info.plist` carries `SUFeedURL` and `SUPublicEDKey`.
- `AppDelegate` owns a standard `SPUStandardUpdaterController` (started at
  launch; Sparkle asks the user for consent before enabling scheduled
  checks) and a "Check for Updates…" menu item in the status-item menu.
- The app is not sandboxed, so Sparkle runs its standard in-process
  installer — no XPC service setup needed.
- Updates are authenticated by the EdDSA signature, so self-signed (non
  Developer ID) builds update correctly.

### Update feed (SUFeedURL)

The feed lives **in this repository** as `appcast.xml` at the root, served
via GitHub's raw-file endpoint:

```
https://raw.githubusercontent.com/roshanca/voice_input/main/appcast.xml
```

This requires the repository (or at least that file) to be reachable
without authentication. If the repo is or becomes private, host
`appcast.xml` on any static HTTPS host instead and update `SUFeedURL` in
`Info.plist` to match.

### EdDSA keys

Generated once with Sparkle's `generate_keys`, shipped inside the SwiftPM
artifact:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

- The **private key** lives in the login Keychain (generic-password item,
  service `https://sparkle-project.org`, account `ed25519`). It is never
  committed. To move it to another machine: `generate_keys -x exported_keys`
  / `-p` import, or re-generate and bump the feed.
- The **public key** is `SUPublicEDKey` in `Info.plist`.

If the private key is lost, generate a new pair, update `SUPublicEDKey`,
and ship one more manually-downloaded release — older clients can't verify
signatures made by the new key.

## Publishing a release

1. Bump `CFBundleShortVersionString` in `Info.plist` (e.g. `1.1`).
   `CFBundleVersion` is stamped automatically per build.
2. Build and package:

   ```bash
   make dmg        # produces signed VoiceInput.app + VoiceInput.dmg
   ```

3. Generate the appcast entry. Put the DMG in a `dist/` folder and run
   Sparkle's `generate_appcast` (also inside the SwiftPM artifact), pointed
   at the future download URL:

   ```bash
   mkdir -p dist && mv VoiceInput.dmg dist/
   .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
       --download-url-prefix \
       "https://github.com/roshanca/voice_input/releases/download/v<VERSION>/" \
       -o appcast.xml dist/
   ```

   `generate_appcast` reads the private key from the Keychain and writes an
   `<item>` with the `sparkle:edSignature`. Adjust
   `--download-url-prefix` to wherever the DMG will actually be hosted.
   Alternatively sign one archive manually with `bin/sign_update`.
4. Create a GitHub release for tag `v<VERSION>` and attach `VoiceInput.dmg`
   so the enclosure URL resolves.
5. Commit the updated `appcast.xml` to `main` — clients pick the update up
   on their next scheduled check or via "Check for Updates…".

## Caveats

- **Notarization**: the default self-signed identity cannot be notarized.
  For Gatekeeper-clean distribution, set a Developer ID identity in
  `Config/Signing.local.mk`, then `xcrun notarytool submit` the DMG and
  `xcrun stapler staple` it. Document any extra steps there when first done.
- TCC permissions (microphone, accessibility) follow the code signature —
  keep the `VoiceInput Dev` identity stable or users must re-grant after
  each update signed by a different certificate.
- A bare `swift build`/`swift run` binary cannot locate
  `Sparkle.framework` at runtime (SwiftPM doesn't stage binary
  dependencies for executable targets). Run and distribute via the
  `make` targets, which embed the framework into the `.app` bundle.
  `make test` adds the products directory to the test bundle's rpath for
  the same reason.
