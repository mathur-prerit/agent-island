import AppKit
import AgentIslandCore

// MARK: - Minimal CLI theme (id "minimal")

/// Terminal-style cues: a braille spinner while working, a blinking caret while waiting, a static
/// ✓ / ✗ / · otherwise. Keeps the persona emoji alongside. Silent (uses the default `sound(for:)`).
struct MinimalTheme: IslandTheme {
    let id = "minimal"
    let displayName = "Minimal (CLI)"
    let showsPersonaGlyph = true

    func makeScene() -> ThemeScene { MinimalScene() }
    func icon() -> NSImage { IslandIcons.symbol("terminal", pointSize: 12) }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }
}

// MARK: - Minimal scene

/// A single monospace label that renders the CLI cues: a braille spinner while working, a blinking
/// caret while waiting, a static ✓ / ✗ / · otherwise. Always inline (never its own row). The
/// spinner/caret depend on the frame, so the snapshot is stored and re-rendered on both
/// `apply` (frame 0) and every `tick`.
final class MinimalScene: ThemeScene {
    private let label = NSTextField(labelWithString: "")
    private var snapshot = RowSnapshot(id: "", tokens: 0, state: .idle)

    init() {
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)   // size to content
    }

    var view: NSView { label }
    var prefersOwnRow: Bool { false }   // always a small inline indicator

    func apply(_ snapshot: RowSnapshot) {
        self.snapshot = snapshot
        render(frame: 0)
    }

    func tick(_ frame: Int) { render(frame: frame) }

    func animates(_ snapshot: RowSnapshot) -> Bool {
        switch snapshot.state {
        case .working, .waiting: return true
        case .idle, .failed, .finished: return false
        }
    }

    private func render(frame: Int) {
        let (text, color): (String, NSColor)
        switch snapshot.state {
        case .idle:
            (text, color) = ("·", .tertiaryLabelColor)
        case .working:
            (text, color) = (IslandAnimations.braille[frame % IslandAnimations.braille.count], .systemTeal)
        case .waiting:
            (text, color) = ((frame / 5) % 2 == 0 ? "▋" : " ", .systemOrange)
        case .failed:
            (text, color) = ("✗", .systemRed)
        case .finished:
            (text, color) = ("✓", .systemGreen)
        }
        label.stringValue = text
        label.textColor = color
    }
}
