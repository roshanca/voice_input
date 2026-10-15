# Shared code-signing defaults for local and release builds.
# Local overrides go in Config/Signing.local.mk (gitignored) — copy
# Config/Signing.local.mk.example to get started. Values set there win
# because it is included after this file.

# Identity passed to `codesign --sign`. The default is the stable
# self-signed "VoiceInput Dev" certificate so TCC permissions persist
# across rebuilds. For a notarized release use "Developer ID Application: …".
CODESIGN_IDENTITY = VoiceInput Dev

# Entitlements applied during signing.
CODESIGN_ENTITLEMENTS = VoiceInput.entitlements
