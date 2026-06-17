import AppKit
import Foundation
import AgentIslandCore

// Theme system core: the rendering contract every theme speaks (`Cue`), the `IslandTheme`
// protocol, the `Themes` registry, and the shared per-state background tint. Concrete themes
// live one-per-file alongside this (`JourneyTheme.swift`, `MinimalTheme.swift`).

/// What a row's status indicator renders as. A theme returns one of these per frame; the row view
/// shows a monospace label, a (tintable) icon, or the scrolling road scene accordingly.
enum Cue {
    case text(String, NSColor)              // monospace label (Minimal theme + fallbacks)
    case icon(NSImage, tint: NSColor?)      // an SF Symbol (tinted) or a hand-drawn image (tint == nil)
    case road(tokens: Int, mode: RoadMode)  // the road-trip theme's journey scene (driving or stopped)
}

/// How the road scene plays: the vehicle is either driving (world scrolls) or halted at an
/// in-scene signal while the session waits on the developer.
enum RoadMode: Equatable {
    case driving
    case stopped(StopKind)

    /// Why the vehicle is stopped — shapes the signal cue (red-dominant block vs. a gentler pause).
    enum StopKind: Equatable {
        case permission   // blocked on a permission/elicitation prompt — a red light, your move
        case turnEnd      // the agent ended its turn — a pitstop, idling until you reply
    }
}

/// A visual theme for the island's per-row status cue. A theme decides what the row's indicator
/// shows for a given state at a given animation frame, the row's background tint, whether the
/// persona emoji is shown alongside, and (optionally) a sound clip to play on a state transition.
/// Themes are swapped at runtime from the menu.
protocol IslandTheme {
    var id: String { get }
    var displayName: String { get }
    var showsPersonaGlyph: Bool { get }
    /// Does this row's cue animate (so the shared ticker needs to run)?
    func animates(_ row: IslandPanel.Row) -> Bool
    /// The indicator for a row at tick `frame`.
    func cue(for row: IslandPanel.Row, frame: Int) -> Cue
    /// Row background tint base color (`.clear` = no tint).
    func tint(for row: IslandPanel.Row) -> NSColor
    /// The sound clip to play for a lifecycle transition (a theme jingle), or `nil` for silence.
    /// Default: silent — a theme opts in by overriding (only Road Runner does today).
    func sound(for transition: SoundTransition) -> URL?
}

extension IslandTheme {
    func sound(for transition: SoundTransition) -> URL? { nil }
}

enum Themes {
    /// First entry is the default.
    static let all: [IslandTheme] = [JourneyTheme(), MinimalTheme()]
    static func named(_ id: String?) -> IslandTheme { all.first { $0.id == id } ?? all[0] }
}

/// Shared per-state background tint (subtle; alpha applied by the row). Module-internal so the
/// per-file themes can share one definition.
func stateTint(_ row: IslandPanel.Row) -> NSColor {
    if row.id == "idle" { return .clear }
    if row.spinning { return .systemTeal }
    if row.waitReason != nil { return .systemOrange }
    if row.verdict == .failed { return .systemRed }
    if row.dimmed { return .systemGreen }   // finished
    return .clear
}
