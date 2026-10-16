import AVFAudio
import Combine

/// Single-slot playback for History rows: tapping a row's play button loads
/// that record's clip, tapping another row's replaces it, and tapping the
/// playing row pauses in place. One shared player so two clips can never
/// overlap; kept deliberately minimal — play/pause only, no seek.
@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject {
    static let shared = HistoryAudioPlayer()

    /// Clip file name currently loaded — rows compare against their own
    /// `audioFileName` to decide between the play and pause glyph.
    @Published private(set) var playingFileName: String?
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?

    /// Toggle for one row's clip: same clip → pause/resume, different clip
    /// → stop and switch, missing/unreadable file → stays silent (the row
    /// keeps its button; nothing crashes).
    func toggle(fileName: String) {
        if playingFileName == fileName, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }

        stop()
        let url = HistoryAudioStore.shared.fileURL(forFileName: fileName)
        guard let next = try? AVAudioPlayer(contentsOf: url) else {
            // The record claims a clip that isn't there (deleted
            // externally, pruned mid-session) — degrade to no-op.
            AppLogger.shared.warning("History audio not playable: \(fileName)")
            return
        }
        next.delegate = self
        next.play()
        player = next
        playingFileName = fileName
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        playingFileName = nil
        isPlaying = false
    }

    /// Row-scoped stop: deleting one record must not kill playback of a
    /// different clip.
    func stopIfPlaying(fileName: String?) {
        guard fileName != nil, fileName == playingFileName else { return }
        stop()
    }
}

extension HistoryAudioPlayer: AVAudioPlayerDelegate {
    /// Delegate callbacks aren't actor-isolated; hop so published state
    /// resets on the main actor.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resetIfCurrent(player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.resetIfCurrent(player) }
    }

    /// Natural end / decode failure resets to the play glyph — but only if
    /// the finished player is still the loaded one: a stale hop must not
    /// clear a different clip the user switched to in the meantime.
    private func resetIfCurrent(_ finishedPlayer: AVAudioPlayer) {
        guard player === finishedPlayer else { return }
        player = nil
        playingFileName = nil
        isPlaying = false
    }
}
