import Foundation

/// Pure retention policy for history audio: which clip file names must be
/// deleted so only the newest `keepNewest` audio-bearing records keep
/// theirs. `records` is newest-first (HistoryStore's invariant).
///
/// The cap counts records that carry a clip, not records overall — records
/// without audio consume no quota, so the policy bounds FILE COUNT on disk
/// (and thus disk usage at ~64 KB/s of captured PCM) rather than how far
/// back in history playback reaches.
enum HistoryAudioRetention {
    static func fileNamesToDelete(records: [DictationRecord], keepNewest: Int) -> Set<String> {
        var kept = 0
        var doomed = Set<String>()
        for record in records {
            guard let name = record.audioFileName else { continue }
            if kept < keepNewest {
                kept += 1
            } else {
                doomed.insert(name)
            }
        }
        return doomed
    }
}
