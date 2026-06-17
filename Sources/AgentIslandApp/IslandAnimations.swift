import AppKit

/// Small helpers for the island's CLI-style status cues. The actual cueing (cycling the
/// spinner, blinking the caret) is driven by `IslandPanel`'s shared ticker calling
/// `SessionRowView.tick(_:)`; this just holds the shared constants.
enum IslandAnimations {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Terminal braille spinner frames, cycled for the working state.
    static let braille = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
}
