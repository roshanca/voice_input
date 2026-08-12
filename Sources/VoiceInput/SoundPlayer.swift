import AppKit

/// Start/stop interaction sounds, gated by the `interactionSounds` preference.
/// Uses bundled system sounds; keep the names here for easy swapping.
@MainActor
enum SoundPlayer {
    private static let startSoundName = "Tink"
    private static let stopSoundName = "Pop"

    static func recordStart() {
        play(startSoundName)
    }

    static func recordStop() {
        play(stopSoundName)
    }

    private static func play(_ name: String) {
        guard UserDefaults.standard.interactionSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
