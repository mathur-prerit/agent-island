import AppKit
import AgentIslandCore

/// What a row's status indicator renders as. A theme returns one of these per frame; the row view
/// shows a monospace label, a (tintable) icon, or the scrolling road scene accordingly.
enum Cue {
    case text(String, NSColor)         // monospace label (Minimal theme + fallbacks)
    case icon(NSImage, tint: NSColor?) // an SF Symbol (tinted) or a hand-drawn image (tint == nil)
    case road(tokens: Int)             // the road-trip theme's scrolling journey scene
}

/// A visual theme for the island's per-row status cue. A theme decides what the row's indicator
/// shows for a given state at a given animation frame, the row's background tint, and whether the
/// persona emoji is shown alongside. Themes are swapped at runtime from the menu.
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
}

enum Themes {
    /// First entry is the default.
    static let all: [IslandTheme] = [JourneyTheme(), MinimalTheme()]
    static func named(_ id: String?) -> IslandTheme { all.first { $0.id == id } ?? all[0] }
}

/// Shared per-state background tint (subtle; alpha applied by the row).
private func stateTint(_ row: IslandPanel.Row) -> NSColor {
    if row.id == "idle" { return .clear }
    if row.spinning { return .systemTeal }
    if row.waitReason != nil { return .systemOrange }
    if row.verdict == .failed { return .systemRed }
    if row.dimmed { return .systemGreen }   // finished
    return .clear
}

// MARK: - Road-trip theme

/// Token burn drives a journey: a vehicle that upgrades by tokens used (bike→car→train→plane)
/// "drives" along a scrolling road past roadside signs every 5K tokens, with signboard "towns" at
/// the upgrade milestones (50K / 100K / 200K); past 200K the plane takes off. Waiting shows a
/// traffic light; failed a warning; finished the chequered flag; idle a parking sign.
struct JourneyTheme: IslandTheme {
    let id = "journey"
    let displayName = "Road trip"
    let showsPersonaGlyph = false   // the road scene is the indicator

    func animates(_ row: IslandPanel.Row) -> Bool { row.spinning || row.waitReason != nil }

    func cue(for row: IslandPanel.Row, frame: Int) -> Cue {
        if row.id == "idle" { return .icon(IslandIcons.symbol("parkingsign"), tint: .secondaryLabelColor) }
        if row.spinning { return .road(tokens: row.tokens) }
        if row.waitReason != nil { return .icon(IslandIcons.trafficLight(frame: frame), tint: nil) }
        if row.verdict == .failed { return .icon(IslandIcons.symbol("exclamationmark.triangle.fill"), tint: .systemRed) }
        if row.dimmed { return .icon(IslandIcons.symbol("flag.checkered"), tint: .systemGreen) }
        return .icon(IslandIcons.symbol("parkingsign"), tint: .secondaryLabelColor)
    }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }
}

// MARK: - Minimal CLI theme

/// Terminal-style cues: a braille spinner while working, a blinking caret while waiting, a static
/// ✓ / ✗ / · otherwise. Keeps the persona emoji alongside.
struct MinimalTheme: IslandTheme {
    let id = "minimal"
    let displayName = "Minimal (CLI)"
    let showsPersonaGlyph = true

    func animates(_ row: IslandPanel.Row) -> Bool { row.spinning || row.waitReason != nil }

    func cue(for row: IslandPanel.Row, frame: Int) -> Cue {
        if row.id == "idle" { return .text("·", .tertiaryLabelColor) }
        if row.spinning { return .text(IslandAnimations.braille[frame % IslandAnimations.braille.count], .systemTeal) }
        if row.waitReason != nil { return .text((frame / 5) % 2 == 0 ? "▋" : " ", .systemOrange) }
        if row.verdict == .failed { return .text("✗", .systemRed) }
        if row.dimmed { return .text("✓", .systemGreen) }
        return .text("·", .tertiaryLabelColor)
    }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }
}
