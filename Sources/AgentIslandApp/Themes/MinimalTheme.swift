import AppKit
import AgentIslandCore

// MARK: - Minimal CLI theme (id "minimal")

/// Terminal-style cues: a braille spinner while working, a blinking caret while waiting, a static
/// ✓ / ✗ / · otherwise. Keeps the persona emoji alongside. Silent (uses the default `sound(for:)`).
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
