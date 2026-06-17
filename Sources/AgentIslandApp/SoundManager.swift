import AppKit
import AgentIslandCore

/// One-shot sound playback for theme lifecycle cues. Quiet by default; obeys an enabled flag, a
/// no-overlap rule (the Road Runner clips are multi-second jingles — never start one while another
/// is playing), and a short cooldown so a burst of session transitions on one refresh tick yields
/// at most one cue. NSSound plays WAV/AIFF/CAF off a file URL with no decode or audio-session setup.
final class SoundManager {
    static let shared = SoundManager()
    static let enabledKey = "soundEnabled"   // UserDefaults; absent → false (quiet by default)

    /// Master gate. Mirrors `UserDefaults["soundEnabled"]`.
    var isEnabled: Bool
    /// Minimum gap between two plays.
    var cooldown: TimeInterval = 1.0

    private var lastPlayed = Date.distantPast
    private var live: NSSound?   // retain the playing sound (NSSound stops if deallocated)

    init() { isEnabled = UserDefaults.standard.bool(forKey: SoundManager.enabledKey) }

    /// Play `url` if enabled, nothing is currently playing, and we're off cooldown.
    /// Returns whether it actually played (used by the self-test indirectly via PlayThrottle).
    @discardableResult
    func play(_ url: URL?) -> Bool {
        guard isEnabled, let url else { return false }
        if let live, live.isPlaying { return false }   // no overlap
        let now = Date()
        guard PlayThrottle.allows(now: now, last: lastPlayed, cooldown: cooldown),
              let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        lastPlayed = now
        live = sound
        sound.play()
        return true
    }
}
