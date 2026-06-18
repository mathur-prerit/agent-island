import Foundation
import AgentIslandCore

/// The default (non-theme) sound cue set: quiet, neutral lifecycle blips that fill the silence when
/// a theme ships no jingle of its own (e.g. Minimal), or that replace a theme's set entirely when
/// the user picks "Default set". The pure transition→name mapping lives in `AgentIslandCore`
/// (`DefaultSoundSet`, pinned by the self-test); this type only resolves those names to bundled WAVs.
///
/// Clips live under `Sources/AgentIslandApp/Themes/Default/` (bundled via `Package.swift`'s `.copy`):
/// `started.wav`, `waiting.wav`, `finished_ok.wav`, `finished_fail.wav`.
enum DefaultSounds {
    /// The clip base-name for a transition, or `nil` for silence. Thin re-export of the Core mapping.
    static func defaultClipName(for t: SoundTransition) -> String? {
        DefaultSoundSet.clipName(for: t)
    }

    /// Resolve a transition to its bundled neutral WAV, or `nil` for silence.
    static func url(for t: SoundTransition) -> URL? {
        guard let name = defaultClipName(for: t) else { return nil }
        return clip(name)
    }

    /// Resolve a bundled clip. Mirrors JourneyTheme's fallback chain (the `.copy` folder may land at
    /// a couple of layouts in the bundle), then a flat lookup — robust to SwiftPM's resource layout.
    private static func clip(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Default")
            ?? Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Themes/Default")
            ?? Bundle.module.url(forResource: name, withExtension: "wav")
    }
}
