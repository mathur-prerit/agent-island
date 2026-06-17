import AppKit
import AgentIslandCore

/// A visual theme for the island's per-row status cue. A theme decides what the row's indicator
/// shows (and its color) for a given state at a given animation frame, the row's background tint,
/// and whether the persona emoji is shown alongside. Themes are swapped at runtime from the menu.
protocol IslandTheme {
    var id: String { get }
    var displayName: String { get }
    var showsPersonaGlyph: Bool { get }
    /// Does this row's cue animate (so the shared ticker needs to run)?
    func animates(_ row: IslandPanel.Row) -> Bool
    /// The indicator string + its color for a row at tick `frame`.
    func indicator(for row: IslandPanel.Row, frame: Int) -> (text: String, color: NSColor)
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

/// Token burn drives a journey: a vehicle that upgrades by tokens used (🚲→🚗→🚆→✈️) travels a
/// road marked with token milestones (50K / 100K / 200K); past 200K the plane "flies dangerously"
/// (⚠). Waiting is a traffic light; failed crashes; finished waves the chequered flag; idle parks.
struct JourneyTheme: IslandTheme {
    let id = "journey"
    let displayName = "Road trip"
    let showsPersonaGlyph = false   // the vehicle is the indicator

    func animates(_ row: IslandPanel.Row) -> Bool { row.spinning || row.waitReason != nil }

    func indicator(for row: IslandPanel.Row, frame: Int) -> (text: String, color: NSColor) {
        if row.id == "idle" { return ("🅿️", .secondaryLabelColor) }
        if row.spinning { return road(tokens: row.tokens, frame: frame) }
        if row.waitReason != nil { return (trafficLight(frame), .systemOrange) }
        if row.verdict == .failed { return ("💥", .systemRed) }
        if row.dimmed { return ("🏁", .systemGreen) }
        return ("🅿️", .secondaryLabelColor)
    }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }

    private func road(tokens: Int, frame: Int) -> (String, NSColor) {
        let vehicle = JourneyMilestones.vehicle(forTokens: tokens)
        let color: NSColor
        switch tokens {
        case ..<JourneyMilestones.cycle: color = .systemTeal
        case ..<JourneyMilestones.car:   color = .systemBlue
        case ..<JourneyMilestones.plane: color = .systemIndigo
        default:                         color = .systemPink
        }
        let cells = 9                                   // 3 bands × 3 cells; ┊ at the 50K/100K marks
        let progress = min(Double(tokens) / Double(JourneyMilestones.plane), 1.0)
        let filled = Int((progress * Double(cells)).rounded())
        var bar = ""
        for i in 0..<cells {
            if i == 3 || i == 6 { bar += "┊" }
            if i < filled { bar += "▰" }
            else if i == filled && (frame / 3) % 2 == 0 { bar += "▰" }   // blinking frontier = motion
            else { bar += "▱" }
        }
        let danger = tokens >= JourneyMilestones.plane ? " ⚠" : ""
        return ("\(vehicle) ▕\(bar)▏\(danger)", color)
    }

    private func trafficLight(_ frame: Int) -> String {
        let lights = ["🔴", "🔴", "🔴", "🟡", "🟢", "🟢", "🟡"]
        return lights[(frame / 6) % lights.count]
    }
}

// MARK: - Minimal CLI theme

/// Terminal-style cues: a braille spinner while working, a blinking caret while waiting, a static
/// ✓ / ✗ / · otherwise. Keeps the persona emoji alongside.
struct MinimalTheme: IslandTheme {
    let id = "minimal"
    let displayName = "Minimal (CLI)"
    let showsPersonaGlyph = true

    func animates(_ row: IslandPanel.Row) -> Bool { row.spinning || row.waitReason != nil }

    func indicator(for row: IslandPanel.Row, frame: Int) -> (text: String, color: NSColor) {
        if row.id == "idle" { return ("·", .tertiaryLabelColor) }
        if row.spinning { return (IslandAnimations.braille[frame % IslandAnimations.braille.count], .systemTeal) }
        if row.waitReason != nil { return ((frame / 5) % 2 == 0 ? "▋" : " ", .systemOrange) }
        if row.verdict == .failed { return ("✗", .systemRed) }
        if row.dimmed { return ("✓", .systemGreen) }
        return ("·", .tertiaryLabelColor)
    }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }
}
