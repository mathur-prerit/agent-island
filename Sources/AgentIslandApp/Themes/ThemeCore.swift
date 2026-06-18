import AppKit
import Foundation
import AgentIslandCore

// Theme system core: the rendering contract every theme speaks (`ThemeScene`), the `IslandTheme`
// protocol, the `Themes` registry, and the shared per-state background tint. Concrete themes
// live one-per-file alongside this (`JourneyTheme.swift`, `MinimalTheme.swift`).

/// A theme's live status indicator for one row. The theme owns the AppKit view(s) and all the
/// state→visual logic; the row view just hands it a `RowSnapshot`, asks where to place it
/// (inline beside the title vs. a wide banner on its own row), and advances its animation frame.
/// One scene instance per row, re-created when the theme changes.
protocol ThemeScene: AnyObject {
    /// The view to place — whichever sub-view is active for the current snapshot (or a container).
    var view: NSView { get }
    /// Where to place `view` for the CURRENT snapshot. Read AFTER `apply(_:)`; state-dependent
    /// (e.g. the road wants its own banner row, an inline icon/label does not).
    var prefersOwnRow: Bool { get }
    /// Set the static, frame-independent state (tokens, which sub-view to show, colours).
    func apply(_ snapshot: RowSnapshot)
    /// Advance the animation to `frame` (lane dashes, spinner glyph, signal cycle…).
    func tick(_ frame: Int)
    /// Does this state animate, so the shared ticker needs to run?
    func animates(_ snapshot: RowSnapshot) -> Bool
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
    /// Make a fresh status-indicator scene for one row. The scene owns its view(s) and renders
    /// every state itself; the row drives it via `apply`/`tick`.
    func makeScene() -> ThemeScene
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
